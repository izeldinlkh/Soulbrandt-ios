#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDF_SRC="$ROOT/ThirdParty/libudfread/src"
TMP="$(mktemp -d)"
BIN="$TMP/udf-smoke"
trap 'rm -rf "$TMP"' EXIT

if ! command -v genisoimage >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y genisoimage
fi

mkdir -p "$TMP/root/PS3_GAME/USRDIR"
printf 'udf-smoke-ok' > "$TMP/root/PS3_GAME/USRDIR/EBOOT.ELF"
genisoimage -quiet -J -r -udf -o "$TMP/fixture.iso" "$TMP/root"

cc -std=gnu11 -D_FILE_OFFSET_BITS=64 \
  -DHAVE_UNISTD_H=1 -DHAVE_FCNTL_H=1 -DHAVE_PTHREAD_H=1 \
  -I "$UDF_SRC" \
  "$UDF_SRC/udfread.c" \
  "$UDF_SRC/ecma167.c" \
  "$UDF_SRC/default_blockinput.c" \
  "$ROOT/Tests/UDFReaderSmokeTest.c" \
  -pthread -o "$BIN"

"$BIN" "$TMP/fixture.iso"
