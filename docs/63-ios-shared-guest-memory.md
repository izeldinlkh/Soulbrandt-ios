# iOS guest-memory offload feasibility: MeloNX 2.7

## Finding

MeloNX 2.7's release notes describe moving guest RAM into a separate NSExtension process and sharing it with the app through `xpc_shmem`. The stated benefit is that those pages no longer contribute to the main app's `phys_footprint`; the release notes explicitly say its in-app memory-limit tester does not include the offloaded pages.

This is a relevant direction for Soulbrandt, but it is not a drop-in allocator change and it does not make the device have more physical RAM. It moves memory accounting across process boundaries. The extension still consumes real system memory, and iOS can still terminate either process under system-wide pressure.

## Current Soulbrandt constraint

`ios/SoulbrandtIOS/PS3GuestMemory.c` reserves a 4-GiB guest address range by over-mapping 8 GiB and trimming the prefix/suffix until `vm_base` is 4-GiB aligned. This is intentional: ps3recomp fast paths truncate host pointers to their low 32 bits to recover guest effective addresses. The mapping is anonymous and demand-paged; reserving 4 GiB does not immediately commit 4 GiB of physical RAM.

The guest address space is directly dereferenced throughout lifted PPU code and the runtime. It is not a small collection of buffers that can be redirected through a copy API. ELF loading, big-endian memory helpers, SPU DMA, RSX uploads, HLE pointer translation, and every generated PPU load/store depend on the same stable `vm_base`.

## What could transfer

- The architectural idea of a second process owning guest-memory backing pages is applicable.
- A shared-memory object could, in principle, let the app and extension see the same bytes without copying each guest read/write.
- The app could continue to own UIKit, Metal presentation, audio, controller input, and orchestration while a worker/extension process owns the guest VM and CPU execution.
- A narrow C ABI for create/map/unmap/health-check operations would keep the platform-specific implementation out of ps3recomp.

## Hard blockers to resolve before implementation

1. **Address placement and alignment.** The current 4-GiB-aligned `vm_base` invariant must survive. A shared-memory API that only maps at an arbitrary address is not compatible. We need to verify whether the chosen iOS shared-memory mechanism can be mapped at a caller-selected, 4-GiB-aligned address without replacing the reservation with unrelated pages.
2. **API availability.** The MeloNX release notes name `xpc_shmem`, but do not establish that the exact API surface is public, App-Store-safe, or available to this deployment target. Verify headers, symbols, entitlements, and runtime behavior on iOS 16 before depending on it. Do not silently add private API calls to the shipping target.
3. **Extension lifecycle.** iOS extensions are system-managed and may be suspended or terminated. The game worker needs explicit startup, liveness, crash, restart, and shared-memory invalidation handling. A game must not continue using a stale `vm_base` after the extension dies.
4. **Threading and callbacks.** PPU execution, SPU jobs, HLE callbacks, and the RSX frame pump currently assume in-process function calls and globals. Cross-process execution requires an RPC/message boundary for host services and a redesigned callback path; simply moving the 4-GiB mapping would not make those globals shared.
5. **Metal and GPU resources.** Guest CPU memory and Metal resources have different ownership and synchronization requirements. Shared CPU pages do not automatically make textures/buffers zero-copy or Metal-visible.
6. **Total memory pressure.** The technique may reduce the app process's reported footprint, but the same physical pages remain resident somewhere. It is not a substitute for reducing the 4-GiB reservation's committed pages, avoiding duplicate asset copies, or managing RSX caches.

## Recommended experiment order

1. Keep the current anonymous VM as the baseline and add measurements for resident/physical footprint, peak committed guest pages, and allocation failures on the iPhone 14.
2. Build a tiny standalone iOS app + extension proof of concept that creates one shared region, maps it in both processes, verifies bidirectional writes, survives extension relaunch, and reports each process's footprint. Do not involve the emulator yet.
3. Prove the shared region can occupy the required 4-GiB-aligned guest range. If this cannot be demonstrated with supported APIs, stop this route rather than rewriting the PPU memory model around an incompatible mapping.
4. If address placement works, move only the guest-memory owner into the extension and expose a stable mapping handle to the app. Then audit all memory accesses and process callbacks before attempting a game boot.
5. Compare real-device peak memory and stability against the baseline. Treat lower main-app `phys_footprint` as an accounting result, not proof of lower total device memory use.

## Decision

**Promising research direction; not yet safe to integrate into the emulator.** MeloNX 2.7 demonstrates that process-separated guest RAM can help with iOS per-process memory limits, but Soulbrandt's aligned 4-GiB direct-address guest VM and tightly coupled in-process PPU/HLE/RSX runtime make the port substantially more invasive. First deliver a minimal extension/shared-memory proof of concept and prove fixed-address mapping. Until then, retain the current VM implementation.
