#define _DEFAULT_SOURCE 1
#include "PS3GuestMemory.h"

#include <stddef.h>
#include <stdint.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>

#if defined(__APPLE__)
#define SOULBRANDT_MAP_ANON MAP_ANON
#else
#define SOULBRANDT_MAP_ANON MAP_ANONYMOUS
#endif

#define SOULBRANDT_VM_SIZE ((uintptr_t)0x100000000ULL)
#define SOULBRANDT_VM_RESERVE_SIZE (SOULBRANDT_VM_SIZE * 2u)

/* These are the canonical globals consumed by ps3recomp's PPU memory helpers.
 * ppu_vm_size stays zero: with a 4-GiB-aligned base, the runtime uses the full
 * 32-bit address range and the fast accessors do not apply a smaller bound. */
uint8_t *vm_base = NULL;
uint32_t ppu_vm_size = 0;

static pthread_mutex_t s_vm_mutex = PTHREAD_MUTEX_INITIALIZER;

int32_t soulbrandt_guest_memory_init(void)
{
    pthread_mutex_lock(&s_vm_mutex);
    if (vm_base) {
        pthread_mutex_unlock(&s_vm_mutex);
        return 0;
    }

#if UINTPTR_MAX < 0xFFFFFFFFFFFFFFFFULL
    pthread_mutex_unlock(&s_vm_mutex);
    return -1;
#else
    /* Over-map 8 GiB, then trim the prefix and suffix. This guarantees that
     * vm_base's low 32 bits are zero instead of relying on mmap's placement. */
    void *raw = mmap(NULL, (size_t)SOULBRANDT_VM_RESERVE_SIZE,
                     PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | SOULBRANDT_MAP_ANON, -1, 0);
    if (raw == MAP_FAILED) {
        pthread_mutex_unlock(&s_vm_mutex);
        return -2;
    }

    uintptr_t raw_addr = (uintptr_t)raw;
    uintptr_t aligned_addr = (raw_addr + SOULBRANDT_VM_SIZE - 1u)
                           & ~(SOULBRANDT_VM_SIZE - 1u);
    uintptr_t raw_end = raw_addr + SOULBRANDT_VM_RESERVE_SIZE;
    uintptr_t aligned_end = aligned_addr + SOULBRANDT_VM_SIZE;

    if (aligned_addr < raw_addr || aligned_end > raw_end) {
        munmap(raw, (size_t)SOULBRANDT_VM_RESERVE_SIZE);
        pthread_mutex_unlock(&s_vm_mutex);
        return -3;
    }

    size_t prefix = (size_t)(aligned_addr - raw_addr);
    size_t suffix = (size_t)(raw_end - aligned_end);
    if (prefix && munmap((void *)raw_addr, prefix) != 0) {
        munmap(raw, (size_t)SOULBRANDT_VM_RESERVE_SIZE);
        pthread_mutex_unlock(&s_vm_mutex);
        return -4;
    }
    if (suffix && munmap((void *)aligned_end, suffix) != 0) {
        munmap((void *)aligned_addr, (size_t)SOULBRANDT_VM_SIZE);
        pthread_mutex_unlock(&s_vm_mutex);
        return -5;
    }

    vm_base = (uint8_t *)aligned_addr;
    if (((uintptr_t)vm_base & (SOULBRANDT_VM_SIZE - 1u)) != 0) {
        munmap(vm_base, (size_t)SOULBRANDT_VM_SIZE);
        vm_base = NULL;
        pthread_mutex_unlock(&s_vm_mutex);
        return -6;
    }

    pthread_mutex_unlock(&s_vm_mutex);
    return 0;
#endif
}

void soulbrandt_guest_memory_shutdown(void)
{
    pthread_mutex_lock(&s_vm_mutex);
    if (vm_base) {
        munmap(vm_base, (size_t)SOULBRANDT_VM_SIZE);
        vm_base = NULL;
        ppu_vm_size = 0;
    }
    pthread_mutex_unlock(&s_vm_mutex);
}

int32_t soulbrandt_guest_memory_is_ready(void)
{
    return vm_base != NULL;
}

uint64_t soulbrandt_guest_memory_size(void)
{
    return (uint64_t)SOULBRANDT_VM_SIZE;
}
