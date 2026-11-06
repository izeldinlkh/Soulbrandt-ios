#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp)"
trap 'rm -f "$BIN"' EXIT
cc -std=c11 -Wall -Wextra -Werror \
  "$ROOT/SoulbrandtIOS/PS3AudioBridge.c" \
  "$ROOT/Tests/PS3AudioBridgeSmokeTest.c" \
  -o "$BIN"
"$BIN"
