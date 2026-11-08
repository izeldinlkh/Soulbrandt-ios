#!/usr/bin/env python3
"""Port the macOS Demon’s Souls guest setjmp/longjmp fix into an iOS PPU lift.

The generated PPU code is private, title-derived output. This patch is applied
after every lift and is deliberately strict: the supported BLUS30443 v1.00
EBOOT has 14 calls to func_01674938 and one func_01674A5C implementation.
"""
from pathlib import Path
import re
import sys

CALL = re.compile(
    r"ctx->lr\s*=\s*(0x[0-9A-Fa-f]+);\s*"
    r"func_01674938\(ctx\);\s*DRAIN_TRAMPOLINE\(ctx\);"
)
WRAPPED = re.compile(
    r"ctx->lr\s*=\s*0x[0-9A-Fa-f]+;\s*\{\s*void\* _sj = ds_sj_arm\("
    r"ctx, __builtin_frame_address\(0\)\);\s*"
    r"if \(!DS_SETJMP\(\*\(jmp_buf\*\)_sj\)\) func_01674938\(ctx\);\s*"
    r"\}\s*DRAIN_TRAMPOLINE\(ctx\);"
)
EXPECTED_CALLS = 14
PREAMBLE = """/* macOS PPU fix 101: preserve guest setjmp/longjmp semantics on iOS. */
#include <setjmp.h>
extern "C" void* ds_sj_arm(ppu_context* ctx, void* host_frame);
#if defined(_WIN32)
#define DS_SETJMP(env) setjmp(env)
#else
#define DS_SETJMP(env) _setjmp(env)
#endif
"""

def function_span(source: str, signature: str):
    start = source.find(signature)
    if start < 0:
        return None
    opening = source.find("{", start + len(signature))
    if opening < 0:
        raise SystemExit("setjmp patch: malformed func_01674A5C definition")
    # Generated top-level function braces close at column zero. The guest
    # function body contains nested scopes, so count braces while ignoring
    # quoted strings and comments.
    depth = 0
    i = opening
    state = "code"
    while i < len(source):
        c = source[i]
        n = source[i + 1] if i + 1 < len(source) else ""
        if state == "code":
            if c == "/" and n == "*": state = "block"; i += 2; continue
            if c == "/" and n == "/": state = "line"; i += 2; continue
            if c == '"': state = "string"; i += 1; continue
            if c == "'": state = "char"; i += 1; continue
            if c == "{": depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0: return start, i + 1
        elif state == "block":
            if c == "*" and n == "/": state = "code"; i += 2; continue
        elif state == "line":
            if c == "\n": state = "code"
        elif state in ("string", "char"):
            if c == "\\":
                i += 2; continue
            if (state == "string" and c == '"') or (state == "char" and c == "'"):
                state = "code"
        i += 1
    raise SystemExit("setjmp patch: unterminated func_01674A5C definition")

def add_preamble(source: str) -> str:
    if "extern \"C\" void* ds_sj_arm" in source:
        return source
    anchor = '#include "ppu_recomp.h"'
    if source.count(anchor) != 1:
        raise SystemExit("setjmp patch: expected one ppu_recomp.h include in a setjmp caller")
    return source.replace(anchor, anchor + "\n" + PREAMBLE.rstrip(), 1)

def patch_lift(lift: Path) -> None:
    files = sorted(lift.glob("ppu_recomp_*.cpp"))
    if not files:
        raise SystemExit(f"setjmp patch: no lifted PPU chunks in {lift}")

    raw_calls = 0
    wrapped_calls = 0
    longjmp_file = None
    longjmp_source = None

    for path in files:
        source = path.read_text(encoding="utf-8", errors="surrogateescape")
        raw_calls += len(CALL.findall(source))
        wrapped_calls += len(WRAPPED.findall(source))
        if "void func_01674A5C(ppu_context* ctx)" in source:
            if longjmp_file is not None:
                raise SystemExit("setjmp patch: func_01674A5C appears in multiple chunks")
            longjmp_file, longjmp_source = path, source

    if raw_calls + wrapped_calls != EXPECTED_CALLS:
        raise SystemExit(
            f"setjmp patch: expected {EXPECTED_CALLS} guest setjmp call sites, "
            f"found {raw_calls} raw + {wrapped_calls} already patched"
        )
    if longjmp_file is None:
        raise SystemExit("setjmp patch: func_01674A5C (guest longjmp) was not lifted")

    for path in files:
        source = path.read_text(encoding="utf-8", errors="surrogateescape")
        if CALL.search(source):
            source = CALL.sub(
                lambda m: (
                    f"ctx->lr = {m.group(1)}; "
                    "{ void* _sj = ds_sj_arm(ctx, __builtin_frame_address(0)); "
                    "if (!DS_SETJMP(*(jmp_buf*)_sj)) func_01674938(ctx); } "
                    "DRAIN_TRAMPOLINE(ctx);"
                ),
                source,
            )
            source = add_preamble(source)
            path.write_text(source, encoding="utf-8", errors="surrogateescape")

    source = longjmp_file.read_text(encoding="utf-8", errors="surrogateescape")
    if "ds_sj_jump(ctx, _sj_buf, _sj_lr);" not in source:
        signature = "void func_01674A5C(ppu_context* ctx)"
        span = function_span(source, signature)
        if span is None:
            raise SystemExit("setjmp patch: could not locate guest longjmp function")
        start, end = span
        fn = source[start:end]
        snap = fn.find("PPU_MM_SNAP")
        if snap < 0:
            raise SystemExit("setjmp patch: guest longjmp lacks PPU_MM_SNAP")
        snap_end = fn.find("\n", snap)
        if snap_end < 0:
            raise SystemExit("setjmp patch: malformed PPU_MM_SNAP line")
        fn = fn[:snap_end + 1] + (
            "    const uint32_t _sj_buf = ((uint32_t)ctx->gpr[3] + 0xFu) & ~0xFu, "
            "_sj_lr = (uint32_t)ctx->lr;\n"
        ) + fn[snap_end + 1:]
        ret = fn.rfind("return;")
        if ret < 0:
            raise SystemExit("setjmp patch: guest longjmp has no final return")
        fn = fn[:ret] + "ds_sj_jump(ctx, _sj_buf, _sj_lr);\n        " + fn[ret:]
        source = source[:start] + fn + source[end:]
        decl = 'extern "C" void ds_sj_jump(ppu_context* ctx, uint32_t buf, uint32_t from_lr);\n'
        source = source[:start] + decl + source[start:]
        longjmp_file.write_text(source, encoding="utf-8", errors="surrogateescape")

    print(f"macOS PPU setjmp port: {EXPECTED_CALLS} call sites, longjmp bridge in {longjmp_file.name}")

def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: apply_macos_ppu_setjmp.py LIFTED_RECOMPILED_DIR")
    patch_lift(Path(sys.argv[1]).resolve())

if __name__ == "__main__":
    main()
