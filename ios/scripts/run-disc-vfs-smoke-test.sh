#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp)"
trap 'rm -f "$BIN"' EXIT
swiftc -swift-version 5 \
  "$ROOT/SoulbrandtIOS/DiscImageFileSystem.swift" \
  "$ROOT/SoulbrandtIOS/ISO9660Reader.swift" \
  "$ROOT/SoulbrandtIOS/PS3DiscVFS.swift" \
  "$ROOT/Tests/PS3DiscVFSSmokeTest.swift" \
  -o "$BIN"
"$BIN"
