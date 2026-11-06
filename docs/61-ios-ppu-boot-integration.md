# iOS PPU boot integration boundary

This note records the next real boot milestone and prevents the ISO importer from being
mistaken for a game loader.

## What is already in the iOS target

- The app copies a user-selected ISO into private storage and can inspect ISO-9660/Joliet
  or UDF directories.
- It can extract a decrypted `PS3_GAME/USRDIR/EBOOT.ELF` (or ELF-form `EBOOT.BIN`)
  without buffering the whole executable.
- `soulbrandt_guest_load_elf` validates PPC64 big-endian program headers and maps
  `PT_LOAD` bytes/BSS into the aligned guest address space. It validates the entry point
  and `PT_TLS` ranges before modifying guest memory.
- The iOS build compiles the generic ps3recomp runtime and syntax-checks the PPU host
  scaffold against the iOS SDK.

None of those steps executes a PPU instruction.

## The missing PPU execution link

ps3recomp is a **static recompiler**, not an interpreter. Its documented path is:

1. Run `tools/ppu_loader.py` on the decrypted retail EBOOT to produce the image,
   OPD/function and import manifests.
2. Run `tools/ppu_disasm.py` and `tools/ppu_lifter.py` to generate native C/C++
   functions and the title's `ppu_recomp.h`.
3. Compile those generated translation units for arm64 as part of the app build.
4. Compile/link the PPU scaffold (`runtime/ppu/ppu_loader.cpp`,
   `ppu_hle.cpp`, `ppu_fs.cpp`, `ppu_sysprx.cpp`) and generated HLE NID table.
5. Register the generated function table, initialize HLE modules, load the ELF and
   enter it through `ppu_run`.

An arbitrary ISO selected inside the app cannot become executable merely because its ELF
segments were copied into RAM. With the current static-recomp architecture, the matching
lift must already have been generated and compiled into the IPA (or supplied as a separately
built, compatible native module). Runtime generation/JIT is not part of this port.

## Two loader paths must not be conflated

The current small C ELF loader is useful for validating and mapping a file. The upstream
PPU runtime loader is the one that must own a real boot: it captures `PT_TLS` metadata,
sets up the main thread's TLS image/`r13`, resolves the entry OPD, installs the PPU
thread trampoline, and dispatches `ppu_run`. The Swift status line saying “ELF loaded”
therefore means **segments mapped only**, not that the PPU runtime is initialized.

Do not wire `soulbrandt_guest_load_elf` directly to a pretend `ppu_run` call. First link
the upstream PPU scaffold and generated lift, then route boot through its loader so TLS,
OPD, HLE and thread setup stay consistent.

## VFS is a separate boot requirement

The current `ppu_fs.cpp` host implementation expects a directory tree on the host file
system. The app currently retains the disc as one ISO/UDF image. A bootable iOS path must
provide cellFs access to files inside that image (random-access open/read/seek/stat and
directory enumeration), or deliberately extract the required disc tree. Copying only
EBOOT.ELF is not enough: the game loads archives, shaders, configuration and other assets
from `/dev_bdvd`.

A virtual disc VFS is preferable to duplicating a multi-gigabyte image as loose files, but
it must be wired into cellFs before game boot is claimed.

## Renderer boundary

The upstream Metal RSX backend is compiled and can own the app's `CAMetalLayer`. The
animated MTKView triangle is only a synthetic presentation test. Actual game rendering
requires PPU code to initialize cellGcm, submit guest RSX command buffers, and reach the
backend's command-consumption/present path. No synthetic triangle or successful backend
initialization counts as a game frame.

## Ordered next milestones

1. Build a reproducible arm64 lift pipeline for the supported Demon's Souls retail EBOOT.
2. Link the PPU scaffold, generated function table and HLE NID registrations into the app.
3. Add an ISO-backed cellFs VFS and prove random-access reads against a real disc image.
4. Route boot through upstream `ppu_load_elf` / `ppu_run` and prove the first guest
   instructions execute on device.
5. Bring up the existing SPURS/SPU work required by the title.
6. Connect guest cellGcm submissions to the Metal RSX backend; only then measure real
   frame pacing and optimize the iPhone 14 target.
