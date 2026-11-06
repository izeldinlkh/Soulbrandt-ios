# iOS bring-up (prototype)

This directory contains a native iOS shell and early disc-inspection code. It is not a playable port.

## Implemented

- SwiftUI app entry point and basic home screen.
- Files picker accepts an .iso file and copies it to Application Support off the main thread.
- The imported filename and inspection summary are remembered across launches.
- Import is retained even when the image uses a filesystem the prototype cannot parse.
- GameController framework discovery, Extended Gamepad monitoring, and a native CELL_PAD-compatible state bridge.
- Read-only UDF-first, then ISO-9660/Joliet directory and file access, with bounded random-access reads. UDF is provided by the LGPL-2.1 libudfread submodule.
- A native MetalKit drawable surface backed by CAMetalLayer. The pinned ps3recomp static runtime is built for iOS and linked into the app; the host bridge initializes and shuts down the RSX Metal backend against that layer, without running a competing MTKView render loop. An MTL4 command-submission prototype exists but is not yet used by the RSX backend.
- A 4-GiB-aligned, demand-backed PS3 guest address-space reservation. It is initialized and released with the native runtime lifecycle; this is address-space infrastructure, not a running PPU loader or a claim that 4 GiB of physical RAM is allocated.
- A lock-free stereo float ring between the PS3 mixer and an AVAudioSourceNode; the AVAudioEngine is deliberately dormant until the game runtime starts.
- CI smoke tests for ISO/UDF, controller mapping, the controller C bridge, audio C bridge, and RSX/runtime bridge startup and teardown. The pinned RSX Metal backend, iOS cellPad adapter and iOS cellAudio adapter are also syntax-checked against the iOS SDK.

## Known limitations

- No PS3 boot or integration with ps3recomp's cellFs VFS.
- The patched RSX Metal backend is now linked and initialized against the app's CAMetalLayer, but the app does not yet boot guest PPU/SPU code or submit a real game frame. A successfully initialized renderer is not the same as a playable game. The actual RSX backend continues to use its existing Metal command submission; the MTL4 prototype is not wired into it.
- ISO-9660 reader does not support multi-extent files, interleaved files, or Rock Ridge extensions. UDF images are handled by libudfread; validation against the target BLUS30443 disc image is still pending.
- The importer inspects the EBOOT header (ELF, likely SELF, or unknown), but an ELF header alone does not prove the full executable or the other required game/firmware files are decrypted and suitable for recompilation.
- The desktop setup currently expects the supported US BLUS30443 v1.00 dump plus 28 decrypted game/firmware files; importing a single ISO does not satisfy that build pipeline.
- Swift GameController state is translated into PS3 pad bytes. The linked runtime's native cellPad backend reads this bridge; guest game code is not running yet.
- The pinned runtime archive also contains an AVAudioEngine-backed cellAudio output and skips SDL2 on iOS. The app-side lock-free audio bridge is tested, but AVAudioEngine remains dormant and the PS3 mixer is not started.
- CI builds the generic ps3recomp runtime as an iOS ARM64 static archive and links it into the app. A small iOS host-shim object satisfies generic archive references, and the guest-memory manager now owns `vm_base` and reserves the aligned 4-GiB address space. This is still not the full `des_boot` host: PPU loader/execution, game-specific generated PPU/SPU code, SPURS registration, VFS wiring, and firmware/HLE startup remain unintegrated.

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
3. Build and link the pinned ps3recomp runtime for iOS, including its native GameController and AVAudioEngine adapters; reserve the aligned guest address space.
4. Port the `des_boot` host in layers: PPU loader and generated PPU code first, then SPU workloads/SPURS and the game-specific registration path.
5. Mount the imported disc through the runtime VFS and provide the required decrypted game/firmware inputs.
6. Initialize the patched Objective-C Metal RSX backend against the app's CAMetalLayer; connect real guest command submission and validate actual game frames, audio and saves.
7. Profile CPU/GPU frame time, memory and thermal behaviour on the A15 before targeting 30 FPS.

The existing desktop CMake target is not an iOS target. Its SDL2, Vulkan/vkd3d, and Win32 assumptions cannot simply be linked into this app.

## Third-party notices

The UDF reader is [libudfread](https://github.com/firecore/libudfread), pinned as a source submodule and licensed under LGPL-2.1-or-later. Its `COPYING` license text is included in the app bundle. The app links the library statically; the complete application source, dependency source, and build workflow are available in this repository so the app can be rebuilt with a modified library.

### Metal surface handoff

The paused `MTKView` publishes its owned `CAMetalLayer` through
`soulbrandt_metal_layer_get()`. The pointer is non-owning; the view retains the
layer and clears the bridge when dismantled. The app has a runtime-initialization
button and a weak-import bridge for `rsx_metal_backend_set_layer()` and
`rsx_metal_backend_init()`. Until the full boot host is linked, that bridge
returns a clear “host not linked” status rather than inventing missing globals.


### RSX drawable ownership

The iOS Metal view is a surface owner, not a second renderer. It publishes its
`CAMetalLayer` through the C bridge and deliberately pauses MTKView's own draw
loop. This avoids two independent renderers racing to acquire and present
`CAMetalLayer` drawables. The patched upstream RSX backend is intended to own
`nextDrawable()`, command encoding, and presentation once the PS3 runtime is
linked and started. The current app still does not start that runtime.
