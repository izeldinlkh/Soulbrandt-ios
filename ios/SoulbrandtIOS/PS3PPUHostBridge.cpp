#include "PS3PPUHostBridge.h"
#include "PS3GuestMemory.h"

#include <stdint.h>
#include <mutex>

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

typedef void (*soulbrandt_guest_caller_fn)(uint32_t opd_addr,
                                           uint64_t arg0, uint64_t arg1,
                                           uint64_t arg2, uint64_t arg3,
                                           uint64_t arg4, uint64_t arg5,
                                           uint64_t arg6, uint64_t arg7);

extern "C" {
extern soulbrandt_guest_caller_fn g_ps3_guest_caller;
uint64_t ppu_guest_call(uint32_t opd_addr,
                        uint64_t arg0, uint64_t arg1, uint64_t arg2, uint64_t arg3,
                        uint64_t arg4, uint64_t arg5, uint64_t arg6, uint64_t arg7);
}

static void soulbrandt_guest_callback(uint32_t opd_addr,
                                      uint64_t arg0, uint64_t arg1,
                                      uint64_t arg2, uint64_t arg3,
                                      uint64_t arg4, uint64_t arg5,
                                      uint64_t arg6, uint64_t arg7)
{
    (void)ppu_guest_call(opd_addr, arg0, arg1, arg2, arg3,
                         arg4, arg5, arg6, arg7);
}

static uint32_t s_entry_opd;
static int32_t s_ready;
static int32_t s_tables_registered;
static std::mutex s_host_mutex;

extern "C" uint32_t soulbrandt_ppu_host_load_elf(const char *path)
{
    std::lock_guard<std::mutex> lock(s_host_mutex);
    if (s_ready) return s_entry_opd;
    if (!path || !*path || !soulbrandt_guest_memory_is_ready()) return 0;

    const uint32_t entry = ppu_load_elf(path);
    if (!entry) return 0;

    /* Registration tables are process-wide; load the image again after a
     * guest-memory reset without registering duplicate HLE/syscall handlers. */
    if (!s_tables_registered) {
        ppu_recomp_register();
        ppu_hle_init();
        ppu_sysprx_register();
        ppu_fs_register();
        lv2_init_syscalls();
        s_tables_registered = 1;
    }

    /* GCM vblank/flip and other HLE callbacks must re-enter lifted guest code. */
    g_ps3_guest_caller = soulbrandt_guest_callback;
    s_entry_opd = entry;
    s_ready = 1;
    return s_entry_opd;
}

extern "C" void soulbrandt_ppu_host_reset_image(void)
{
    std::lock_guard<std::mutex> lock(s_host_mutex);
    s_entry_opd = 0;
    s_ready = 0;
    g_ps3_guest_caller = nullptr;
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
    std::lock_guard<std::mutex> lock(s_host_mutex);
    return s_ready;
}
