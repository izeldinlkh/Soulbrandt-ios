#include "PS3PPUHostBridge.h"

#include <cassert>
#include <cstdint>
#include <cstring>

static bool g_memory_ready = false;
static unsigned g_load_calls = 0;
static unsigned g_recomp_register_calls = 0;
static unsigned g_hle_init_calls = 0;
static unsigned g_sysprx_register_calls = 0;
static unsigned g_fs_register_calls = 0;
static unsigned g_syscall_init_calls = 0;

extern "C" int32_t soulbrandt_guest_memory_is_ready(void)
{
    return g_memory_ready ? 1 : 0;
}

extern "C" uint32_t ppu_load_elf(const char *path)
{
    assert(path && std::strlen(path) > 0);
    ++g_load_calls;
    return g_load_calls == 1 ? 0x1000u : 0x2000u;
}
extern "C" void ppu_recomp_register(void) { ++g_recomp_register_calls; }
extern "C" void ppu_hle_init(void) { ++g_hle_init_calls; }
extern "C" void ppu_sysprx_register(void) { ++g_sysprx_register_calls; }
extern "C" void ppu_fs_register(void) { ++g_fs_register_calls; }
extern "C" void lv2_init_syscalls(void) { ++g_syscall_init_calls; }
extern "C" uint32_t ppu_function_count(void) { return 42; }
extern "C" uint32_t ps3_hle_count(void) { return 84; }

int main()
{
    assert(soulbrandt_ppu_host_load_elf("/disc/EBOOT.ELF") == 0);
    assert(g_load_calls == 0);
    assert(soulbrandt_ppu_host_is_ready() == 0);

    g_memory_ready = true;
    assert(soulbrandt_ppu_host_load_elf("/disc/EBOOT.ELF") == 0x1000u);
    assert(soulbrandt_ppu_host_is_ready() == 1);
    assert(soulbrandt_ppu_host_function_count() == 42);
    assert(soulbrandt_ppu_host_hle_count() == 84);
    assert(soulbrandt_ppu_host_load_elf("/different/EBOOT.ELF") == 0x1000u);
    assert(g_load_calls == 1);

    soulbrandt_ppu_host_reset_image();
    assert(soulbrandt_ppu_host_is_ready() == 0);
    assert(soulbrandt_ppu_host_load_elf("/disc/EBOOT.ELF") == 0x2000u);
    assert(g_load_calls == 2);

    // Process-wide registration tables must not be duplicated on restart.
    assert(g_recomp_register_calls == 1);
    assert(g_hle_init_calls == 1);
    assert(g_sysprx_register_calls == 1);
    assert(g_fs_register_calls == 1);
    assert(g_syscall_init_calls == 1);
    soulbrandt_ppu_host_reset_image();
    return 0;
}
