#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/ios/scripts/prepare-title-lift.sh"
bash -n "$SCRIPT"
HELP="$(bash "$SCRIPT" --help)"
grep -Fq 'DECRYPTED_EBOOT.ELF' <<<"$HELP"
grep -Fq 'PS3RECOMP_DIR' <<<"$HELP"
PATCHER="$ROOT/ios/scripts/patch-ps3recomp-ios-metal.py"
grep -Fq 'tools/ppu_lifter.py' "$PATCHER"
grep -Fq '0xF8410028' "$PATCHER"
grep -Fq 'vm_write64(ctx->gpr[1] + 0x28, ctx->gpr[2])' "$PATCHER"
echo "iOS title-lift pipeline preflight smoke test passed"
