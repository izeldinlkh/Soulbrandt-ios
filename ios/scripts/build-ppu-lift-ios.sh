#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "usage: build-ppu-lift-ios.sh PS3RECOMP_DIR RECOMP_DIR [SPU_DIR] [OUTPUT_DIR]" >&2
  exit 2
fi

PS3_ROOT="$(cd "$1" && pwd)"
RECOMP_DIR="$2"
SPU_DIR="${3:-$RECOMP_DIR/../spu}"
OUT="${4:-$PWD/ppu-lift-ios-build}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

if [[ ! -d "$PS3_ROOT/runtime/ppu" || ! -d "$PS3_ROOT/include/ps3emu" ]]; then
  echo "not a ps3recomp checkout: $PS3_ROOT" >&2
  exit 2
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"
CXX="$(xcrun --sdk iphoneos -f clang++)"

rm -rf "$OUT/objects"
mkdir -p "$OUT/objects"

INCLUDES=(
  -I"$RECOMP_DIR"
  -I"$PS3_ROOT/include"
  -I"$PS3_ROOT/runtime"
  -I"$PS3_ROOT/runtime/ppu"
  -I"$PS3_ROOT/runtime/spu"
  -I"$PS3_ROOT/runtime/memory"
  -I"$PS3_ROOT/runtime/syscalls"
  -I"$PS3_ROOT/runtime/platform"
  -I"$PS3_ROOT/libs"
  -I"$PS3_ROOT/libs/video"
  -I"$PS3_ROOT/libs/input"
  -I"$PS3_ROOT/libs/audio"
  -I"$PS3_ROOT/libs/spurs"
  -I"$PS3_ROOT/libs/system"
  -I"$PS3_ROOT/libs/filesystem"
  -I"$PS3_ROOT/libs/network"
  -I"$PS3_ROOT/third_party/mbedtls/include"
)

COMMON=(
  -target arm64-apple-ios16.0
  -isysroot "$SDK"
  -fno-strict-aliasing
  "${INCLUDES[@]}"
)

OBJECTS=()
PPU_COUNT=0
SPU_COUNT=0
OBJECT_INDEX=0

compile_source() {
  local source="$1"
  local kind="$2"
  local object_name
  printf -v object_name "%s_%05d_%s.o" "$kind" "$OBJECT_INDEX" "$(basename "${source%.*}")"
  local object="$OUT/objects/$object_name"
  OBJECT_INDEX=$((OBJECT_INDEX + 1))

  if [[ "$source" == *.c ]]; then
    if [[ "$kind" == "spu" ]]; then
      "$CC" "${COMMON[@]}" -std=c17 -O2 -w -DSPU_USE_DISPATCH_MT \
        -I"$PS3_ROOT/runtime/spu" -c "$source" -o "$object"
    else
      "$CC" "${COMMON[@]}" -std=c17 -O1 -w -ffp-contract=off \
        -c "$source" -o "$object"
    fi
  else
    if [[ "$kind" == "spu" ]]; then
      "$CXX" "${COMMON[@]}" -std=c++20 -O2 -w -DSPU_USE_DISPATCH_MT \
        -I"$PS3_ROOT/runtime/spu" -c "$source" -o "$object"
    else
      "$CXX" "${COMMON[@]}" -std=c++20 -O1 -w -ffp-contract=off \
        -c "$source" -o "$object"
    fi
  fi
  OBJECTS+=("$object")
}

if [[ -f "$RECOMP_DIR/ppu_recomp.h" ]]; then
  PPU_SOURCES=()
  while IFS= read -r source; do
    [[ "$(basename "$source")" == "ppu_hle_nids.cpp" ]] && continue
    PPU_SOURCES+=("$source")
  done < <(find "$RECOMP_DIR" -maxdepth 1 -type f \( -name '*.c' -o -name '*.cpp' \) | sort)

  if [[ ${#PPU_SOURCES[@]} -eq 0 ]]; then
    echo "ppu_recomp.h exists but no lifted PPU .c/.cpp files were found in $RECOMP_DIR" >&2
    exit 1
  fi

  for source in "${PPU_SOURCES[@]}"; do
    compile_source "$source" ppu
    PPU_COUNT=$((PPU_COUNT + 1))
  done
else
  echo "No PPU lift found at $RECOMP_DIR; building a marker archive for the no-game shell."
  printf '%s\n' 'int soulbrandt_no_game_lift_marker(void) { return 0; }' > "$OUT/no_game_lift_marker.c"
  compile_source "$OUT/no_game_lift_marker.c" marker
fi

if [[ -f "$RECOMP_DIR/ppu_recomp.h" && -d "$SPU_DIR" ]]; then
  SPU_SOURCES=()
  while IFS= read -r source; do SPU_SOURCES+=("$source"); done \
    < <(find "$SPU_DIR" -mindepth 2 -maxdepth 2 -type f -name 'spu_recomp.c' | sort)

  if [[ ${#SPU_SOURCES[@]} -gt 0 ]]; then
    for source in "${SPU_SOURCES[@]}"; do
      compile_source "$source" spu
      SPU_COUNT=$((SPU_COUNT + 1))
    done
    compile_source "$PS3_ROOT/runtime/spu/spu_dispatch_mt.c" spu
    SPU_COUNT=$((SPU_COUNT + 1))

    for generated in spu_workloads.c jobmods_register.c taskset_policy_bytes.c; do
      if [[ -f "$SPU_DIR/$generated" ]]; then
        compile_source "$SPU_DIR/$generated" spu
        SPU_COUNT=$((SPU_COUNT + 1))
      fi
    done
  fi
fi

/usr/bin/libtool -static -o "$OUT/libSoulbrandtGameLift.a" "${OBJECTS[@]}"
test -s "$OUT/libSoulbrandtGameLift.a"

if [[ -f "$RECOMP_DIR/ppu_recomp.h" ]]; then
  if ! /usr/bin/nm -g "$OUT/libSoulbrandtGameLift.a" | grep -qE ' _function_table$'; then
    echo "lift archive does not export function_table" >&2
    exit 1
  fi
  if ! /usr/bin/nm -g "$OUT/libSoulbrandtGameLift.a" | grep -qE ' _function_table_count$'; then
    echo "lift archive does not export function_table_count" >&2
    exit 1
  fi
  printf 'game_lift=1\nppu_sources=%s\nspu_sources=%s\n' "$PPU_COUNT" "$SPU_COUNT" > "$OUT/lift-status.txt"
else
  printf 'game_lift=0\nppu_sources=0\nspu_sources=0\n' > "$OUT/lift-status.txt"
fi

echo "Built iOS game-lift archive: $OUT/libSoulbrandtGameLift.a"
cat "$OUT/lift-status.txt"
