#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Swift permits top-level statements in the designated main.swift file only
# when compiling several source files together.
cp "$ROOT/Tests/PS3PadMapperSmokeTest.swift" "$TMP/main.swift"
swiftc -swift-version 5 \
  "$ROOT/SoulbrandtIOS/PS3PadMapper.swift" \
  "$TMP/main.swift" \
  -o "$TMP/pad-mapper-smoke"
"$TMP/pad-mapper-smoke"
