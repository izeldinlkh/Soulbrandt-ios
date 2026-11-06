# iOS bring-up (prototype)

This directory contains the native iOS shell and the first linked layers of the Soulbrandt port. It is still not a playable port.

## Implemented

- SwiftUI app entry point and ISO file picker. The selected image is copied into Application Support off the main thread and the imported name/inspection summary survive relaunches.
- ISO-9660/Joliet and UDF disc readers with bounded random-access reads. UDF is provided by the LGPL-2.1 libudfread submodule.
- Decrypted EBOOT extraction and validation.
- A read-only ISO-backed runtime VFS wired into patched upstream `cellFs`: `/dev_bdvd` maps to disc root and `/app_home` maps to `/PS3_GAME/USRDIR`.
- The app loads a decrypted EBOOT through upstream `ppu_load_elf`, then registers the PPU function table, HLE NIDs, sysPrx CRT, `cellFs`, and LV2 syscall table.
- Separate iOS ARM64 static archives for the generic ps3recomp runtime and PPU host scaffold. The PPU archive is force-loaded so its generated HLE NID registration table is retained despite the upstream weak fallback.
- A 4-GiB-aligned, demand-backed PS3 guest address-space reservation. `PS3GuestMemory` owns `vm_base`; upstream `ppu_loader` owns `ppu_vm_size`. The mapping is virtual; physical pages are backed on demand.
- A native MetalKit drawable surface backed by CAMetalLayer. The patched RSX Metal backend owns drawable acquisition, command encoding and presentation; MTKView does not run a competing render loop.
- A dedicated RSX frame-pump thread drives 59.94 Hz GCM ticks, drains the RSX FIFO every 4 ms, and presents completed flips.
- GameController discovery and a native CELL_PAD-compatible state bridge.
- A lock-free stereo audio ring and AVAudioSourceNode bridge. AVAudioEngine and the PS3 mixer remain dormant until guest execution is ready.
- CI smoke tests for ISO/UDF, EBOOT extraction, VFS paths, RSX frame pumping, controller/audio bridges, runtime lifecycle and guest-memory reservation.

## Known limitations

- The IPA currently contains an empty game PPU function table. The host can map a decrypted EBOOT and initialize its runtime tables, but `ppu_run` is deliberately not called and no guest PPU instructions execute.
- Game-specific SPU workloads/SPURS, `libsre.prx` loading and remaining title boot registrations are not linked yet.
- The desktop setup expects the supported US BLUS30443 v1.00 dump plus 28 decrypted game/firmware inputs. Importing one ISO is not enough; an ELF header alone does not prove the executable or required assets are suitable.
- The ISO-9660 reader does not support multi-extent files, interleaved files or Rock Ridge extensions. UDF support is present, but validation against the target BLUS30443 image is pending.
- The RSX frame pump advances the GCM clock and drains the FIFO, but it cannot display game content until guest PPU code submits real RSX commands. A running renderer is not proof of a playable game.
- Guest audio and saves are not operational yet. The disc VFS is read-only; writable `/dev_hdd0`/`/dev_hdd1` overlays still need to be implemented.
- The target is the iPhone 14/A15. A 30 FPS target is not claimed until real-game CPU/GPU frame time, memory pressure and thermal behaviour are measured.

## Generate and build on macOS

Install Xcode and XcodeGen, then follow the CI workflow in `.github/workflows/ios-build.yml`. The build first fetches and patches the pinned ps3recomp revision, builds the PPU host archive and generic runtime archive, and then runs XcodeGen/xcodebuild.

A signed, installable IPA additionally requires Apple signing assets (a development certificate and provisioning profile, or an appropriate distribution workflow).

## Porting order

1. Validate the ISO/UDF reader and `/dev_bdvd`/`/app_home` VFS against the exact supported disc image.
2. Generate the matching BLUS30443 v1.00 PPU lift from the user-owned decrypted EBOOT and compile its translation units into the IPA. iOS cannot turn an arbitrary imported ISO into native lifted code at runtime.
3. Load the matching game/firmware data, register the compiled lift, and enter it through upstream `ppu_run` with correct TLS, OPD and thread setup.
4. Bring up the title's SPU workloads, SPURS coordination and required `libsre.prx` path.
5. Validate real guest GCM submissions, Metal frames, audio and save-data writes.
6. Profile CPU/GPU frame time, memory and thermal behaviour on the A15 before targeting 30 FPS.

The existing desktop CMake target is not an iOS target. Its SDL2, Vulkan/vkd3d and Win32 assumptions cannot simply be linked into this app.

## Third-party notices

The UDF reader is [libudfread](https://github.com/firecore/libudfread), pinned as a source submodule and licensed under LGPL-2.1-or-later. Its `COPYING` license text is included in the app bundle. The app links the library statically; the complete application source, dependency source and build workflow are available in this repository so the app can be rebuilt with a modified library.

## Metal surface and frame ownership

The paused `MTKView` publishes its owned `CAMetalLayer` through `soulbrandt_metal_layer_get()`. The pointer is non-owning; the view retains the layer and clears the bridge when dismantled. The RSX backend owns `nextDrawable()`, command encoding and presentation. The separate frame-pump thread drives the upstream GCM vblank/flip path and FIFO drain; it is stopped before the RSX backend is torn down.
