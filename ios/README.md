# iOS bring-up (prototype)

This directory is the first native iOS shell, not a playable port.

## What exists

- SwiftUI application entry point and a minimal home screen.
- Files picker that accepts ISO files, requests security-scoped access, and copies the image into the app's Application Support directory.
- GameController framework discovery and basic Extended Gamepad input detection.
- A read-only ISO-9660/Joliet directory and bounded file-range reader prototype.
- XcodeGen project definition.

## What does not exist

- The ISO reader is not yet integrated into ps3recomp's cellFs VFS. It handles ISO-9660 primary/Joliet directory records only; UDF, multi-extent and interleaved files are not supported.
- No PS3 boot, PPU/SPU runtime, RSX renderer, audio, save-state, or game loop.
- Controller events are detected for bring-up only; they are not mapped to Soulbrandt's input system.
- No IPA is produced by this source-only commit.

## Generate and build on macOS

Install Xcode and XcodeGen, then:

```sh
cd ios
xcodegen generate
xcodebuild -project SoulbrandtIOS.xcodeproj \
  -scheme SoulbrandtIOS -sdk iphoneos \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

A signed, installable IPA additionally needs Apple signing assets (a development certificate and provisioning profile, or an appropriate distribution workflow).

## Porting order

1. Make the iOS shell build and validate file import/controller discovery on device.
2. Replace the desktop SDL/window/input layer with UIKit, GameController, and a Metal-backed presentation surface.
3. Add an iOS-compatible RSX backend and audio/output path.
4. Integrate the pinned ps3recomp runtime and generated game code.
5. Implement PS3 disc/VFS support for the filesystem formats actually used by the supported Demon's Souls dump; an ISO extension alone does not imply ISO-9660.
6. Profile and optimize on the target iPhone, then sign and package.

The existing desktop CMake target is not an iOS target. Do not try to link its SDL2/Vulkan/vkd3d/Win32 assumptions directly into this app.
