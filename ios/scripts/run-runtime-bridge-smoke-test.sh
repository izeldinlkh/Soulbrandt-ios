#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp)"
trap 'rm -f "$BIN"' EXIT
cc -std=c11 -Wall -Wextra -Werror -DSOULBRANDT_LINKED_RUNTIME=1 \
  -I"$ROOT/SoulbrandtIOS" \
  "$ROOT/SoulbrandtIOS/PS3RuntimeBridge.c" \
  "$ROOT/Tests/PS3RuntimeBridgeSmokeTest.c" \
  -o "$BIN"
"$BIN"
