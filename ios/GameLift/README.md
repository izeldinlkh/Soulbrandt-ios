# Optional game lift input

This directory is intentionally empty of game-derived code. Keep the decrypted
EBOOT/PRX files and generated translation units private; do not commit an ISO or
other copyrighted game data to a public repository.

When the supported BLUS30443 v1.00 lift has been generated with the pinned
ps3recomp tools, place its output here:

- `recompiled/ppu_recomp.h`
- `recompiled/*.cpp` and/or `recompiled/*.c`
- `spu/<image-name>/spu_recomp.c` for each generated SPU image
- optional `spu/spu_workloads.c`, `spu/jobmods_register.c`, and
  `spu/taskset_policy_bytes.c`

The iOS workflow runs `ios/scripts/build-ppu-lift-ios.sh` against these paths.
It compiles PPU translation units for arm64 iOS with floating-point contraction
disabled, compiles SPU workloads with the musttail dispatcher, and force-loads
the resulting static archive into the IPA. Without `recompiled/ppu_recomp.h`,
it emits a marker archive and the app keeps its weak empty function-table
fallback; that build can inspect/load an EBOOT but cannot execute the game.

The generated PPU/SPU code must match the exact EBOOT and firmware inputs used
to create it. Do not mix lifts from another game revision.
