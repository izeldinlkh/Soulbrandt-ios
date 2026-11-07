#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/game/PS3_GAME/USRDIR/sub"
printf 'SFO-test' > "$TMP/game/PS3_GAME/PARAM.SFO"
printf 'asset-data' > "$TMP/game/PS3_GAME/USRDIR/sub/asset.bin"
cp "$ROOT/ios/Tests/ExtractedGameDirectoryReaderSmokeTest.swift" "$TMP/main.swift"
swiftc "$ROOT/ios/SoulbrandtIOS/DiscImageFileSystem.swift" \
  "$ROOT/ios/SoulbrandtIOS/ISO9660Reader.swift" \
  "$ROOT/ios/SoulbrandtIOS/ExtractedGameDirectoryReader.swift" \
  "$TMP/main.swift" \
  -o "$TMP/folder-reader-test"
"$TMP/folder-reader-test" "$TMP/game"
