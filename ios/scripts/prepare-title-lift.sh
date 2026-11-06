#!/usr/bin/env bash
# Build the private, title-derived PPU and SPU sources needed by the iOS app.
# Nothing generated here is distributable: it is derived from the user's game.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: prepare-title-lift.sh DECRYPTED_EBOOT.ELF PS3RECOMP_DIR [OUTPUT_DIR] [JOBS]

Inputs:
  DECRYPTED_EBOOT.ELF  BLUS30443 v1.00 EBOOT.ELF (not SELF/EBOOT.BIN)
  PS3RECOMP_DIR        Checkout at the commit in ps3recomp.pin

Outputs (default ios/GameLift):
  recompiled/          lifted PPU translation units + function table
  loader/              PPU analysis (function and import maps)
  spu/                 lifted SPU images + generated workload registry
  libSoulbrandtGameLift.a  ARM64 iOS static archive

Run on macOS with Xcode command-line tools, Python 3 and the pinned
ps3recomp checkout. The generated output is private and must not be committed.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi
if [[ $# -lt 2 || $# -gt 4 ]]; then usage >&2; exit 2; fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EBOOT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
PS3_ROOT="$(cd "$2" && pwd)"
OUT="${3:-$ROOT/ios/GameLift}"
JOBS="${4:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
OUT="$(mkdir -p "$OUT" && cd "$OUT" && pwd)"

PIN="$(sed -n 's/^commit=//p' "$ROOT/ps3recomp.pin")"
ACTUAL="$(git -C "$PS3_ROOT" rev-parse HEAD 2>/dev/null || true)"
if [[ -z "$PIN" || "$ACTUAL" != "$PIN" ]]; then
  echo "ps3recomp checkout mismatch: expected $PIN, found ${ACTUAL:-not a git checkout}" >&2
  exit 1
fi
for tool in "$PS3_ROOT/tools/ppu_loader.py" "$PS3_ROOT/tools/ppu_lifter.py" \
            "$ROOT/scripts/apply_boot_patches.py" "$ROOT/scripts/build_spu.py"; do
  [[ -f "$tool" ]] || { echo "required tool is missing: $tool" >&2; exit 1; }
done
[[ -s "$EBOOT" ]] || { echo "EBOOT is missing or empty: $EBOOT" >&2; exit 1; }

python3 - "$EBOOT" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
b = p.read_bytes()[:20]
if len(b) < 20 or b[:7] != b"\x7fELF\x02\x02\x01" or b[18:20] != b"\x00\x15":
    raise SystemExit("input must be a decrypted 64-bit big-endian PowerPC64 ELF; decrypt EBOOT.BIN first")
PY

LOADER="$OUT/loader"
RECOMP="$OUT/recompiled"
SPU="$OUT/spu"
mkdir -p "$LOADER" "$RECOMP" "$SPU"

echo "[title-lift] analysing decrypted EBOOT"
python3 "$PS3_ROOT/tools/ppu_loader.py" "$EBOOT" -o "$LOADER"
FUNCTIONS="$LOADER/EBOOT.functions.json"
IMPORTS="$LOADER/EBOOT.imports.json"
[[ -s "$FUNCTIONS" && -s "$IMPORTS" ]] || {
  echo "ppu_loader did not produce EBOOT.functions.json and EBOOT.imports.json" >&2
  exit 1
}

OVERRIDES="0x167AC88=ds_malloc,0x167AC58=ds_free,0x273D38=des_move_post,0x724E40=des_menu_tick"
echo "[title-lift] recompiling PPU functions for the iOS ARM64 host"
python3 "$PS3_ROOT/tools/ppu_lifter.py" "$EBOOT" \
  --functions "$FUNCTIONS" --hle-stubs "$IMPORTS" \
  --override-funcs "$OVERRIDES" \
  --insn-hooks "@$ROOT/port/insn_hooks.txt" \
  --shadow-stack --chunk-lines 150000 --output "$RECOMP" -j "$JOBS"

echo "[title-lift] applying the repository's boot patches"
python3 "$ROOT/scripts/apply_boot_patches.py" "$RECOMP" --title BLUS30443

echo "[title-lift] extracting and lifting SPU images and SPURS jobs"
python3 "$ROOT/scripts/build_spu.py" --eboot "$EBOOT" \
  --ps3recomp "$PS3_ROOT" --out-dir "$SPU" -j "$JOBS"

echo "[title-lift] compiling PPU and SPU translation units for iOS"
bash "$ROOT/ios/scripts/build-ppu-lift-ios.sh" \
  "$PS3_ROOT" "$RECOMP" "$SPU" "$OUT/arm64"

STATUS="$OUT/arm64/lift-status.txt"
grep -Fqx 'game_lift=1' "$STATUS"
if ! grep -Eq '^ppu_sources=[1-9][0-9]*$' "$STATUS"; then
  echo "no PPU translation units were compiled" >&2
  exit 1
fi
if ! grep -Eq '^spu_sources=[1-9][0-9]*$' "$STATUS"; then
  echo "no SPU translation units/workload registry were compiled" >&2
  exit 1
fi
cp "$OUT/arm64/libSoulbrandtGameLift.a" "$OUT/libSoulbrandtGameLift.a"
echo "[title-lift] READY: $OUT/libSoulbrandtGameLift.a"
echo "[title-lift] This is a title lift, not yet proof of a successful game boot."
cat "$STATUS"
