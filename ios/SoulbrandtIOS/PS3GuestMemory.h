#ifndef SOULBRANDT_GUEST_MEMORY_H
#define SOULBRANDT_GUEST_MEMORY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Reserve the complete 32-bit PS3 guest address space. The returned base is
 * exactly 4 GiB aligned because ps3recomp converts some host pointers back to
 * guest EAs by truncating their low 32 bits. The 4 GiB mapping is virtual;
 * anonymous pages are backed lazily as the guest touches them. */
int32_t soulbrandt_guest_memory_init(void);
void soulbrandt_guest_memory_shutdown(void);
int32_t soulbrandt_guest_memory_is_ready(void);
uint64_t soulbrandt_guest_memory_size(void);

#ifdef __cplusplus
}
#endif
#endif
