#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cc -std=c11 -Wall -Wextra -Werror -pthread \
  "$ROOT/ios/SoulbrandtIOS/PS3GuestMemory.c" \
  "$ROOT/ios/Tests/PS3GuestMemorySmokeTest.c" \
  -o "$TMP/guest-memory-smoke"
"$TMP/guest-memory-smoke"
