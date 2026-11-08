#!/usr/bin/env bash
set -euo pipefail

PS3_ROOT="${1:?usage: build-ppu-host-ios.sh /path/to/ps3recomp [output-dir] [recomp-dir]}"
OUT="${2:-$PWD/ppu-host-ios-build}"
RECOMP_DIR="${3:-$PORT_ROOT/ios/GameLift/recompiled}"
PORT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$PORT_ROOT/ios/scripts/patch-ps3recomp-ios-metal.py" "$PS3_ROOT"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CXX="$(xcrun --sdk iphoneos -f clang++)"
mkdir -p "$OUT/objects" "$OUT/generated" "$OUT/include"
cp "$PORT_ROOT/ios/SoulbrandtIOS/PS3DiscVFSBridge.h" "$OUT/include/"

# The macOS PPU runtime includes the title-generated ppu_recomp.h. When CI has
# no private EBOOT lift, provide the same table ABI so the host archive can be
# compiled and the app can link its weak empty-table fallback.
if [[ -f "$RECOMP_DIR/ppu_recomp.h" ]]; then
  PPU_HEADER_DIR="$RECOMP_DIR"
else
  PPU_HEADER_DIR="$OUT/generated"
  cat > "$PPU_HEADER_DIR/ppu_recomp.h" <<'EOF'
#pragma once
#include "ppu_context.h"
typedef struct { uint64_t addr; void (*func)(ppu_context*); const char* name; } func_entry;
#ifdef __cplusplus
extern "C" {
#endif
extern const func_entry function_table[];
extern const uint64_t function_table_count;
extern PPU_THREAD_LOCAL void (*g_trampoline_fn)(void*);
#ifdef __cplusplus
}
#endif
EOF
fi

python3 "$PS3_ROOT/tools/gen_hle_nids.py" \
  --out "$OUT/generated/ppu_hle_nids.cpp" --all

INCLUDES=(
  -I"$PORT_ROOT/ios/SoulbrandtIOS"
  -I"$PPU_HEADER_DIR"
  -I"$OUT/generated"
  -I"$PS3_ROOT/include"
  -I"$PS3_ROOT/libs"
  -I"$PS3_ROOT/libs/hardware"
  -I"$PS3_ROOT/third_party/mbedtls/include"
  -I"$PS3_ROOT/runtime"
  -I"$PS3_ROOT/runtime/ppu"
  -I"$PS3_ROOT/runtime/spu"
  -I"$PS3_ROOT/runtime/memory"
  -I"$PS3_ROOT/runtime/syscalls"
  -I"$PS3_ROOT/runtime/platform"
  -I"$PS3_ROOT/libs/system"
  -I"$PS3_ROOT/libs/filesystem"
  -I"$PS3_ROOT/libs/network"
  -I"$PS3_ROOT/libs/video"
)

COMMON=(
  -target arm64-apple-ios16.0
  -isysroot "$SDK"
  -std=c++20
  -O2
  -fno-strict-aliasing
  "${INCLUDES[@]}"
)

SOURCES=(
  "$PS3_ROOT/runtime/ppu/ppu_loader.cpp"
  "$PS3_ROOT/runtime/ppu/ppu_hle.cpp"
  "$PS3_ROOT/runtime/ppu/ppu_fs.cpp"
  "$PS3_ROOT/runtime/ppu/ppu_sysprx.cpp"
  "$OUT/generated/ppu_hle_nids.cpp"
)

for source in "${SOURCES[@]}"; do
  name="$(basename "${source%.*}")"
  "$CXX" "${COMMON[@]}" -c "$source" -o "$OUT/objects/$name.o"
done

/usr/bin/libtool -static -o "$OUT/libSoulbrandtPPUHost.a" "$OUT"/objects/*.o
test -s "$OUT/libSoulbrandtPPUHost.a"
echo "Built iOS PPU host scaffold archive: $OUT/libSoulbrandtPPUHost.a"
echo "The PPU host archive is linked into the iOS app; generated title PPU lift code is still required."
