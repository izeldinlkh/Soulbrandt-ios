#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/ppu_recomp_0.cpp" <<'CPP'
#include "ppu_recomp.h"
void func_00001000(ppu_context* ctx) {
    func_01674938(ctx);
    DRAIN_TRAMPOLINE(ctx);
}
void func_01674A5C(ppu_context* ctx) {
    PPU_MM_SNAP
    ctx->gpr[3] = (int64_t)(int32_t)(0);
    { uint64_t result = ~ctx->gpr[4] + ctx->gpr[3] + 1; ctx->xer = (ctx->xer & ~(1u << 29)) | ((ctx->gpr[3] >= ctx->gpr[4]) ? (1u << 29) : 0); ctx->gpr[0] = result; }
    { uint64_t ca = (ctx->xer >> 29) & 1; uint64_t result = ctx->gpr[4] + ca; ctx->xer = (ctx->xer & ~(1u << 29)) | ((result < ctx->gpr[4]) ? (1u << 29) : 0); ctx->gpr[3] = result; }
    return;
}
CPP

python3 "$ROOT/scripts/apply_macos_ppu_setjmp.py" "$TMP"
python3 "$ROOT/scripts/apply_macos_ppu_setjmp.py" "$TMP"
grep -Fq 'ds_sj_arm(ctx, __builtin_frame_address(0))' "$TMP/ppu_recomp_0.cpp"
grep -Fq 'ds_sj_jump(ctx, _sj_buf, _sj_lr);' "$TMP/ppu_recomp_0.cpp"
grep -Fq '#define DS_SETJMP(env) _setjmp(env)' "$TMP/ppu_recomp_0.cpp"
echo "macOS PPU setjmp smoke test passed"
