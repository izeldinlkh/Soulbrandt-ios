#include "PS3PPUHostBridge.h"

#include <cassert>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <atomic>
#include <thread>

typedef void (*ps3_guest_caller_fn)(uint32_t opd_addr,
                                    uint64_t arg0, uint64_t arg1,
                                    uint64_t arg2, uint64_t arg3,
                                    uint64_t arg4, uint64_t arg5,
                                    uint64_t arg6, uint64_t arg7);
extern "C" {
ps3_guest_caller_fn g_ps3_guest_caller = nullptr;
uint32_t g_ppu_main_stack_addr = 0;
uint32_t g_ppu_main_stack_size = 0;
}

static uint32_t g_guest_opd;
static uint64_t g_guest_args[8];
static unsigned g_guest_call_count;
static std::atomic<int> g_run_called{0};
static uint32_t g_run_stack_top;

extern "C" uint64_t ppu_guest_call(uint32_t opd_addr,
                                    uint64_t arg0, uint64_t arg1,
                                    uint64_t arg2, uint64_t arg3,
                                    uint64_t arg4, uint64_t arg5,
                                    uint64_t arg6, uint64_t arg7)
{
    g_guest_opd = opd_addr;
    const uint64_t args[8] = {arg0, arg1, arg2, arg3, arg4, arg5, arg6, arg7};
    std::memcpy(g_guest_args, args, sizeof(args));
    ++g_guest_call_count;
    return 0x1234u;
}

static bool g_memory_ready = false;
static unsigned g_load_calls = 0;
static unsigned g_recomp_register_calls = 0;
static unsigned g_hle_init_calls = 0;
static unsigned g_sysprx_register_calls = 0;
static unsigned g_fs_register_calls = 0;
static unsigned g_syscall_init_calls = 0;
static unsigned g_paramsfo_init_calls = 0;

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
extern "C" void cellGame_init_from_paramsfo(const char *path) { assert(path && std::strlen(path) > 0); ++g_paramsfo_init_calls; }
extern "C" int ppu_run(uint32_t, uint32_t stack_top)
{
    g_run_stack_top = stack_top;
    assert(g_ppu_main_stack_addr == 0x0FE00000u);
    assert(g_ppu_main_stack_size == 0x00100000u);
    g_run_called.store(1, std::memory_order_release);
    return 0;
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
    unsetenv("PS3_HDD0_ROOT");
    unsetenv("PS3_HDD1_ROOT");
    assert(soulbrandt_ppu_host_set_storage_roots("/tmp/soulbrandt-hdd0", "/tmp/soulbrandt-hdd1") == 0);
    assert(std::strcmp(std::getenv("PS3_HDD0_ROOT"), "/tmp/soulbrandt-hdd0") == 0);
    assert(std::strcmp(std::getenv("PS3_HDD1_ROOT"), "/tmp/soulbrandt-hdd1") == 0);
    assert(soulbrandt_ppu_host_set_storage_roots(nullptr, "/tmp/soulbrandt-hdd1") == -1);

    assert(soulbrandt_ppu_host_load_elf("/disc/EBOOT.ELF") == 0);
    assert(g_load_calls == 0);
    assert(soulbrandt_ppu_host_is_ready() == 0);

    assert(soulbrandt_ppu_host_set_storage_roots(
        "/tmp/soulbrandt-test-hdd0", "/tmp/soulbrandt-test-hdd1") == 0);
    assert(std::strcmp(std::getenv("PS3_HDD0_ROOT"), "/tmp/soulbrandt-test-hdd0") == 0);
    assert(std::strcmp(std::getenv("PS3_HDD1_ROOT"), "/tmp/soulbrandt-test-hdd1") == 0);

    assert(soulbrandt_ppu_host_init_title_metadata("/disc/PS3_GAME/PARAM.SFO") == 0);
    assert(g_paramsfo_init_calls == 1);
    g_memory_ready = true;
    assert(soulbrandt_ppu_host_load_elf("/disc/EBOOT.ELF") == 0x1000u);
    assert(soulbrandt_ppu_host_is_ready() == 1);
    assert(soulbrandt_ppu_host_init_title_metadata("/other/PARAM.SFO") == -1);
    assert(soulbrandt_ppu_host_function_count() == 42);
    assert(soulbrandt_ppu_host_hle_count() == 84);
    assert(g_ps3_guest_caller != nullptr);
    assert(soulbrandt_ppu_host_set_storage_roots("/tmp/soulbrandt-test-hdd0", "/tmp/soulbrandt-test-hdd1") == 0);
    assert(soulbrandt_ppu_host_set_storage_roots("/tmp/other-hdd0", "/tmp/other-hdd1") == -2);
    g_ps3_guest_caller(0xABCDEF00u, 1, 2, 3, 4, 5, 6, 7, 8);
    assert(g_guest_call_count == 1 && g_guest_opd == 0xABCDEF00u);
    for (unsigned i = 0; i < 8; ++i) assert(g_guest_args[i] == i + 1);
    assert(soulbrandt_ppu_host_load_elf("/different/EBOOT.ELF") == 0x1000u);
    assert(g_load_calls == 1);
    assert(soulbrandt_ppu_host_set_storage_roots(
        "/tmp/soulbrandt-test-hdd0", "/tmp/soulbrandt-test-hdd1") == 0);
    assert(soulbrandt_ppu_host_set_storage_roots(
        "/tmp/other-hdd0", "/tmp/other-hdd1") == -2);

    soulbrandt_ppu_host_reset_image();
    assert(soulbrandt_ppu_host_is_ready() == 0);
    assert(g_ps3_guest_caller == nullptr);
    assert(soulbrandt_ppu_host_load_elf("/disc/EBOOT.ELF") == 0x2000u);
    assert(g_ps3_guest_caller != nullptr);
    assert(g_load_calls == 2);

    // Process-wide registration tables must not be duplicated on restart.
    assert(g_recomp_register_calls == 1);
    assert(g_hle_init_calls == 1);
    assert(g_sysprx_register_calls == 1);
    assert(g_fs_register_calls == 1);
    assert(g_syscall_init_calls == 1);
    soulbrandt_ppu_host_reset_image();
    assert(g_ps3_guest_caller == nullptr);
    return 0;
}
