#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/ios/scripts/prepare-title-lift.sh"
bash -n "$SCRIPT"
HELP="$(bash "$SCRIPT" --help)"
grep -Fq 'DECRYPTED_EBOOT.ELF' <<<"$HELP"
grep -Fq 'PS3RECOMP_DIR' <<<"$HELP"
echo "iOS title-lift pipeline preflight smoke test passed"
