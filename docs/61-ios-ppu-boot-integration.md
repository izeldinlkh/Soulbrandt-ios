# iOS PPU boot integration boundary

This note records what is genuinely connected and what still blocks a game boot.

## Linked and exercised in the iOS target

- ISO-9660/Joliet and UDF readers, plus chunked extraction of a decrypted
  `PS3_GAME/USRDIR/EBOOT.ELF` or ELF-form `EBOOT.BIN`.
- A read-only ISO-backed VFS wired into the patched upstream `ppu_fs.cpp` /
  `cellFs` path. `/dev_bdvd` resolves to the disc root and `/app_home` resolves
  to `/PS3_GAME/USRDIR`. Linux smoke tests cover open/read/seek/stat/list and
  reject traversal outside the image.
- The upstream PPU host scaffold (`ppu_loader.cpp`, `ppu_hle.cpp`,
  `ppu_fs.cpp`, `ppu_sysprx.cpp`) and generated HLE NID table, compiled as an
  iOS ARM64 archive and linked into the app alongside the generic runtime.
- The app's EBOOT action calls upstream `ppu_load_elf`, then
  `ppu_recomp_register`, `ppu_hle_init`, `ppu_sysprx_register`,
  `ppu_fs_register` and `lv2_init_syscalls`.
- The RSX frame pump starts/stops with the runtime. It drives 59.94 Hz GCM
  ticks, drains the FIFO every 4 ms, dispatches pending vblank/flip callbacks
  and presents only at a completed flip boundary. Scheduler and lifecycle
  smoke tests pass.
- The guest address-space manager reserves a 4-GiB-aligned virtual region and
  owns `vm_base`; upstream `ppu_loader` owns `ppu_vm_size`.

These are host and loader milestones, **not proof that the game boots**.

## The missing game execution link

ps3recomp is a **static recompiler**, not a general PPU interpreter. Its
supported game pipeline generates native C/C++ from the matching retail EBOOT.
Those generated translation units and their function table must be compiled
into the iOS app (or a separately built compatible native module).

The current IPA deliberately supplies an empty `function_table` so the PPU
host can be linked before the game-specific lift exists. Therefore the app
does not call `ppu_run` and executes no guest PPU instructions. Copying ELF
segments into RAM is not equivalent to executing them.

## Game-specific inputs and build constraints

The existing desktop setup targets the US BLUS30443 v1.00 dump and expects 28
decrypted game/firmware inputs. The iOS importer currently extracts the EBOOT
but does not run the complete title-specific lift pipeline, compile its
generated units for arm64, or package all required inputs. An arbitrary ISO
selected in the app cannot become a runnable game by itself; runtime JIT is
not part of this port.

Next, the build needs a reproducible arm64 lift pipeline that consumes the
matching user-owned EBOOT and produces:
- the generated PPU function table and native translation units;
- the title-specific registration/override code;
- the SPU workload table and SPURS integration;
- the required decrypted firmware/PRX inputs, including the supported
  `libsre.prx` variant.

## VFS and storage boundary

The disc VFS is read-only. It supports the runtime's disc-file path and
directory operations, but does not yet provide writable `/dev_hdd0` or
`/dev_hdd1` storage overlays. Save data, caches and other writes therefore
remain blocked. The path mapping still needs validation against the exact
target disc image.

## Renderer boundary

The RSX Metal backend is linked to the app's `CAMetalLayer`. The frame pump
advances the GCM clock, drains the FIFO and presents completed flips. The
animated MTKView triangle remains only a synthetic presentation test. A real
game frame requires guest PPU code to initialize cellGcm and submit real RSX
commands; no empty FIFO drain or successful backend initialization counts as
game rendering.

## Ordered next milestones

1. Validate the VFS against the supported BLUS30443 image and add writable
   HDD overlays for save/cache paths.
2. Build a reproducible arm64 PPU-lift pipeline for the exact supported EBOOT
   and package the resulting game function table/native units into the IPA.
3. Load the required game/firmware PRX modules and complete HLE registration.
4. Set up the guest main thread's TLS, OPD and stack correctly, then dispatch
   through upstream `ppu_run` and prove the first guest instructions execute.
5. Bring up the title's SPU workloads and SPURS scheduler.
6. Validate real guest GCM submissions, Metal presentation, audio and saves;
   then profile CPU/GPU frame time, memory and thermal behaviour on iPhone 14.
