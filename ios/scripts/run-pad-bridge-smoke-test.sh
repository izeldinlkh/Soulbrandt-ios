#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cc -std=c11 -Wall -Wextra -Werror -pthread \
  "$ROOT/SoulbrandtIOS/PS3PadBridge.c" \
  "$ROOT/Tests/PS3PadBridgeSmokeTest.c" \
  -o "$TMP/pad-bridge-smoke"
"$TMP/pad-bridge-smoke"
