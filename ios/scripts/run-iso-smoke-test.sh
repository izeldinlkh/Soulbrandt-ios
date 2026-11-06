#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp)"
trap 'rm -f "$BIN"' EXIT
swiftc -swift-version 5 "$ROOT/SoulbrandtIOS/ISO9660Reader.swift" "$ROOT/Tests/ISO9660ReaderSmokeTest.swift" -o "$BIN"
"$BIN"
