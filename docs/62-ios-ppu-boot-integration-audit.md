# iOS PPU boot integration audit

This note records what the first ARM64 PPU-host archive actually proves and the integration shape for the next stage.

## Verified in CI

Workflow run [42295164427](https://github.com/izeldinlkh/Soulbrandt-ios/actions/runs/42295164427) completed successfully on 2026-11-06:
- The pinned upstream ppu_loader.cpp, ppu_hle.cpp, ppu_fs.cpp, and ppu_sysprx.cpp compile for arm64-apple-ios16.0.
- The generated all-module ppu_hle_nids.cpp compiles for the same target.
- Those objects archive into libSoulbrandtPPUHost.a.
- The generic ps3recomp_runtime archive and unsigned iOS app/IPA also build.
- The PPU host archive is now linked into the iOS app target, with a no-game fallback function table so the shell can link before title-derived code exists. No guest code runs yet.

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

The iOS host now has an app-owned RSX frame-pump thread that drives GCM vblank/flip callbacks, drains the FIFO between ticks, and presents only completed guest flips. The MTKView remains a drawable owner and does not run a competing render loop. The PPU bridge loads an extracted EBOOT and calls the upstream registration sequence, but still does not dispatch ppu_run().

## iOS-specific build decision

Do not adopt the upstream dynamic split-module loader as the first iOS route. runtime/ppu/game_module.c explicitly supports Windows x64 and x86-64 ELF only; its freestanding libc implementation is likewise x86-specific. The iOS route should statically compile the generated PPU chunks and title registration table into the app target, alongside the PPU host scaffold and generic runtime.

The existing PS3BootImageStore can provide the extracted EBOOT path to the PPU ELF loader. Runtime cellFs access still needs to use the imported-disc VFS callbacks, with /dev_bdvd mapped to disc root and /app_home mapped to /PS3_GAME/USRDIR. Save/cache paths require a writable sandbox overlay; the ISO itself stays read-only.

## Remaining gates

- Generate the title lift and verify the exact supported game/firmware input set.
- Compile all generated PPU chunks for ARM64 and resolve title-specific overrides/hooks.
- Generate and compile the title SPU image/job workloads; connect SPURS registration and dispatch.
- Add an iOS boot coordinator that owns the ordered initialization/teardown above.
- Link the host archive and generated title objects into the app; verify no unresolved host symbols.
- Route real guest RSX commands through the existing Metal backend and prove the first game frame.
- Implement persistent writable storage for saves and game data.
- Profile memory, thermal load and frame pacing on the target iPhone before making any FPS claim.

A successful archive or IPA build is a host-build milestone, not evidence of a bootable game.
