#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/boot_bridge_test.cpp" <<'EOF'
#include "PS3PPUHostBridge.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint32_t g_functions = 0;
static int g_loads, g_recomp, g_hle, g_prx, g_fs, g_lv2, g_runs;
static uint32_t g_run_entry, g_run_stack;
typedef void (*guest_caller_fn)(uint32_t, uint64_t, uint64_t, uint64_t, uint64_t,
                                uint64_t, uint64_t, uint64_t, uint64_t);
extern "C" { guest_caller_fn g_ps3_guest_caller = nullptr; }

extern "C" int32_t soulbrandt_guest_memory_is_ready(void) { return 1; }
extern "C" uint32_t ppu_load_elf(const char *) { ++g_loads; return 0x12345678u; }
extern "C" void ppu_recomp_register(void) { ++g_recomp; }
extern "C" void ppu_hle_init(void) { ++g_hle; }
extern "C" void ppu_sysprx_register(void) { ++g_prx; }
extern "C" void ppu_fs_register(void) { ++g_fs; }
extern "C" void lv2_init_syscalls(void) { ++g_lv2; }
extern "C" uint32_t ppu_function_count(void) { return g_functions; }
extern "C" uint32_t ps3_hle_count(void) { return 17; }
extern "C" uint64_t ppu_guest_call(uint32_t, uint64_t, uint64_t, uint64_t, uint64_t,
                                   uint64_t, uint64_t, uint64_t, uint64_t) { return 0; }
extern "C" int ppu_run(uint32_t entry, uint32_t stack) {
    ++g_runs; g_run_entry = entry; g_run_stack = stack; return 23;
}

int main() {
    if (soulbrandt_ppu_host_set_storage_roots("/tmp/soulbrandt-hdd0", "/tmp/soulbrandt-hdd1") != 0) return 1;
    if (soulbrandt_ppu_host_load_elf("/tmp/DecryptedEBOOT.ELF") != 0x12345678u) return 2;
    if (g_loads != 1 || g_recomp != 1 || g_hle != 1 || g_prx != 1 || g_fs != 1 || g_lv2 != 1) return 3;
    if (!soulbrandt_ppu_host_is_ready() || soulbrandt_ppu_host_function_count() != 0) return 4;
    if (soulbrandt_ppu_host_start_game() != -2) return 5; // empty weak table must be refused

    g_functions = 4096;
    if (soulbrandt_ppu_host_start_game() != 0) return 6;
    for (int i = 0; i < 200 && soulbrandt_ppu_host_is_running(); ++i) {
        struct timespec ts = {0, 5000000};
        nanosleep(&ts, nullptr);
    }
    if (soulbrandt_ppu_host_is_running() || soulbrandt_ppu_host_run_result() != 23) return 7;
    if (g_runs != 1 || g_run_entry != 0x12345678u || g_run_stack != 0x0FF00000u) return 8;
    if (soulbrandt_ppu_host_start_game() != -3) return 9;
    soulbrandt_ppu_host_reset_image();
    if (soulbrandt_ppu_host_is_ready()) return 10;
    puts("PPU host boot-dispatch lifecycle test passed");
    return 0;
}
EOF
c++ -std=c++17 -pthread -I"$ROOT/ios/SoulbrandtIOS" \
  "$ROOT/ios/SoulbrandtIOS/PS3PPUHostBridge.cpp" "$TMP/boot_bridge_test.cpp" \
  -o "$TMP/boot_bridge_test"
"$TMP/boot_bridge_test"
