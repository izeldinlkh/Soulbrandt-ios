#!/usr/bin/env bash
set -euo pipefail

PS3_ROOT="${1:?usage: check-ppu-host-ios-compat.sh /path/to/ps3recomp}"
PORT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$PORT_ROOT/ios/scripts/patch-ps3recomp-ios-metal.py" "$PS3_ROOT"
grep -Fq 'vm_write64(ctx->gpr[1] + 0x28, ctx->gpr[2])' "$PS3_ROOT/tools/ppu_lifter.py"
grep -Fq 'kGuestHostStackSize = 256u * 1024u * 1024u' "$PORT_ROOT/ios/SoulbrandtIOS/PS3PPUHostBridge.cpp"
grep -Fq 'uint32_t g_ppu_main_stack_addr = 0;' "$PS3_ROOT/runtime/syscalls/sys_ppu_thread.c"
grep -Fq 'if (!t || !t->stack_size)' "$PS3_ROOT/runtime/syscalls/sys_ppu_thread.c"
grep -Fq 'PPU_ICACHE_N = 1024' "$PS3_ROOT/runtime/ppu/ppu_loader.cpp"
grep -Fq 'g_ppu_icache[PPU_ICACHE_N]' "$PS3_ROOT/runtime/ppu/ppu_loader.cpp"
grep -Fq 'PS3_ICALL_SLOW' "$PS3_ROOT/runtime/ppu/ppu_loader.cpp"
grep -Fq 'g_ppu_image_range_count = image.load_range_count;' "$PS3_ROOT/runtime/ppu/ppu_loader.cpp"
grep -Fq 'g_ppu_image_ranges[i]' "$PS3_ROOT/runtime/ppu/ppu_loader.cpp"
grep -Fq 'entry argument stack overlaps loaded image' "$PS3_ROOT/runtime/ppu/ppu_loader.cpp"
grep -Fq 'ctx.gpr[5] = argv_base + (argc_n + 1u) * 8u;' "$PS3_ROOT/runtime/ppu/ppu_loader.cpp"
grep -Fq 'main_stack_info(&sa, &ss);' "$PS3_ROOT/runtime/syscalls/sys_ppu_thread.c"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
COMMON=(
  -fsyntax-only
  -std=c++20
  -Wno-deprecated-declarations
  -target arm64-apple-ios16.0
  -isysroot "$SDK"
  -D_GNU_SOURCE=1
  -I"$PORT_ROOT/ios/SoulbrandtIOS"
  -I"$PS3_ROOT/include"
  -I"$PS3_ROOT/runtime"
  -I"$PS3_ROOT/runtime/ppu"
  -I"$PS3_ROOT/runtime/platform"
  -I"$PS3_ROOT/runtime/memory"
  -I"$PS3_ROOT/runtime/spu"
  -I"$PS3_ROOT/runtime/syscalls"
  -I"$PS3_ROOT/libs/system"
  -I"$PS3_ROOT/libs/filesystem"
  -I"$PS3_ROOT/libs/input"
  -I"$PS3_ROOT/libs/audio"
  -I"$PS3_ROOT/libs/video"
  -I"$PS3_ROOT/libs/network"
  -I"$PS3_ROOT/libs/spurs"
  -I"$PS3_ROOT/libs/sync"
  -I"$PS3_ROOT/libs/codec"
  -I"$PS3_ROOT/libs/font"
  -I"$PS3_ROOT/libs/misc"
  -I"$PS3_ROOT/third_party/mbedtls/include"
)

# These are the game-agnostic pieces of des_boot's PPU startup path. Compile
# them against Apple's SDK before attempting to add them to the app target.
for source in \
  runtime/ppu/ppu_loader.cpp \
  runtime/ppu/ppu_hle.cpp \
  runtime/ppu/ppu_fs.cpp \
  runtime/ppu/ppu_sysprx.cpp
do
  echo "[ios-ppu] syntax-checking $source"
  xcrun --sdk iphoneos clang++ "${COMMON[@]}" "$PS3_ROOT/$source"
done

# The macOS PPU stack-reporting fix lives in the C LV2 syscall layer, and the
# ELF bounds used by its entry-stack check are produced by the app's C loader.
C_COMMON=(
  -fsyntax-only
  -std=c17
  -target arm64-apple-ios16.0
  -isysroot "$SDK"
  -D_GNU_SOURCE=1
  -I"$PORT_ROOT/ios/SoulbrandtIOS"
  -I"$PS3_ROOT/include"
  -I"$PS3_ROOT/runtime"
  -I"$PS3_ROOT/runtime/ppu"
  -I"$PS3_ROOT/runtime/platform"
  -I"$PS3_ROOT/runtime/memory"
  -I"$PS3_ROOT/runtime/spu"
  -I"$PS3_ROOT/runtime/syscalls"
  -I"$PS3_ROOT/libs/system"
  -I"$PS3_ROOT/libs/filesystem"
  -I"$PS3_ROOT/libs/input"
  -I"$PS3_ROOT/libs/audio"
  -I"$PS3_ROOT/libs/video"
  -I"$PS3_ROOT/libs/network"
  -I"$PS3_ROOT/libs/spurs"
  -I"$PS3_ROOT/libs/sync"
  -I"$PS3_ROOT/libs/codec"
  -I"$PS3_ROOT/libs/font"
  -I"$PS3_ROOT/libs/misc"
  -I"$PS3_ROOT/third_party/mbedtls/include"
)
echo "[ios-ppu] syntax-checking runtime/syscalls/sys_ppu_thread.c"
xcrun --sdk iphoneos clang "${C_COMMON[@]}" "$PS3_ROOT/runtime/syscalls/sys_ppu_thread.c"
echo "[ios-ppu] syntax-checking PS3GuestMemory.c"
xcrun --sdk iphoneos clang "${C_COMMON[@]}" "$PORT_ROOT/ios/SoulbrandtIOS/PS3GuestMemory.c"
