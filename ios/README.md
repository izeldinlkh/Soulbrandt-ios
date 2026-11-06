# iOS bring-up (prototype)

This directory contains a native iOS shell and early disc-inspection code. It is not a playable port.

## Implemented

- SwiftUI app entry point and basic home screen.
- Files picker accepts an .iso file and copies it to Application Support off the main thread.
- The imported filename and inspection summary are remembered across launches.
- Import is retained even when the image uses a filesystem the prototype cannot parse.
- GameController framework discovery and basic Extended Gamepad input-event monitoring.
- Read-only ISO-9660/Joliet and UDF directory/file access, with bounded random-access reads. UDF is provided by the LGPL-2.1 libudfread submodule.
- Synthetic ISO smoke test run by the macOS CI workflow.

## Known limitations

- No PS3 boot or integration with ps3recomp's cellFs VFS.
- ISO-9660 reader does not support multi-extent files, interleaved files, or Rock Ridge extensions. UDF images are handled by libudfread; validation against the target BLUS30443 disc image is still pending.
- The importer inspects the EBOOT header (ELF, likely SELF, or unknown), but an ELF header alone does not prove the full executable or the other required game/firmware files are decrypted and suitable for recompilation.
- The desktop setup currently expects the supported US BLUS30443 v1.00 dump plus 28 decrypted game/firmware files; importing a single ISO does not satisfy that build pipeline.
- Controller input is detected but not yet mapped into Soulbrandt's input abstraction.
- No PPU/SPU runtime, RSX renderer, audio path, save system, game loop, or IPA is included.

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
3. Replace desktop window/input/output assumptions with UIKit, GameController, Metal, and iOS audio.
4. Integrate the pinned ps3recomp runtime and generated PPU/SPU game code.
5. Implement an iOS-compatible RSX backend, then profile and optimize on the target device.

The existing desktop CMake target is not an iOS target. Its SDL2, Vulkan/vkd3d, and Win32 assumptions cannot simply be linked into this app.
