#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -swift-version 5 \
  "$ROOT/SoulbrandtIOS/PS3PadMapper.swift" \
  "$ROOT/Tests/PS3PadMapperSmokeTest.swift" \
  -o "$TMP/pad-mapper-smoke"
"$TMP/pad-mapper-smoke"
