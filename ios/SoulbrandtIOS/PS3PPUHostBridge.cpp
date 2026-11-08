#include "PS3PPUHostBridge.h"
#include "PS3GuestMemory.h"

#include <stdint.h>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <pthread.h>

extern "C" {
uint32_t ppu_load_elf(const char *path);
void ppu_recomp_register(void);
void ppu_hle_init(void);
void ppu_sysprx_register(void);
void ppu_fs_register(void);
void lv2_init_syscalls(void);
void cellGame_init_from_paramsfo(const char *sfo_path);
int ppu_run(uint32_t entry_opd, uint32_t stack_top);
/* Match the macOS runner: sys_ppu_thread_get_stack_information must report
 * the same guest stack that the main PPU context actually uses. */
extern uint32_t g_ppu_main_stack_addr;
extern uint32_t g_ppu_main_stack_size;
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

/* Ported from demons-souls-recomp/project/main.cpp. These are guest
 * addresses, not host pointers. The host stack is separately reserved below. */
static constexpr uint32_t kGuestMainStackTop = 0x0FF00000u;
static constexpr uint32_t kGuestMainStackSize = 0x00100000u;
static constexpr size_t kGuestHostStackSize = 256u * 1024u * 1024u;

static uint32_t s_entry_opd;
static int32_t s_ready;
static int32_t s_tables_registered;
static int32_t s_run_state; /* 0=not started, 1=running, 2=returned */
static int32_t s_run_result;
static std::mutex s_host_mutex;

extern "C" int32_t soulbrandt_ppu_host_set_storage_roots(const char *hdd0_root,
                                                              const char *hdd1_root)
{
    std::lock_guard<std::mutex> lock(s_host_mutex);
    if (!hdd0_root || !*hdd0_root || !hdd1_root || !*hdd1_root) return -1;
    const char *current_hdd0 = ::getenv("PS3_HDD0_ROOT");
    const char *current_hdd1 = ::getenv("PS3_HDD1_ROOT");
    if (s_tables_registered) {
        return current_hdd0 && current_hdd1 &&
               ::strcmp(current_hdd0, hdd0_root) == 0 &&
               ::strcmp(current_hdd1, hdd1_root) == 0 ? 0 : -2;
    }
    if (::setenv("PS3_HDD0_ROOT", hdd0_root, 1) != 0) return -3;
    if (::setenv("PS3_HDD1_ROOT", hdd1_root, 1) != 0) return -4;
    return 0;
}
extern "C" int32_t soulbrandt_ppu_host_init_title_metadata(const char *paramsfo_path)
{
    std::lock_guard<std::mutex> lock(s_host_mutex);
    if (s_ready || !paramsfo_path || !*paramsfo_path) return -1;
    /* Match the upstream boot harness: title ID/name/version must be loaded
     * from PARAM.SFO before the guest asks cellGame for content paths. */
    cellGame_init_from_paramsfo(paramsfo_path);
    return 0;
}

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
    if (s_run_state == 1) return; /* guest still owns vm_base and the runtime */
    s_entry_opd = 0;
    s_ready = 0;
    s_run_state = 0;
    s_run_result = 0;
    g_ps3_guest_caller = nullptr;
}

static void *soulbrandt_ppu_run_thread(void *)
{
    /* Match the upstream des_boot harness' default main guest stack. Keep the
     * long-running guest off the Swift/UI thread; ppu_run owns its PPU context. */
    (void)::setenv("PS3_BOOT_PATH", "/dev_bdvd/PS3_GAME/USRDIR/EBOOT.BIN", 1);
    const int result = ppu_run(s_entry_opd, kGuestMainStackTop);
    std::lock_guard<std::mutex> lock(s_host_mutex);
    s_run_result = result;
    s_run_state = 2;
    return nullptr;
}

extern "C" int32_t soulbrandt_ppu_host_start_game(void)
{
    std::lock_guard<std::mutex> lock(s_host_mutex);
    if (!s_ready || !s_entry_opd) return -1;
    if (ppu_function_count() == 0) return -2; /* never dispatch the empty fallback table */
    if (s_run_state != 0) return -3;          /* one boot per loaded image/process */
    pthread_attr_t attr;
    if (pthread_attr_init(&attr) != 0) return -4;
    /* The macOS PPU runner reserves 256 MiB for the host stack. The lifted
     * guest's call/trampoline chains can exceed the old 8 MiB iOS stack; keep
     * the main PPU thread consistent with sys_ppu_thread_create workers. */
    const int stack_result = pthread_attr_setstacksize(&attr, kGuestHostStackSize);
    if (stack_result != 0) {
        pthread_attr_destroy(&attr);
        return -5;
    }
    /* Same 1 MiB guest main stack and bounds advertised by the macOS runner. */
    g_ppu_main_stack_addr = kGuestMainStackTop - kGuestMainStackSize;
    g_ppu_main_stack_size = kGuestMainStackSize;

    pthread_t thread;
    s_run_state = 1;
    const int create_result = pthread_create(&thread, &attr, soulbrandt_ppu_run_thread, nullptr);
    pthread_attr_destroy(&attr);
    if (create_result != 0) {
        s_run_state = 0;
        return -6;
    }
    const int detach_result = pthread_detach(thread);
    if (detach_result != 0) {
        /* The thread is already running; do not pretend it can be cancelled. */
        return -7;
    }
    return 0;
}

extern "C" int32_t soulbrandt_ppu_host_is_running(void)
{
    std::lock_guard<std::mutex> lock(s_host_mutex);
    return s_run_state == 1;
}

extern "C" int32_t soulbrandt_ppu_host_run_result(void)
{
    std::lock_guard<std::mutex> lock(s_host_mutex);
    return s_run_state == 2 ? s_run_result : INT32_MIN;
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
