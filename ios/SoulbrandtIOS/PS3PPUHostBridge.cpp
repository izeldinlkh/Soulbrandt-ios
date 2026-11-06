#include "PS3PPUHostBridge.h"
#include "PS3GuestMemory.h"

#include <stdint.h>

extern "C" {
uint32_t ppu_load_elf(const char *path);
void ppu_recomp_register(void);
void ppu_hle_init(void);
void ppu_sysprx_register(void);
void ppu_fs_register(void);
void lv2_init_syscalls(void);
uint32_t ppu_function_count(void);
uint32_t ps3_hle_count(void);
}

static uint32_t s_entry_opd;
static int32_t s_ready;

extern "C" uint32_t soulbrandt_ppu_host_load_elf(const char *path)
{
    if (s_ready) return s_entry_opd;
    if (!path || !*path || !soulbrandt_guest_memory_is_ready()) return 0;

    const uint32_t entry = ppu_load_elf(path);
    if (!entry) return 0;

    /* Match the upstream boot order: image first, then generated code and HLE. */
    ppu_recomp_register();
    ppu_hle_init();
    ppu_sysprx_register();
    ppu_fs_register();
    lv2_init_syscalls();

    s_entry_opd = entry;
    s_ready = 1;
    return s_entry_opd;
}

extern "C" uint32_t soulbrandt_ppu_host_function_count(void)
{
    return ppu_function_count();
}

extern "C" uint32_t soulbrandt_ppu_host_hle_count(void)
{
    return ps3_hle_count();
}

extern "C" int32_t soulbrandt_ppu_host_is_ready(void)
{
    return s_ready;
}
