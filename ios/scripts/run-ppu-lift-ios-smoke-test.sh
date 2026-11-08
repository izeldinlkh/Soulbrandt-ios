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
#include <stdint.h>
#define PPU_THREAD_LOCAL thread_local
typedef struct ppu_context {
    uint64_t gpr[32];
    uint64_t lr;
} ppu_context;
typedef struct {
    uint64_t addr;
    void (*func)(ppu_context*);
    const char* name;
} func_entry;
#ifdef __cplusplus
extern "C" {
#endif
extern const func_entry function_table[];
extern const uint64_t function_table_count;
#ifdef __cplusplus
}
#endif
EOF
# The desktop lift emits this all-module NID registration unit. iOS builds it
# separately in the PPU-host archive, so the game-lift builder must omit it.
cat > "$TMP/recompiled/hle_nid_table.cpp" <<'EOF'
extern "C" void ppu_hle_register_all(void) {}
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
grep -Fqx 'game_lift=1' "$TMP/lift-build/lift-status.txt"
grep -Fqx 'ppu_sources=2' "$TMP/lift-build/lift-status.txt"
grep -Fqx 'spu_sources=3' "$TMP/lift-build/lift-status.txt"
test -s "$TMP/lift-build/libSoulbrandtGameLift.a"
if /usr/bin/nm -g "$TMP/lift-build/libSoulbrandtGameLift.a" | grep -q 'ppu_hle_register_all'; then
  echo "game-lift archive duplicated the PPU-host HLE NID registration unit" >&2
  exit 1
fi

bash "$IOS_ROOT/scripts/build-ppu-lift-ios.sh" \
  "$PS3_ROOT" "$TMP/no-lift" "$TMP/no-spu" "$TMP/no-lift-build"
grep -Fqx 'game_lift=0' "$TMP/no-lift-build/lift-status.txt"
test -s "$TMP/no-lift-build/libSoulbrandtGameLift.a"

echo "iOS PPU/SPU lift archive smoke test passed"
