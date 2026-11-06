# Private game-lift inputs for iOS

This directory is intentionally free of game-derived code. Keep the ISO, decrypted EBOOT/PRX/SDAT files, and generated translation units in a private workspace; do not commit copyrighted game data or generated game code to the public repository.

## Supported input set

The current port targets **Demon's Souls US BLUS30443, version 1.00** only.

The iOS ISO importer mounts the disc read-only and can extract an EBOOT that is already a decrypted ELF. It does **not** decrypt SELF containers, SDAT files, or PRX modules. If the ISO still contains an encrypted `EBOOT.BIN`, the app will report that it is SELF and refuse to load it. The upstream desktop setup lists 28 decrypted inputs in total: `EBOOT.ELF`, the game's SDAT files, and `libsre.prx`.

The current iOS PPU/SPU archive pipeline handles the main EBOOT lift and SPU images/jobs. It does not yet build or load the separate `libsre.prx` firmware-LLE module, and the iOS VFS does not yet provide a loose-file overlay for separately decrypted SDAT files. The existing HLE cellSpurs path remains the default. Do not assume that an imported ISO alone is sufficient for a complete game boot.

## Generate the PPU and SPU lift

From the repository root, using the pinned `ps3recomp` checkout and your own decrypted EBOOT:

```sh
python ps3recomp/tools/ppu_loader.py work/game/EBOOT.ELF -o work/loader

python ps3recomp/tools/ppu_lifter.py work/game/EBOOT.ELF \
  --functions work/loader/EBOOT.functions.json \
  --hle-stubs work/loader/EBOOT.imports.json \
  --override-funcs "0x167AC88=ds_malloc,0x167AC58=ds_free,0x273D38=des_move_post,0x724E40=des_menu_tick" \
  --insn-hooks @port/insn_hooks.txt --shadow-stack --chunk-lines 150000 \
  --output ios/GameLift/recompiled -j 16

python scripts/apply_boot_patches.py ios/GameLift/recompiled

python scripts/build_spu.py --eboot work/game/EBOOT.ELF \
  --out-dir ios/GameLift/spu -j 8
```

The PPU output must include `recompiled/ppu_recomp.h` and its generated `.cpp/.c` translation units. The SPU output must include each image/job `spu_recomp.c` and `spu/_gen/spu_workloads.cpp`. The iOS build script also excludes the desktop-generated HLE NID table because the iOS PPU-host archive builds that table itself.

## What CI builds

The workflow runs `ios/scripts/build-ppu-lift-ios.sh` against these paths. It compiles PPU units for arm64 iOS with floating-point contraction disabled, compiles SPU workloads with the musttail dispatcher, verifies the generated function-table symbols, and force-loads the static archive into the IPA.

When the private generated sources are absent, CI emits a marker archive and the app keeps its weak empty function-table fallback. That build proves the link path only: it can inspect/load an EBOOT, but it has zero lifted functions and cannot execute the game.

The generated PPU/SPU code must match the exact EBOOT revision used to create it. Do not mix lifts from another region or game update.