#!/usr/bin/env python3
"""Apply the macOS Demon’s Souls guest setjmp/longjmp bridge to an iOS PPU lift."""
from pathlib import Path
import re
import sys

CALL = re.compile(r"(?P<indent>[ \t]*)func_01674938\(ctx\);\s*DRAIN_TRAMPOLINE\(ctx\);")
FUNC = "void func_01674A5C(ppu_context* ctx) {"


def function_body(source: str, signature: str):
    start = source.find(signature)
    if start < 0:
        return None
    brace = source.find("{", start)
    depth = 0
    for i in range(brace, len(source)):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                return start, brace, i
    raise RuntimeError("unterminated func_01674A5C body")


def patch_chunk(path: Path):
    source = path.read_text(encoding="utf-8", errors="surrogateescape")
    changed = False

    if "func_01674938(ctx);" in source:
        if "ds_sj_arm(ctx, __builtin_frame_address(0))" not in source:
            source, n = CALL.subn(
                lambda m: (
                    m.group("indent")
                    + "{ void* _sj = ds_sj_arm(ctx, __builtin_frame_address(0)); "
                    + "if (!DS_SETJMP(*(jmp_buf*)_sj)) func_01674938(ctx); } "
                    + "DRAIN_TRAMPOLINE(ctx);"
                ),
                source,
            )
            if n == 0:
                raise RuntimeError(f"{path}: setjmp call exists but expected call-site pattern did not")
            changed = True

        if "DS_SETJMP(env)" not in source:
            include = (
                '#include <setjmp.h>\n'
                'extern "C" void* ds_sj_arm(ppu_context* ctx, void* host_frame);\n'
                '#if defined(_WIN32)\n'
                '#define DS_SETJMP(env) setjmp(env)\n'
                '#else\n'
                '#define DS_SETJMP(env) _setjmp(env)\n'
                '#endif\n'
            )
            anchor = '#include "ppu_recomp.h"'
            if anchor not in source:
                raise RuntimeError(f"{path}: ppu_recomp.h include not found")
            source = source.replace(anchor, anchor + "\n" + include, 1)
            changed = True

    if FUNC in source and "ds_sj_jump(ctx, _sj_buf, _sj_lr);" not in source:
        found = function_body(source, FUNC)
        if found is None:
            raise RuntimeError(f"{path}: longjmp function signature not found")
        start, brace, end = found
        body = source[brace + 1:end]
        zero = "ctx->gpr[3] = (int64_t)(int32_t)(0);"
        if body.count(zero) != 1:
            raise RuntimeError(
                f"{path}: expected one final r3=0 restore in func_01674A5C, found {body.count(zero)}"
            )
        snap = body.find("PPU_MM_SNAP")
        if snap >= 0:
            line_end = body.find("\n", snap)
            insert_at = brace + 1 + (line_end + 1 if line_end >= 0 else len(body))
        else:
            insert_at = brace + 1
        prologue = (
            "\n    const uint32_t _sj_buf = ((uint32_t)ctx->gpr[3] + 0xF) & ~0xFu, "
            "_sj_lr = (uint32_t)ctx->lr;"
        )
        source = source[:insert_at] + prologue + source[insert_at:]
        z = source.find(zero, start)
        ret = source.find("return;", z)
        if ret < 0 or ret > end + len(prologue):
            raise RuntimeError(f"{path}: longjmp return anchor not found")
        source = source[:ret] + "ds_sj_jump(ctx, _sj_buf, _sj_lr);\n        " + source[ret:]
        declaration = 'extern "C" void ds_sj_jump(ppu_context* ctx, uint32_t buf, uint32_t from_lr);\n'
        source = source[:start] + declaration + source[start:]
        changed = True

    if changed:
        path.write_text(source, encoding="utf-8", errors="surrogateescape")
    return changed


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: apply_macos_ppu_setjmp.py LIFT_DIR")
    lift = Path(sys.argv[1])
    chunks = sorted(lift.glob("ppu_recomp_*.cpp"))
    if not chunks:
        raise SystemExit(f"no PPU chunks found in {lift}")

    changed = 0
    for path in chunks:
        if patch_chunk(path):
            changed += 1

    all_source = "\n".join(p.read_text(encoding="utf-8", errors="surrogateescape") for p in chunks)
    if "ds_sj_arm(ctx, __builtin_frame_address(0))" not in all_source:
        raise SystemExit("macOS setjmp bridge: no guest setjmp call sites were patched")
    if "ds_sj_jump(ctx, _sj_buf, _sj_lr);" not in all_source:
        raise SystemExit("macOS setjmp bridge: guest longjmp restore point was not patched")
    print(f"macOS PPU setjmp bridge: updated {changed} chunk(s); setjmp and longjmp hooks verified")


if __name__ == "__main__":
    main()
