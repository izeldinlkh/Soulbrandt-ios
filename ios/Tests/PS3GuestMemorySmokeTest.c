#include "../SoulbrandtIOS/PS3GuestMemory.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern uint8_t *vm_base;

int main(void)
{
    if (soulbrandt_guest_memory_init() != 0) {
        fprintf(stderr, "guest VM reservation failed\n");
        return 1;
    }
    if (!soulbrandt_guest_memory_is_ready() ||
        soulbrandt_guest_memory_size() != 0x100000000ULL ||
        ((uintptr_t)vm_base & 0xFFFFFFFFULL) != 0) {
        fprintf(stderr, "guest VM alignment/size invariant failed\n");
        return 2;
    }

    /* Touch representative PS3 regions, including DeS's sys_memory window,
     * host-backed heap, RSX local memory, and PPU stack range. */
    const uint32_t addresses[] = {
        0x00010000u, 0x40000000u, 0x60000000u, 0xC0000000u, 0xD0000000u
    };
    for (unsigned i = 0; i < sizeof(addresses) / sizeof(addresses[0]); ++i) {
        uint32_t ea = addresses[i];
        vm_base[ea] = (uint8_t)(i + 0x31u);
        if (vm_base[ea] != (uint8_t)(i + 0x31u)) return 3;
    }

    if (soulbrandt_guest_memory_init() != 0) return 4; /* idempotent */
    soulbrandt_guest_memory_shutdown();
    if (soulbrandt_guest_memory_is_ready()) return 5;
    soulbrandt_guest_memory_shutdown(); /* idempotent */
    puts("PS3 guest VM reservation smoke test passed");
    return 0;
}
