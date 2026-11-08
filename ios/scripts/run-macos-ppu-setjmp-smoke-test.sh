#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/recompiled"
{
  echo '/* Auto-generated test PPU chunk. */'
  echo '#include "ppu_recomp.h"'
  for i in $(seq 1 14); do
    printf 'void setjmp_site_%02d(ppu_context* ctx) { ctx->lr = 0x%08X; func_01674938(ctx); DRAIN_TRAMPOLINE(ctx); }\n' "$i" "$((0x1000 + i))"
  done
  cat <<'EOF'
void func_01674A5C(ppu_context* ctx) {
    PPU_MM_SNAP
    ctx->gpr[3] = (int64_t)(int32_t)(0);
    return;
}
EOF
} > "$TMP/recompiled/ppu_recomp_000.cpp"

PATCH="$ROOT/scripts/apply_macos_ppu_setjmp.py"
python3 "$PATCH" "$TMP/recompiled"
grep -Fq '#define DS_SETJMP(env) _setjmp(env)' "$TMP/recompiled/ppu_recomp_000.cpp"
[[ "$(grep -Fc 'ds_sj_arm(ctx, __builtin_frame_address(0))' "$TMP/recompiled/ppu_recomp_000.cpp")" == 14 ]]
[[ "$(grep -Fc 'ds_sj_jump(ctx, _sj_buf, _sj_lr);' "$TMP/recompiled/ppu_recomp_000.cpp")" == 1 ]]
if grep -Eq 'ctx->lr = 0x[0-9A-Fa-f]+; func_01674938\(ctx\); DRAIN_TRAMPOLINE\(ctx\);' "$TMP/recompiled/ppu_recomp_000.cpp"; then
  echo "raw guest setjmp call remains unpatched" >&2
  exit 1
fi
cp "$TMP/recompiled/ppu_recomp_000.cpp" "$TMP/once.cpp"
python3 "$PATCH" "$TMP/recompiled"
cmp "$TMP/once.cpp" "$TMP/recompiled/ppu_recomp_000.cpp"
echo "macOS-derived PPU guest setjmp/longjmp smoke test passed"
