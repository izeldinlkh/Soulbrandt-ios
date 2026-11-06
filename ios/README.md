# iOS bring-up (prototype)

This directory contains a native iOS shell and early disc-inspection code. It is not a playable port.

## Implemented

- SwiftUI app entry point and basic home screen.
- Files picker accepts an .iso file and copies it to Application Support off the main thread.
- The imported filename and inspection summary are remembered across launches.
- Import is retained even when the image uses a filesystem the prototype cannot parse.
- GameController framework discovery, Extended Gamepad monitoring, and a native CELL_PAD-compatible state bridge.
- Read-only UDF-first, then ISO-9660/Joliet directory and file access, with bounded random-access reads. UDF is provided by the LGPL-2.1 libudfread submodule.
- A native MetalKit diagnostic render loop with live FPS/GPU diagnostics; Metal 4 capability detection on iOS 26+.
- Synthetic ISO and controller bridge smoke tests run by CI.

## Known limitations

- No PS3 boot or integration with ps3recomp's cellFs VFS.
- The MetalKit triangle is only a GPU bring-up test. It currently submits through the compatible `MTLCommandQueue` path; Metal 4 is detected but its `MTL4CommandQueue` submission path is not yet wired.
- ISO-9660 reader does not support multi-extent files, interleaved files, or Rock Ridge extensions. UDF images are handled by libudfread; validation against the target BLUS30443 disc image is still pending.
- The importer inspects the EBOOT header (ELF, likely SELF, or unknown), but an ELF header alone does not prove the full executable or the other required game/firmware files are decrypted and suitable for recompilation.
- The desktop setup currently expects the supported US BLUS30443 v1.00 dump plus 28 decrypted game/firmware files; importing a single ISO does not satisfy that build pipeline.
- Controller state is mapped into a CELL_PAD-shaped bridge, but no running game consumes it yet.
- The iOS target does not yet build the PPU/SPU runtime or connect the RSX backend, audio mixer, save system, or game loop.

## Generate and build on macOS

Install Xcode and XcodeGen, then:

```sh
cd ios
xcodegen generate
xcodebuild -project SoulbrandtIOS.xcodeproj \
  -scheme SoulbrandtIOS -sdk iphoneos \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

A signed, installable IPA additionally requires Apple signing assets (a development certificate and provisioning profile, or an appropriate distribution workflow).

## Porting order

1. Build and validate the native shell on a real iPhone.
2. Implement UDF and the exact disc/VFS behavior needed by the supported Demon's Souls dump, then extract/validate the full set of inputs required by the existing recompilation pipeline.
3. Build the pinned ps3recomp runtime for iOS, replacing desktop SDL input/audio dependencies with GameController and AVAudioEngine adapters.
4. Adapt the existing Objective-C Metal RSX backend: its iOS compile path currently forces headless/offscreen rendering, so it must accept and present through the app's CAMetalLayer/MTKView drawable.
5. Connect the generated PPU/SPU game code and cellFs VFS, then bring up RSX guest shaders and render targets. Adopt MTL4 command submission where it measurably helps, retaining the compatible Metal path as fallback.
6. Profile CPU/GPU frame time, memory and thermal behaviour on the A15 before targeting 30/60 FPS.

The existing desktop CMake target is not an iOS target. Its SDL2, Vulkan/vkd3d, and Win32 assumptions cannot simply be linked into this app.

## Third-party notices

The UDF reader is [libudfread](https://github.com/firecore/libudfread), pinned as a source submodule and licensed under LGPL-2.1-or-later. Its `COPYING` license text is included in the app bundle. The app links the library statically; the complete application source, dependency source, and build workflow are available in this repository so the app can be rebuilt with a modified library.

### Metal surface handoff

The diagnostic `MTKView` publishes its owned `CAMetalLayer` through
`soulbrandt_metal_layer_get()`. The pointer is non-owning; the view retains the
layer and clears the bridge when dismantled. Once the runtime is linked, its
iOS startup must pass this pointer to the patched
`rsx_metal_backend_set_layer()` before `rsx_metal_backend_init()`. The current
IPA does not yet link or call that backend.
