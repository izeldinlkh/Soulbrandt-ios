# iOS guest-memory offload investigation

## Reference implementation

MeloNX 2.7's official release notes (2026-10-11) describe moving guest RAM into an
`NSExtension` process using `xpc_shmem`. The notes specifically say the shared
memory does not contribute to the main app's `phys_footprint`. The same release also
mentions GPU-buffer eviction under memory pressure.

Reference: https://starforgejo.dev/projects/MeloNX/releases

This is a process-accounting and memory-ownership technique, not additional physical
RAM. The shared pages still consume system memory and the extension can be subject
to lifecycle and memory-pressure termination.

## Soulbrandt's current memory contract

- The PPU runtime uses a flat 32-bit guest address space: `host = vm_base + guest_ea`.
- `vm_base` must be aligned to a 4-GiB boundary. Some runtime paths recover guest
  addresses by truncating the low 32 bits of a host pointer.
- `ppu_vm_size == 0` means the full 32-bit guest address range is backed.
- The iOS shell now reserves one contiguous 4-GiB anonymous read/write mapping and
  relies on the OS to back pages as they are first touched. This is a virtual
  reservation; it does not allocate 4 GiB of resident RAM.
- The DeS heap occupies guest addresses `0x60000000–0xC0000000`; RSX resources and
  other guest regions also live inside the same flat address space.

## Feasibility

The MeloNX approach is worth prototyping, but it cannot be copied directly.

1. The main process must still see a single contiguous guest address space, with
   the required 4-GiB alignment. A normal `xpc_shmem_map` mapping may return an
   arbitrary host address; that does not automatically satisfy the runtime's
   pointer-to-guest-address assumptions.
2. We need to establish whether the shared pages can be remapped into a reserved,
   correctly aligned guest range on iOS, or whether the runtime's pointer-to-EA
   conversions can be changed safely to use `host_pointer - vm_base`.
3. Offloading a subset such as the large DeS heap may be a smaller first prototype
   than sharing the entire 4-GiB guest address space. This still requires a
   contiguous mapping at the correct guest offsets.
4. Shared memory can reduce the main app's reported physical footprint, but it
   does not reduce total system RAM use. The extension's lifecycle, jetsam behavior,
   memory-pressure handling, and cross-process synchronization must be tested on
   the target iPhone.
5. Metal textures, render targets, and command buffers are separate allocations.
   Shared guest RAM does not automatically move those GPU resources out of the
   app's footprint; cache eviction remains a separate optimization.

## Prototype plan

1. Measure the current app and extension-free guest-memory baseline on the iPhone 14.
2. Build a minimal extension-backed `xpc_shmem` experiment (start with a small region,
   not multiple gigabytes) and verify cross-process reads/writes.
3. Test whether the shared mapping can occupy an aligned guest-memory range without
   breaking `vm_base + ea` or pointer-to-EA conversions.
4. Run synthetic PPU memory and SPU DMA tests against the shared region.
5. Measure main-app `phys_footprint`, extension footprint, total resident memory,
   frame pacing, and behavior when iOS applies memory pressure.
6. Integrate only if the target device shows a measurable stability benefit.

Do not replace the current allocator until the prototype proves the mapping and
lifecycle assumptions. The existing aligned allocator remains the baseline.
