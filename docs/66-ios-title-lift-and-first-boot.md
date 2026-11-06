# iOS title lift and first PPU dispatch

The iOS shell and generic PPU host are not a game build. The app must contain
the PPU functions lifted from the matching retail executable and the SPU
workloads extracted/lifted from that same executable. The iOS target links
these native objects statically; it does not JIT or interpret the PS3 ELF.

## Supported source

The existing Soulbrandt port targets the US BLUS30443 v1.00 disc. Use the
**decrypted 64-bit big-endian PowerPC64** `EBOOT.ELF`, not the encrypted
SELF-form `EBOOT.BIN`. The EBOOT must be paired with the exact pinned
`ps3recomp` commit in `ps3recomp.pin`.

The original disc image and decrypted game/firmware inputs remain user-owned.
Do not commit the EBOOT, lifted PPU/SPU source, PRX files, firmware data or
resulting title archive. `/ios/GameLift/` is ignored for that reason.

## Prepare the title-derived code

On macOS with Xcode command-line tools and Python 3, from the repository root:

```sh
bash ios/scripts/prepare-title-lift.sh \
  /path/to/BLUS30443/PS3_GAME/USRDIR/EBOOT.ELF \
  /path/to/pinned/ps3recomp
```

The script verifies the ELF architecture and pinned runtime commit, then runs
the same PPU analysis/lift options used by the desktop port, applies the
repository's boot patch, extracts and lifts the SPU images/SPURS jobs, and
compiles the resulting source for arm64 iOS.

It creates private generated material under `ios/GameLift/` and copies
`libSoulbrandtGameLift.a` to `ios/build/ppu-lift-ios/`, which is the path
already force-loaded by `ios/project.yml`.

Then generate and build the unsigned IPA:

```sh
cd ios
xcodegen generate
xcodebuild -project SoulbrandtIOS.xcodeproj -scheme SoulbrandtIOS \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -configuration Debug -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Package the app from Xcode's `Debug-iphoneos/Soulbrandt.app` as an IPA using
the same packaging commands in `.github/workflows/ios-build.yml`.

## What the app does at boot

1. Import the disc ISO. The importer mounts the read-only disc VFS and extracts
   the decrypted EBOOT into app storage.
2. Initialize the Metal/RSX backend, guest VM and controller bridge.
3. Configure persistent `/dev_hdd0` and `/dev_hdd1` overlays.
4. Load the EBOOT through the patched upstream PPU loader and register the
   linked title function table, HLE, sysPrx, filesystem and LV2 syscall tables.
5. The Boot button is exposed only when the linked PPU function table is
   non-empty. It dispatches upstream `ppu_run(entry_opd, 0x0FF00000)` on a
   dedicated 8 MiB host thread, never on SwiftUI's main thread.

The runtime currently has no cooperative guest-stop API. While `ppu_run` is
active, the app refuses to replace the disc or unmap guest memory. Relaunch the
app to reset a run that does not return.

## What still has to be proven

A successful lift/archive build is not a successful game boot. The first real
test must confirm that the BLUS30443 entry point executes, initializes its
required PRX/HLE dependencies and reaches the first game loading screen. SPU
dispatch, real GCM command submission, Metal output, audio, save semantics and
stability remain separate gates. The optional real `libsre.prx` LLE path is
not yet wired into this iOS build; the first boot attempt will use the current
HLE path and may expose missing imports or SPURS behavior.

The normal public CI build has no private game-derived inputs and therefore
continues to build the empty no-game marker archive. It must never be described
as a bootable Demon's Souls IPA.
