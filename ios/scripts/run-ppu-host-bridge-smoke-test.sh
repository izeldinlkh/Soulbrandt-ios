#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$(mktemp)"
trap 'rm -f "$BIN"' EXIT
c++ -std=c++17 -pthread \
  -I"$ROOT/ios/SoulbrandtIOS" \
  "$ROOT/ios/SoulbrandtIOS/PS3PPUHostBridge.cpp" \
  "$ROOT/ios/Tests/PS3PPUHostBridgeSmokeTest.cpp" \
  -o "$BIN"
"$BIN"
echo "PPU host bridge lifecycle smoke test passed"
