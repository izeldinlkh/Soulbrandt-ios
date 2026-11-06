#!/usr/bin/env bash
set -euo pipefail

IOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PS3_ROOT="${1:?usage: run-ppu-lift-ios-smoke-test.sh /path/to/patched/ps3recomp}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/recompiled" "$TMP/spu/fixture" "$TMP/spu/_gen"
printf '%s\n' 'void fixture_spu_image(void) {}' > "$TMP/spu/fixture/spu_recomp.c"
printf '%s\n' 'extern "C" int fixture_spu_registration(void) { return 1; }' > "$TMP/spu/_gen/spu_workloads.cpp"
cat > "$TMP/recompiled/ppu_recomp.h" <<'EOF'
#include "ps3emu/ppu_lift.h"
EOF
cat > "$TMP/recompiled/fixture.cpp" <<'EOF'
#include "ppu_recomp.h"

static void fixture_function(ppu_context *ctx) { (void)ctx; }

extern "C" {
const func_entry function_table[] = {
    {0x1000, fixture_function, "fixture_function"},
    {0, nullptr, nullptr}
};
const uint64_t function_table_count = 1;
}
EOF

bash "$IOS_ROOT/scripts/build-ppu-lift-ios.sh" \
  "$PS3_ROOT" "$TMP/recompiled" "$TMP/spu" "$TMP/lift-build"
STATUS="$TMP/lift-build/lift-status.txt"
grep -q '^game_lift=1$' "$STATUS"
grep -q '^ppu_sources=1$' "$STATUS"
grep -q '^spu_sources=3$' "$STATUS"
test -s "$TMP/lift-build/libSoulbrandtGameLift.a"

bash "$IOS_ROOT/scripts/build-ppu-lift-ios.sh" \
  "$PS3_ROOT" "$TMP/no-lift" "$TMP/no-spu" "$TMP/no-lift-build"
NO_LIFT_STATUS="$TMP/no-lift-build/lift-status.txt"
grep -q '^game_lift=0$' "$NO_LIFT_STATUS"
grep -q '^ppu_sources=0$' "$NO_LIFT_STATUS"
grep -q '^spu_sources=0$' "$NO_LIFT_STATUS"
test -s "$TMP/no-lift-build/libSoulbrandtGameLift.a"

echo "iOS PPU/SPU lift archive smoke test passed"
