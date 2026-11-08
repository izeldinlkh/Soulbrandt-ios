# iOS PPU boot integration audit

This note records what the first ARM64 PPU-host archive actually proves and the integration shape for the next stage.

## Verified in CI

Workflow run [42300874615](https://github.com/izeldinlkh/Soulbrandt-ios/actions/runs/42300874615) completed successfully on 2026-11-06:
- The pinned upstream ppu_loader.cpp, ppu_hle.cpp, ppu_fs.cpp, and ppu_sysprx.cpp compile for arm64-apple-ios16.0.
- The generated all-module ppu_hle_nids.cpp compiles for the same target.
- Those objects archive into libSoulbrandtPPUHost.a.
- The generic ps3recomp_runtime archive and unsigned iOS app/IPA also build.
- The PPU host archive is linked into the iOS app target, with a no-game fallback function table so the shell can link before title-derived code exists. The fallback registers zero lifted functions; no game code runs yet.
- The upstream PPU ELF loader now delegates PT_LOAD/PT_TLS parsing and memory writes to the app's validated guest ELF loader. It rejects malformed program-header tables and segment ranges instead of skipping bad segments and returning a misleading entry point.
- The PPU host bridge installs and resets the upstream guest-callback dispatcher around image lifetime, and its lifecycle is covered by a Linux smoke test.
- The optional ARM64 game-lift archive builder is tested with synthetic PPU and SPU fixtures, verifies the generated function-table symbols, excludes the duplicate HLE NID table, and is force-loaded by the app target. CI currently builds its no-game marker because private title sources are not present.
- Persistent /dev_hdd0 and /dev_hdd1 roots are configured in the app's Application Support directory before HLE initialization. The disc image remains read-only.

## What the host archive depends on

The archive is the same four-source PPU boot scaffold selected by upstream templates/project/CMakeLists.txt, plus the generated HLE NID registration unit. The generated HLE unit references the runtime implemented HLE handlers; the generic ps3recomp_runtime target builds the corresponding libs/** sources.

The PPU loader expects the title-generated function_table[] and function_table_count. These are emitted with the lifted PPU sources, not supplied by the generic runtime. The current PS3PPUNoGameLift.cpp provides an empty fallback only so the host shell links; ppu_function_count() remains zero, so this fallback cannot execute a game.

## Required boot sequence

The upstream template runner establishes this order:
1. Reserve and initialize the aligned guest address space.
2. Load the decrypted PPU ELF into guest memory and capture its entry OPD and TLS metadata.
3. Register the generated PPU function table with ppu_recomp_register().
4. Register title PRX modules/glue where required.
5. Initialize firmware HLE handlers with ppu_hle_init().
6. Register system PRX HLE handlers with ppu_sysprx_register().
7. Register filesystem HLE handlers with ppu_fs_register().
8. Initialize LV2 syscall dispatch with lv2_init_syscalls().
9. Install the guest-callback bridge, start a frame/FIFO pump, then dispatch the entry OPD with ppu_run().

The iOS host now has an app-owned RSX frame-pump thread that drives GCM vblank/flip callbacks, drains the FIFO between ticks, and presents only completed guest flips. The MTKView remains a drawable owner and does not run a competing render loop. The PPU bridge loads an extracted EBOOT through the bounds-checked guest ELF loader, registers the PPU/HLE/syscall tables, installs the guest callback dispatcher, and starts `ppu_run()` on a detached guest thread. The guest host thread uses the macOS runner's 256 MiB host stack and explicitly configures the 1 MiB guest main stack. The LV2 stack-information syscall reports that configured range even though the registered main context has no per-thread stack record. The title lifter preserves the caller TOC when replacing an HLE import stub that originally saves r2 at 40(r1). The PPU dispatcher also has the macOS port's positive-only thread-local indirect-call cache. The process-entry argv/envp block is reserved on the guest main stack, checked against the exact loaded ELF PT_LOAD ranges, and passed in r3-r6 rather than placed at a fixed data/heap address. Runtime shutdown clears the cached image/callback before unmapping memory; process-wide tables are retained across restart.

## macOS PPU port decisions

The iOS port keeps the pinned iOS lifter's existing guest setjmp/longjmp lowering. It already emits per-function host `setjmp` scopes and guest-buffer matching, so copying the macOS project's separate `ds_guest_setjmp.cpp` would duplicate an older mechanism rather than improve the port. The macOS PPU reservation-filter changes in `ppu_context`/`ppu_memory` are deferred: they coordinate PPU reservations with SPU lock-line notifications and belong with the later SPU integration, not this PPU-only pass.

## iOS-specific build decision

Do not adopt the upstream dynamic split-module loader as the first iOS route. runtime/ppu/game_module.c explicitly supports Windows x64 and x86-64 ELF only; its freestanding libc implementation is likewise x86-specific. The iOS route should statically compile the generated PPU chunks and title registration table into the app target, alongside the PPU host scaffold and generic runtime.

The existing PS3BootImageStore provides the extracted EBOOT path to the PPU ELF loader. Runtime cellFs access uses the imported-disc VFS callbacks, with /dev_bdvd mapped to disc root and /app_home mapped to /PS3_GAME/USRDIR. Persistent /dev_hdd0 and /dev_hdd1 roots now map to Application Support/SoulbrandtStorage; the ISO itself stays read-only. HDD unlink/rmdir now operate on the writable overlays and reject disc paths. Remaining filesystem work is broader syscall/error-semantic coverage and validation against the exact target disc.

## Remaining gates

- Confirm the supported input set: Demon's Souls BLUS30443 v1.00 and its required decrypted boot/firmware assets.
- Supply the private BLUS30443 v1.00 PPU/SPU lift sources and validate their real function/workload registration; CI currently tests only synthetic fixtures and the no-game marker.
- Add an iOS boot coordinator with a safe guest-thread start/stop lifecycle.
- Generate the title-specific PPU lift and function_table, then statically compile and link those sources into the app; the current fallback has zero functions.
- Route real guest RSX commands through the existing Metal backend and prove the first game frame.
- Validate persistent HDD saves/cache writes, directory creation/deletion and error semantics against the target image.
- Profile memory, thermal load and frame pacing on the target iPhone before making any FPS claim.

A successful archive or IPA build is a host-build milestone, not evidence of a bootable game.
