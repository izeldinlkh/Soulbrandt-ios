#!/usr/bin/env bash
set -euo pipefail

PS3_ROOT="${1:?usage: build-ppu-host-ios.sh /path/to/ps3recomp [output-dir]}"
OUT="${2:-$PWD/ppu-host-ios-build}"
PORT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CXX="$(xcrun --sdk iphoneos -f clang++)"
mkdir -p "$OUT/objects" "$OUT/generated" "$OUT/include"
cp "$PORT_ROOT/ios/SoulbrandtIOS/PS3DiscVFSBridge.h" "$OUT/include/"

python3 "$PS3_ROOT/tools/gen_hle_nids.py" \
  --out "$OUT/generated/ppu_hle_nids.cpp" --all

INCLUDES=(
  -I"$PORT_ROOT/ios/SoulbrandtIOS"
  -I"$OUT/generated"
  -I"$PS3_ROOT/include"
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
echo "This archive is not linked into the app yet; it awaits generated title lift code."
