#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp)"
trap 'rm -f "$BIN"' EXIT
cc -std=c11 -D_POSIX_C_SOURCE=200809L -pthread \
  -I"$ROOT/SoulbrandtIOS" \
  "$ROOT/SoulbrandtIOS/PS3RSXFramePump.c" \
  "$ROOT/Tests/PS3RSXFramePumpSmokeTest.c" \
  -o "$BIN"
"$BIN"
