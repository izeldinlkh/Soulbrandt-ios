#define _DEFAULT_SOURCE 1
#include "PS3GuestMemory.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>
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

static uint16_t soulbrandt_be16(const uint8_t *p)
{
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static uint32_t soulbrandt_be32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint64_t soulbrandt_be64(const uint8_t *p)
{
    return ((uint64_t)soulbrandt_be32(p) << 32) | soulbrandt_be32(p + 4);
}

int32_t soulbrandt_guest_load_elf(const void *bytes, uint64_t length,
                                  soulbrandt_guest_elf_info *info)
{
    const uint8_t *file = (const uint8_t *)bytes;
    if (!vm_base || !file || !info || length < 64) return -1;
    if (file[0] != 0x7f || file[1] != 'E' || file[2] != 'L' ||
        file[3] != 'F' || file[4] != 2 || file[5] != 2 || file[6] != 1)
        return -2;
    if (soulbrandt_be16(file + 18) != 21) return -3;

    const uint64_t entry = soulbrandt_be64(file + 24);
    const uint64_t phoff = soulbrandt_be64(file + 32);
    const uint16_t ehsize = soulbrandt_be16(file + 52);
    const uint16_t phentsize = soulbrandt_be16(file + 54);
    const uint16_t phnum = soulbrandt_be16(file + 56);
    if (ehsize < 64 || phentsize < 56 || phnum == 0 || entry == 0 ||
        entry > UINT32_MAX) return -4;
    if (phoff > length || (uint64_t)phnum > (length - phoff) / phentsize)
        return -5;

    soulbrandt_guest_elf_info parsed = {0};
    parsed.entry_opd = (uint32_t)entry;
    int entry_in_load_segment = 0;
    int tls_seen = 0;

    for (uint16_t i = 0; i < phnum; ++i) {
        const uint8_t *ph = file + phoff + (uint64_t)i * phentsize;
        const uint32_t type = soulbrandt_be32(ph);
        if (type == 7) {
            const uint64_t offset = soulbrandt_be64(ph + 8);
            const uint64_t vaddr = soulbrandt_be64(ph + 16);
            const uint64_t filesz = soulbrandt_be64(ph + 32);
            const uint64_t memsz = soulbrandt_be64(ph + 40);
            if (offset > length || filesz > length - offset ||
                vaddr > UINT32_MAX || filesz > UINT32_MAX ||
                memsz > UINT32_MAX || filesz > memsz ||
                vaddr + memsz > SOULBRANDT_VM_SIZE) return -6;
            parsed.tls_vaddr = (uint32_t)vaddr;
            parsed.tls_filesz = (uint32_t)filesz;
            parsed.tls_memsz = (uint32_t)memsz;
            tls_seen = 1;
        } else if (type == 1) {
            const uint64_t offset = soulbrandt_be64(ph + 8);
            const uint64_t vaddr = soulbrandt_be64(ph + 16);
            const uint64_t filesz = soulbrandt_be64(ph + 32);
            const uint64_t memsz = soulbrandt_be64(ph + 40);
            if (filesz > memsz || offset > length || filesz > length - offset ||
                vaddr > UINT32_MAX || memsz > SOULBRANDT_VM_SIZE ||
                vaddr + memsz > SOULBRANDT_VM_SIZE) return -7;
            if (entry >= vaddr && entry < vaddr + memsz)
                entry_in_load_segment = 1;
            parsed.load_segment_count++;
        }
    }
    if (parsed.load_segment_count == 0) return -8;
    if (!entry_in_load_segment) return -9;
    if (tls_seen) {
        int tls_in_load_segment = 0;
        const uint64_t tls_start = parsed.tls_vaddr;
        const uint64_t tls_end = tls_start + parsed.tls_memsz;
        for (uint16_t i = 0; i < phnum; ++i) {
            const uint8_t *ph = file + phoff + (uint64_t)i * phentsize;
            if (soulbrandt_be32(ph) != 1) continue;
            const uint64_t vaddr = soulbrandt_be64(ph + 16);
            const uint64_t memsz = soulbrandt_be64(ph + 40);
            if (tls_start >= vaddr && tls_end <= vaddr + memsz) {
                tls_in_load_segment = 1;
                break;
            }
        }
        if (!tls_in_load_segment) return -10;
    }

    for (uint16_t i = 0; i < phnum; ++i) {
        const uint8_t *ph = file + phoff + (uint64_t)i * phentsize;
        if (soulbrandt_be32(ph) != 1) continue;
        const uint64_t offset = soulbrandt_be64(ph + 8);
        const uint64_t vaddr = soulbrandt_be64(ph + 16);
        const uint64_t filesz = soulbrandt_be64(ph + 32);
        const uint64_t memsz = soulbrandt_be64(ph + 40);
        if (filesz) memcpy(vm_base + (uint32_t)vaddr, file + offset, (size_t)filesz);
        if (memsz > filesz)
            memset(vm_base + (uint32_t)vaddr + filesz, 0, (size_t)(memsz - filesz));
    }
    *info = parsed;
    return 0;
}
