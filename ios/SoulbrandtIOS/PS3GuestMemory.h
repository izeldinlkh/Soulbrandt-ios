#ifndef SOULBRANDT_GUEST_MEMORY_H
#define SOULBRANDT_GUEST_MEMORY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SOULBRANDT_GUEST_MAX_LOAD_RANGES 128

typedef struct soulbrandt_guest_elf_range {
    uint64_t begin;
    uint64_t end;
} soulbrandt_guest_elf_range;

typedef struct soulbrandt_guest_elf_info {
    uint32_t entry_opd;
    uint32_t tls_vaddr;
    uint32_t tls_filesz;
    uint32_t tls_memsz;
    uint32_t load_segment_count;
    uint64_t load_min_vaddr;
    uint64_t load_max_vaddr;
    uint32_t load_range_count;
    soulbrandt_guest_elf_range load_ranges[SOULBRANDT_GUEST_MAX_LOAD_RANGES];
} soulbrandt_guest_elf_info;

/* Reserve the complete 32-bit PS3 guest address space. The returned base is
 * exactly 4 GiB aligned because ps3recomp converts some host pointers back to
 * guest EAs by truncating their low 32 bits. The 4 GiB mapping is virtual;
 * anonymous pages are backed lazily as the guest touches them. */
int32_t soulbrandt_guest_memory_init(void);
void soulbrandt_guest_memory_shutdown(void);
int32_t soulbrandt_guest_memory_is_ready(void);
uint64_t soulbrandt_guest_memory_size(void);

/* Load a decrypted big-endian ELF64 PowerPC64 image into the reserved guest VM.
 * Validates the complete program-header table and every PT_LOAD range before
 * modifying guest memory. Returns 0 on success, negative on malformed input. */
int32_t soulbrandt_guest_load_elf(const void *bytes, uint64_t length,
                                  soulbrandt_guest_elf_info *info);

#ifdef __cplusplus
}
#endif
#endif
