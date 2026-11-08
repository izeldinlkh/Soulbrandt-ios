#!/usr/bin/env python3
"""Apply the small iOS host-surface patch to the exact pinned ps3recomp checkout.

The upstream Metal RSX renderer already handles the RSX command stream, guest
shaders, textures, render targets and depth/stencil. Its iOS branch currently
forces headless rendering. This patch lets the app hand it a CAMetalLayer.
"""
from pathlib import Path
import sys


def replace_once(root: Path, relative: str, old: str, new: str) -> None:
    path = root / relative
    source = path.read_text()
    if new in source:
        return
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{relative}: expected one patch anchor, found {count}: {old[:100]!r}")
    path.write_text(source.replace(old, new, 1))


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-ps3recomp-ios-metal.py PS3RECOMP_SOURCE_DIR")
    root = Path(sys.argv[1]).resolve()
    if not (root / "libs/video/rsx_metal_backend.m").is_file():
        raise SystemExit(f"not a ps3recomp checkout: {root}")

    # iOS deliberately does not expose mach/mach_vm.h. Use the
    # supported 64-bit vm_region_64 API from mach/vm_map.h instead.
    win32_compat = root / "runtime/platform/win32_compat.c"
    if "mach_vm_region vm_region_64" not in win32_compat.read_text():
        replace_once(
            root, "runtime/platform/win32_compat.c",
            """#if defined(__APPLE__)
/* <sys/ucontext.h>, not <ucontext.h>: the latter is the deprecated
 * makecontext/swapcontext family and refuses to compile without _XOPEN_SOURCE,
 * while all that is wanted here is the ucontext_t a signal handler is given. */
#  include <sys/ucontext.h>
#  include <mach/mach.h>
#  include <mach/mach_vm.h>
#  include <mach/thread_act.h>
#  include <pthread/qos.h>
#else""",
            """#if defined(__APPLE__)
/* <sys/ucontext.h>, not <ucontext.h>: the latter is the deprecated
 * makecontext/swapcontext family and refuses to compile without _XOPEN_SOURCE,
 * while all that is wanted here is the ucontext_t a signal handler is given. */
#  include <sys/ucontext.h>
#  include <mach/mach.h>
#  include <TargetConditionals.h>
#  if TARGET_OS_IPHONE
#    include <mach/vm_map.h>
     /* mach/mach_vm.h is explicitly unsupported by the iOS SDK. */
#    define mach_vm_address_t vm_address_t
#    define mach_vm_size_t vm_size_t
#    define mach_vm_region vm_region_64
#  else
#    include <mach/mach_vm.h>
#  endif
#  include <mach/thread_act.h>
#  include <pthread/qos.h>
#else""",
        )

    # Reuse the app's fully bounds-checked ELF loader. The upstream loader
    # historically skipped malformed PT_LOAD segments and could still return
    # the ELF entry point, making a partial image look like a successful load.
    replace_once(
        root, "runtime/ppu/ppu_loader.cpp",
        """#include "ps3emu/ppu_lift.h"   /* ppu_context, the vm_* prototypes, function_table: the lift's fixed part */\n""",
        """#include "ps3emu/ppu_lift.h"   /* ppu_context, the vm_* prototypes, function_table: the lift's fixed part */\n#include "PS3GuestMemory.h"\n""",
    )
    replace_once(
        root, "runtime/ppu/ppu_loader.cpp",
        r"""    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "[ppu] cannot open %s\n", path); return 0; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t* file = (uint8_t*)malloc(sz);
    if (!file || fread(file, 1, sz, f) != (size_t)sz) { fclose(f); free(file); return 0; }
    fclose(f);

    if (sz < 64 || memcmp(file, "\x7F""ELF", 4) != 0 || file[4] != 2 /*ELFCLASS64*/ || file[5] != 2 /*MSB*/) {
        fprintf(stderr, "[ppu] not a 64-bit big-endian ELF\n"); free(file); return 0;
    }
    uint64_t fsz = (uint64_t)sz;
    uint32_t entry = (uint32_t)be64(file + 24);
    uint64_t phoff = be64(file + 32);
    uint16_t phentsize = be16(file + 54);
    uint16_t phnum = be16(file + 56);

    int loaded = 0;
    for (uint16_t i = 0; i < phnum; i++) {
        uint64_t ph_off = phoff + (uint64_t)i * phentsize;
        if (ph_off + 56 > fsz) break;   /* program header itself out of the file */
        const uint8_t* ph = file + ph_off;
        uint32_t p_type = be32(ph + 0);
        if (p_type == 7 /*PT_TLS*/) {
            /* The thread-local template: its initialised bytes live in vm_base
             * at p_vaddr (covered by a PT_LOAD too). ppu_run copies it into the
             * main thread's TLS image and points r13 at it. */
            g_tls_vaddr  = (uint32_t)be64(ph + 16);
            g_tls_filesz = (uint32_t)be64(ph + 32);
            g_tls_memsz  = (uint32_t)be64(ph + 40);
            fprintf(stderr, "[ppu] PT_TLS template vaddr=0x%08X filesz=0x%X memsz=0x%X\n",
                    g_tls_vaddr, g_tls_filesz, g_tls_memsz);
            continue;
        }
        if (p_type != 1 /*PT_LOAD*/) continue;
        uint64_t p_offset = be64(ph + 8);
        uint64_t p_vaddr  = be64(ph + 16);
        uint64_t p_filesz = be64(ph + 32);
        uint64_t p_memsz  = be64(ph + 40);
        if (p_memsz == 0) continue;
        /* Bounds-check both ends before touching host memory: the source range
         * must lie inside the ELF file, and the destination range inside the
         * guest VM (ppu_vm_size==0 = unchecked, matching the vm accessors).
         * Skip malformed/oversized segments rather than overflowing the host. */
        if (p_offset > fsz || p_filesz > fsz || p_offset + p_filesz > fsz) {
            fprintf(stderr, "[ppu] segment %u file range 0x%llX+0x%llX exceeds ELF (0x%llX), skipped\n",
                    i, (unsigned long long)p_offset, (unsigned long long)p_filesz, (unsigned long long)fsz);
            continue;
        }
        if (ppu_vm_size && (p_vaddr > ppu_vm_size || p_memsz > ppu_vm_size ||
                            p_vaddr + p_memsz > ppu_vm_size)) {
            fprintf(stderr, "[ppu] segment %u vaddr 0x%llX+0x%llX exceeds VM (0x%X), skipped\n",
                    i, (unsigned long long)p_vaddr, (unsigned long long)p_memsz, ppu_vm_size);
            continue;
        }
        memcpy(vm_base + (uint32_t)p_vaddr, file + p_offset, (size_t)p_filesz);
        if (p_memsz > p_filesz)
            memset(vm_base + (uint32_t)p_vaddr + (uint32_t)p_filesz, 0, (size_t)(p_memsz - p_filesz));
        loaded++;
    }
    free(file);
    fprintf(stderr, "[ppu] loaded %d PT_LOAD segments, entry OPD 0x%08X\n", loaded, entry);""",
        r"""    if (!path || !*path || !vm_base) return 0;
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "[ppu] cannot open %s\n", path); return 0; }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 0; }
    long sz = ftell(f);
    if (sz < 64 || (uint64_t)sz > 512ULL * 1024ULL * 1024ULL ||
        fseek(f, 0, SEEK_SET) != 0) {
        fprintf(stderr, "[ppu] invalid EBOOT file size\n");
        fclose(f);
        return 0;
    }
    uint8_t* file = (uint8_t*)malloc((size_t)sz);
    if (!file || fread(file, 1, (size_t)sz, f) != (size_t)sz) {
        fclose(f);
        free(file);
        return 0;
    }
    fclose(f);

    soulbrandt_guest_elf_info image = {};
    const int32_t load_result = soulbrandt_guest_load_elf(file, (uint64_t)sz, &image);
    free(file);
    if (load_result != 0) {
        fprintf(stderr, "[ppu] validated ELF loader rejected image (%d)\n", load_result);
        return 0;
    }

    g_tls_vaddr = image.tls_vaddr;
    g_tls_filesz = image.tls_filesz;
    g_tls_memsz = image.tls_memsz;
    const uint32_t entry = image.entry_opd;
    fprintf(stderr, "[ppu] validated and loaded %u PT_LOAD segments, entry OPD 0x%08X\n",
            image.load_segment_count, entry);""",
    )

    # The macOS runner keeps the loaded PT_LOAD envelope and places argv/envp
    # on the guest main stack, not at a fixed address in the game's data/heap.
    replace_once(
        root, "runtime/ppu/ppu_loader.cpp",
        'extern "C" uint32_t ppu_vm_size = 0;\\n',
        'extern "C" uint32_t ppu_vm_size = 0;\\nstatic uint64_t g_ppu_image_min = 0x100000000ull;\\nstatic uint64_t g_ppu_image_max = 0;\\n',
    )
    replace_once(
        root, "runtime/ppu/ppu_loader.cpp",
        """    g_tls_vaddr = image.tls_vaddr;
    g_tls_filesz = image.tls_filesz;
    g_tls_memsz = image.tls_memsz;
    const uint32_t entry = image.entry_opd;""",
        """    g_tls_vaddr = image.tls_vaddr;
    g_tls_filesz = image.tls_filesz;
    g_tls_memsz = image.tls_memsz;
    g_ppu_image_min = image.load_min_vaddr;
    g_ppu_image_max = image.load_max_vaddr;
    const uint32_t entry = image.entry_opd;""",
    )
    replace_once(
        root, "runtime/ppu/ppu_loader.cpp",
        r"""        uint32_t argv_base = 0x00B00000u;          /* scratch in the .data/heap gap */
        /* argc_n argv pointers, a NULL argv terminator, then a NULL envp. */
        uint32_t slots     = (argc_n + 2u) * 8u;
        uint32_t str_addr  = argv_base + ((slots + 0x1Fu) & ~0x1Fu);
        uint32_t sp_cur    = str_addr;
        for (uint32_t a = 0; a < argc_n; a++) {
            uint32_t j = 0;
            for (; argp[a][j]; j++) vm_write8(sp_cur + j, (uint8_t)argp[a][j]);
            vm_write8(sp_cur + j, 0);
            vm_write32(argv_base + a * 8u + 0, 0);        /* pointer hi word */
            vm_write32(argv_base + a * 8u + 4, sp_cur);   /* pointer lo word */
            sp_cur = (sp_cur + j + 1u + 0xFu) & ~0xFu;    /* lv2 aligns each string */
        }
        vm_write32(argv_base + argc_n * 8u + 0, 0);        /* argv NULL terminator */
        vm_write32(argv_base + argc_n * 8u + 4, 0);
        vm_write32(argv_base + (argc_n + 1u) * 8u + 0, 0); /* envp NULL            */
        vm_write32(argv_base + (argc_n + 1u) * 8u + 4, 0);
        /* The pointer goes in the LOW word (+4) of each 8-byte slot: a guest CRT
         * reads argv as 64-bit big-endian pointers at [argv + 4 + i*8]. Writing it
         * at +0 leaves the CRT reading 0 there -- a null argv[0], which YDKJ read as
         * an empty boot device before deadlocking on a data.toc it never loaded. */
        ctx.gpr[3] = argc_n;                        /* argc */
        ctx.gpr[4] = argv_base;                     /* argv */
        /* Read back: demand-committed pages can swallow a write, and a silently
         * empty argv is hard to recognise from the guest side. */
        for (uint32_t a = 0; a < argc_n; a++) {
            uint32_t pa = __builtin_bswap32(*(uint32_t*)(vm_base + argv_base + a * 8u + 4));
            char rb[80]; uint32_t k = 0;
            for (; k < 79; k++) { rb[k] = (char)vm_base[pa + k]; if (!rb[k]) break; }
            rb[79] = 0;
            fprintf(stderr, "[ppu] argv[%u] @0x%08X = \\"%s\\"\\n", a, pa, rb);
        }
        fprintf(stderr, "[ppu] argc=%u argv=0x%08X\\n", argc_n, argv_base);""",
        r"""        /* Put the process-entry frame, argv and envp on the reserved guest
         * main stack, matching the macOS runner and LV2 ABI. Never use a fixed
         * address in the image/data/heap window. */
        uint32_t slots = (argc_n + 2u) * 8u;
        uint64_t strings_offset = (slots + 0x1Fu) & ~uint64_t(0x1F);
        uint64_t bytes = strings_offset;
        for (uint32_t a = 0; a < argc_n; a++)
            bytes += (strlen(argp[a]) + 1u + 0xFu) & ~uint64_t(0xF);
        const uint32_t entry_frame = 0x80;
        const uint64_t reserve = (entry_frame + bytes + 0x1Fu) & ~uint64_t(0x1F);
        const uint64_t top = stack_top & ~uint64_t(0x1F);
        const uint64_t vm_end = ppu_vm_size ? ppu_vm_size : 0x100000000ull;
        if (reserve > 0x10000 || top > vm_end || top < 0x10000u + reserve) {
            fprintf(stderr, "[ppu] invalid entry argument stack reservation\\n");
            return -1;
        }
        const uint32_t entry_sp = (uint32_t)(top - reserve);
        if (g_ppu_image_min < top && g_ppu_image_max > entry_sp) {
            fprintf(stderr, "[ppu] entry argument stack overlaps loaded image\\n");
            return -1;
        }
        ctx.gpr[1] = entry_sp;
        for (uint32_t off = 0; off < entry_frame; off += 8)
            vm_write64(entry_sp + off, 0);
        const uint32_t argv_base = entry_sp + entry_frame;
        const uint32_t str_addr = argv_base + (uint32_t)strings_offset;
        uint32_t sp_cur = str_addr;
        for (uint32_t a = 0; a < argc_n; a++) {
            uint32_t j = 0;
            for (; argp[a][j]; j++) vm_write8(sp_cur + j, (uint8_t)argp[a][j]);
            vm_write8(sp_cur + j, 0);
            vm_write32(argv_base + a * 8u + 0, 0);
            vm_write32(argv_base + a * 8u + 4, sp_cur);
            sp_cur = (sp_cur + j + 1u + 0xFu) & ~0xFu;
        }
        vm_write32(argv_base + argc_n * 8u + 0, 0);
        vm_write32(argv_base + argc_n * 8u + 4, 0);
        vm_write32(argv_base + (argc_n + 1u) * 8u + 0, 0);
        vm_write32(argv_base + (argc_n + 1u) * 8u + 4, 0);
        ctx.gpr[3] = argc_n;
        ctx.gpr[4] = argv_base;
        ctx.gpr[5] = argv_base + (argc_n + 1u) * 8u;
        ctx.gpr[6] = 0;
        for (uint32_t a = 0; a < argc_n; a++) {
            uint32_t pa = __builtin_bswap32(*(uint32_t*)(vm_base + argv_base + a * 8u + 4));
            char rb[80]; uint32_t k = 0;
            for (; k < 79; k++) { rb[k] = (char)vm_base[pa + k]; if (!rb[k]) break; }
            rb[79] = 0;
            fprintf(stderr, "[ppu] argv[%u] @0x%08X = \\"%s\\"\\n", a, pa, rb);
        }
        fprintf(stderr, "[ppu] argc=%u argv=0x%08X\\n", argc_n, argv_base);""",
    )

    # Ported from demons-souls-recomp's PPU lifter patch: a firmware HLE
    # import stub may begin with "std r2,40(r1)" to preserve the caller's TOC.
    # Replacing the stub body with ps3_hle_call must retain that save, or the
    # caller restores an uninitialised TOC after the HLE call.
    replace_once(
        root, "tools/ppu_lifter.py",
        """        nid = self.hle_stub_nids.get(start)
        if nid is not None:
            func.body_lines.append(
                f"    ps3_hle_call(0x{nid:08X}u, ctx); return;  /* import stub */")""",
        """        nid = self.hle_stub_nids.get(start)
        if nid is not None:
            # Match the macOS port: preserve the caller's TOC when the original
            # import trampoline saves r2 at guest stack offset 0x28.
            if any(ins.raw == 0xF8410028
                   for ins in self._range_insns(instructions, start, end)):
                func.body_lines.append(
                    "    vm_write64(ctx->gpr[1] + 0x28, ctx->gpr[2]);  /* std r2,40(r1) */")
            func.body_lines.append(
                f"    ps3_hle_call(0x{nid:08X}u, ctx); return;  /* import stub */")""",
    )

    # Port the macOS PPU dispatch cache into the iOS runtime. The existing
    # iOS lean path already bypasses diagnostics when safe; cache only positive
    # lookups there, so late PRX registrations remain discoverable on misses.
    replace_once(
        root, "runtime/ppu/ppu_loader.cpp",
        """extern "C" void ps3_indirect_call(ppu_context* ctx)
{
    if ((g_icall_diag_gen == ps3_env_gen ? g_icall_diag : icall_diag_load()) == 0 && g_icall_lean) {
        const uint32_t addr = (uint32_t)ctx->ctr;
        const ppu_fn fn = addr ? ppu_lookup(addr) : nullptr;""",
        """enum { PPU_ICACHE_N = 1024 };
static PPU_THREAD_LOCAL struct { uint32_t addr; ppu_fn fn; } g_ppu_icache[PPU_ICACHE_N];

extern "C" void ps3_indirect_call(ppu_context* ctx)
{
    if ((g_icall_diag_gen == ps3_env_gen ? g_icall_diag : icall_diag_load()) == 0 && g_icall_lean) {
        const uint32_t addr = (uint32_t)ctx->ctr;
        const uint32_t ci = (addr >> 2) & (PPU_ICACHE_N - 1);
        ppu_fn fn = (addr && g_ppu_icache[ci].addr == addr) ? g_ppu_icache[ci].fn : nullptr;
        if (!fn && addr) {
            fn = ppu_lookup(addr);
            if (fn) { g_ppu_icache[ci].addr = addr; g_ppu_icache[ci].fn = fn; }
        }""",
    )

    # Ported from demons-souls-recomp's PPU runtime: the main PPU context is
    # registered in the thread table but has no per-thread stack record. Treat
    # that case like the macOS runner and report its explicitly configured
    # guest stack instead of returning 0+0 to the game.
    replace_once(
        root, "runtime/syscalls/sys_ppu_thread.c",
        "int64_t sys_ppu_thread_get_stack_information(ppu_context* ctx)\\n{",
        """uint32_t g_ppu_main_stack_addr = 0;
uint32_t g_ppu_main_stack_size = 0;

static void main_stack_info(uint32_t* addr, uint32_t* size)
{
    if (g_ppu_main_stack_size) {
        *addr = g_ppu_main_stack_addr;
        *size = g_ppu_main_stack_size;
    } else {
        *addr = VM_STACK_BASE;
        *size = VM_PPU_STACK_SIZE;
    }
}

int64_t sys_ppu_thread_get_stack_information(ppu_context* ctx)
{""",
    )
    replace_once(
        root, "runtime/syscalls/sys_ppu_thread.c",
        """    if (!t) {
        table_unlock();
        /* For the main thread, return sensible defaults */
        if (out_addr != 0) {
            uint32_t* out = (uint32_t*)vm_to_host(out_addr);
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ || defined(_WIN32)
            /* byteswap both fields */
            uint32_t sa = VM_STACK_BASE;
            uint32_t ss = VM_PPU_STACK_SIZE;""",
        """    if (!t || !t->stack_size) {
        table_unlock();
        /* The main PPU context is registered but has no thread stack record. */
        if (out_addr != 0) {
            uint32_t* out = (uint32_t*)vm_to_host(out_addr);
            uint32_t sa, ss;
            main_stack_info(&sa, &ss);
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ || defined(_WIN32)
            /* byteswap both fields */""",
    )
    replace_once(
        root, "runtime/syscalls/sys_ppu_thread.c",
        """#else
            out[0] = VM_STACK_BASE;
            out[1] = VM_PPU_STACK_SIZE;
#endif
        }
        return CELL_OK;
    }""",
        """#else
            out[0] = sa;
            out[1] = ss;
#endif
        }
        return CELL_OK;
    }""",
    )

    # A main thread can already have a thread-table entry with a stack record.
    # The macOS runner's explicit main stack must win for tid 1 in that case too.
    replace_once(
        root, "runtime/syscalls/sys_ppu_thread.c",
        """        uint32_t sa = t->stack_addr;
        uint32_t ss = t->stack_size;""",
        """        uint32_t sa = t->stack_addr;
        uint32_t ss = t->stack_size;
        if (tid == 1 && g_ppu_main_stack_addr) sa = g_ppu_main_stack_addr;
        if (tid == 1 && g_ppu_main_stack_size) ss = g_ppu_main_stack_size;""",
    )

    replace_once(
        root, "libs/video/rsx_metal_backend.m",
        "static NSWindow*           s_window;\n",
        "#if !TARGET_OS_IPHONE\nstatic NSWindow*           s_window;\n#endif\n",
    )
    replace_once(
        root, "libs/video/rsx_metal_backend.m",
        "int rsx_metal_backend_init(u32 width, u32 height, const char* title)\n{",
        """/* The iOS host supplies the MTKView's CAMetalLayer before init. The
 * static reference keeps the layer alive for the backend's frame lifetime. */
void rsx_metal_backend_set_layer(void* layer)
{
#if TARGET_OS_IPHONE
    @autoreleasepool { s_layer = (__bridge CAMetalLayer*)layer; }
#else
    (void)layer;
#endif
}

int rsx_metal_backend_init(u32 width, u32 height, const char* title)
{""",
    )
    replace_once(
        root, "libs/video/rsx_metal_backend.m",
        """        const char* hl = getenv("PS3RECOMP_METAL_HEADLESS");
        s_headless = (hl && *hl && *hl != '0');""",
        """#if TARGET_OS_IPHONE
        /* A supplied layer is the onscreen path; no layer means headless tests. */
        s_headless = (s_layer == nil);
#else
        const char* hl = getenv("PS3RECOMP_METAL_HEADLESS");
        s_headless = (hl && *hl && *hl != '0');
#endif""",
    )
    replace_once(
        root, "libs/video/rsx_metal_backend.m",
        """#if TARGET_OS_IPHONE
        s_headless = 1;
        rc = create_offscreen();
#else
        rc = s_headless ? create_offscreen() : create_window(title);
#endif""",
        """#if TARGET_OS_IPHONE
        if (s_layer) {
            s_layer.device = s_dev;
            s_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            s_layer.framebufferOnly = YES;
            s_layer.drawableSize = CGSizeMake((CGFloat)s_width, (CGFloat)s_height);
            rc = 0;
        } else {
            rc = create_offscreen();
        }
#else
        rc = s_headless ? create_offscreen() : create_window(title);
#endif""",
    )
    replace_once(
        root, "libs/video/rsx_metal_backend.h",
        "int  rsx_metal_backend_init(u32 width, u32 height, const char* title);",
        """/* iOS only: pass the MTKView's CAMetalLayer before init; pass NULL for
 * headless/offscreen rendering. The pointer is retained by the backend. */
void rsx_metal_backend_set_layer(void* layer);
int  rsx_metal_backend_init(u32 width, u32 height, const char* title);""",
    )
    replace_once(
        root, "CMakeLists.txt",
        """    target_link_libraries(ps3recomp_runtime PUBLIC
        "-framework Metal"
        "-framework QuartzCore"
        "-framework Foundation"
        "-framework AppKit"
    )""",
        """    target_link_libraries(ps3recomp_runtime PUBLIC
        "-framework Metal"
        "-framework QuartzCore"
        "-framework Foundation"
    )
    if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        target_link_libraries(ps3recomp_runtime PUBLIC "-framework AppKit")
    else()
        target_compile_definitions(ps3recomp_runtime PRIVATE
            PS3RECOMP_PAD_IOS_NATIVE=1
            PS3RECOMP_AUDIO_IOS_NATIVE=1)
    endif()""",
    )
    replace_once(
        root, "libs/video/rsx_shader_msl.cpp",
        "#include <spirv_cross_c.h>\n",
        "#include <spirv_cross_c.h>\n#include <TargetConditionals.h>\n",
    )
    replace_once(
        root, "libs/video/rsx_shader_msl.cpp",
        "    spvc_compiler_options_set_uint(opt, SPVC_COMPILER_OPTION_MSL_PLATFORM, SPVC_MSL_PLATFORM_MACOS);",
        """#if TARGET_OS_IPHONE
    spvc_compiler_options_set_uint(opt, SPVC_COMPILER_OPTION_MSL_PLATFORM, SPVC_MSL_PLATFORM_IOS);
#else
    spvc_compiler_options_set_uint(opt, SPVC_COMPILER_OPTION_MSL_PLATFORM, SPVC_MSL_PLATFORM_MACOS);
#endif""",
    )
    replace_once(
        root, "libs/audio/cellAudio.c",
        """#if defined(PS3RECOMP_AUDIO_USE_SDL2)
  #define AUDIO_BACKEND_SDL2    1
  #define AUDIO_BACKEND_WASAPI  0
#elif defined(_WIN32)
  #define AUDIO_BACKEND_SDL2    0
  #define AUDIO_BACKEND_WASAPI  1
#else
  #define AUDIO_BACKEND_SDL2    1
  #define AUDIO_BACKEND_WASAPI  0
#endif""",
        """#if defined(PS3RECOMP_AUDIO_IOS_NATIVE)
  #define AUDIO_BACKEND_IOS_NATIVE 1
  #define AUDIO_BACKEND_SDL2    0
  #define AUDIO_BACKEND_WASAPI  0
#elif defined(PS3RECOMP_AUDIO_USE_SDL2)
  #define AUDIO_BACKEND_IOS_NATIVE 0
  #define AUDIO_BACKEND_SDL2    1
  #define AUDIO_BACKEND_WASAPI  0
#elif defined(_WIN32)
  #define AUDIO_BACKEND_IOS_NATIVE 0
  #define AUDIO_BACKEND_SDL2    0
  #define AUDIO_BACKEND_WASAPI  1
#else
  #define AUDIO_BACKEND_IOS_NATIVE 0
  #define AUDIO_BACKEND_SDL2    1
  #define AUDIO_BACKEND_WASAPI  0
#endif""",
    )
    replace_once(
        root, "libs/audio/cellAudio.c",
        """#if AUDIO_BACKEND_SDL2

static SDL_AudioDeviceID s_sdl_audio_dev = 0;""",
        """#if AUDIO_BACKEND_IOS_NATIVE
extern uint32_t soulbrandt_audio_write(const float* interleaved_stereo, uint32_t frames);
extern uint32_t soulbrandt_audio_pull(float* interleaved_stereo, uint32_t frames);
extern uint32_t soulbrandt_audio_room(void);
extern uint32_t soulbrandt_audio_queued_frames(void);
extern void soulbrandt_audio_reset(void);

static int audio_backend_init(void)
{
    /* AVAudioEngine owns the consumer and resets the ring before starting. */
    return 0;
}

static void audio_backend_shutdown(void)
{
    /* Do not reset while AVAudioSourceNode may be reading the ring. */
}

static void audio_backend_submit(const float* stereo_samples, u32 num_samples)
{
    (void)soulbrandt_audio_write(stereo_samples, num_samples);
}

static int audio_backend_room(void)
{
    return soulbrandt_audio_room() >= CELL_AUDIO_BLOCK_SAMPLES
        ? CELL_AUDIO_BLOCK_SAMPLES : 0;
}

static int audio_backend_starving(void)
{
    return soulbrandt_audio_queued_frames() < CELL_AUDIO_BLOCK_SAMPLES * 2u;
}

static u32 audio_backend_queued_samples(void)
{
    return soulbrandt_audio_queued_frames();
}

static void audio_backend_follow(void) {}
#endif /* AUDIO_BACKEND_IOS_NATIVE */

#if AUDIO_BACKEND_SDL2

static SDL_AudioDeviceID s_sdl_audio_dev = 0;""",
    )
    replace_once(
        root, "CMakeLists.txt",
        """    # cellPad and cellAudio select their SDL2 backends unconditionally off
    # Windows (see PAD_BACKEND_SDL2 / AUDIO_BACKEND_SDL2), so SDL2 is required""",
        """    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        message(STATUS "  SDL2:         omitted (native GameController + AVAudioEngine backends)")
    else()
        # cellPad and cellAudio select their SDL2 backends unconditionally off
        # Windows, so SDL2 remains required on Linux and macOS""",
    )
    replace_once(
        root, "CMakeLists.txt",
        """    endif()

    find_package(Threads REQUIRED)""",
        """    endif()
    endif()

    find_package(Threads REQUIRED)""",
    )
    replace_once(
        root, "libs/input/cellPad.c",
        """#if defined(PS3RECOMP_PAD_USE_SDL2)
  #define PAD_BACKEND_SDL2  1
  #define PAD_BACKEND_XINPUT 0
#elif defined(_WIN32)
  #define PAD_BACKEND_SDL2  0
  #define PAD_BACKEND_XINPUT 1
#else
  #define PAD_BACKEND_SDL2  1
  #define PAD_BACKEND_XINPUT 0
#endif""",
        """#if defined(PS3RECOMP_PAD_IOS_NATIVE)
  #define PAD_BACKEND_IOS_NATIVE 1
  #define PAD_BACKEND_SDL2  0
  #define PAD_BACKEND_XINPUT 0
#elif defined(PS3RECOMP_PAD_USE_SDL2)
  #define PAD_BACKEND_IOS_NATIVE 0
  #define PAD_BACKEND_SDL2  1
  #define PAD_BACKEND_XINPUT 0
#elif defined(_WIN32)
  #define PAD_BACKEND_IOS_NATIVE 0
  #define PAD_BACKEND_SDL2  0
  #define PAD_BACKEND_XINPUT 1
#else
  #define PAD_BACKEND_IOS_NATIVE 0
  #define PAD_BACKEND_SDL2  1
  #define PAD_BACKEND_XINPUT 0
#endif""",
    )
    replace_once(
        root, "libs/input/cellPad.c",
        """    hs->press_r1       = (btns & CELL_PAD_CTRL_R1)       ? 255 : 0;
}""",
        """    hs->press_r1       = (btns & CELL_PAD_CTRL_R1)       ? 255 : 0;
}

#if PAD_BACKEND_IOS_NATIVE
typedef struct SoulbrandtPadState {
    u16 buttons;
    u8 connected;
    u8 left_x, left_y, right_x, right_y;
    u8 analog_l2, analog_r2;
} SoulbrandtPadState;
extern void soulbrandt_pad_state_read(SoulbrandtPadState* out_state);

/* GameController is sampled by Swift. This poll copies its latest PS3-format
 * packet into cellPad's normal host state, so the existing guest API remains
 * unchanged and no SDL controller enumeration runs on iOS. */
static void pad_poll_ios_native(void)
{
    SoulbrandtPadState state = { 0, 0, 128, 128, 128, 128, 0, 0 };
    soulbrandt_pad_state_read(&state);
    for (int i = 0; i < PAD_MAX_HOST_PORTS; i++) {
        PadHostState* hs = &s_host_state[i];
        memset(hs, 0, sizeof *hs);
        hs->connected = i == 0 && state.connected != 0;
        hs->analog_lx = hs->analog_ly = hs->analog_rx = hs->analog_ry = 128;
        s_poll_dev[i] = RUMBLE_NONE;
        if (i == 0) {
            hs->buttons = state.buttons;
            hs->analog_lx = state.left_x;
            hs->analog_ly = state.left_y;
            hs->analog_rx = state.right_x;
            hs->analog_ry = state.right_y;
            hs->trigger_l2 = state.analog_l2;
            hs->trigger_r2 = state.analog_r2;
            pad_press_from_buttons(hs);
        }
    }
}

/* Native iOS input is fed by GameController; no SDL/XInput lifecycle exists. */
static void pad_init_backend(void) {}
static void pad_shutdown_backend(void) {}
#endif""",
    )
    replace_once(
        root, "libs/input/cellPad.c",
        "    pad_init_backend();\n",
        "#if !PAD_BACKEND_IOS_NATIVE\n    pad_init_backend();\n#endif\n",
    )
    replace_once(
        root, "libs/input/cellPad.c",
        "    pad_shutdown_backend();\n",
        "#if !PAD_BACKEND_IOS_NATIVE\n    pad_shutdown_backend();\n#endif\n",
    )
    replace_once(
        root, "libs/input/cellPad.c",
        """#if PAD_BACKEND_XINPUT
    pad_poll_xinput();
    pad_poll_hid();
#elif PAD_BACKEND_SDL2
    pad_poll_sdl2();
#endif
    pad_apply_controller();
    pad_publish_devices();
    pad_apply_map();   /* the pads only: the keyboard has its own keys */
#if PAD_BACKEND_XINPUT || PAD_BACKEND_SDL2
    pad_poll_keyboard();
#endif""",
        """#if PAD_BACKEND_IOS_NATIVE
    pad_poll_ios_native();
    pad_publish_devices();
#else
#if PAD_BACKEND_XINPUT
    pad_poll_xinput();
    pad_poll_hid();
#elif PAD_BACKEND_SDL2
    pad_poll_sdl2();
#endif
    pad_apply_controller();
    pad_publish_devices();
    pad_apply_map();   /* the pads only: the keyboard has its own keys */
#if PAD_BACKEND_XINPUT || PAD_BACKEND_SDL2
    pad_poll_keyboard();
#endif
#endif""",
    )

    # Route read-only /dev_bdvd and /app_home cellFs calls through the app's
    # random-access ISO/UDF reader. Other paths keep the existing host VFS.
    replace_once(
        root, "runtime/ppu/ppu_fs.cpp",
        '#include "ps3emu/guest_call.h" /* ps3_invoke_guest: AIO completion is a guest OPD */',
        '#include "ps3emu/guest_call.h" /* ps3_invoke_guest: AIO completion is a guest OPD */\n#include "PS3DiscVFSBridge.h"',
    )
    # Map both bare HDD roots and child paths to the dedicated writable
    # directories supplied by the iOS app.
    replace_once(
        root, "runtime/ppu/ppu_fs.cpp",
        '''if (hdd0_root && strncmp(guest, "/dev_hdd0/", 10) == 0) {
        snprintf(out, cap, "%s/%s", hdd0_root, guest + 10);''',
        '''if (hdd0_root && (strncmp(guest, "/dev_hdd0/", 10) == 0 ||
                       strcmp(guest, "/dev_hdd0") == 0)) {
        const char* hdd0_rel = strcmp(guest, "/dev_hdd0") == 0 ? "" : guest + 10;
        snprintf(out, cap, "%s/%s", hdd0_root, hdd0_rel);''',
    )
    replace_once(
        root, "runtime/ppu/ppu_fs.cpp",
        '''if (hdd1_root && *hdd1_root && strncmp(guest, "/dev_hdd1/", 10) == 0) {
        snprintf(out, cap, "%s/%s", hdd1_root, guest + 10);''',
        '''if (hdd1_root && *hdd1_root &&
        (strncmp(guest, "/dev_hdd1/", 10) == 0 ||
         strcmp(guest, "/dev_hdd1") == 0)) {
        const char* hdd1_rel = strcmp(guest, "/dev_hdd1") == 0 ? "" : guest + 10;
        snprintf(out, cap, "%s/%s", hdd1_root, hdd1_rel);''',
    )

    replace_once(
        root, "runtime/ppu/ppu_fs.cpp",
        'static DIR*  g_dirs[FS_MAX];',
        'static DIR*  g_dirs[FS_MAX];\n#if defined(__APPLE__)\nstatic uint8_t g_disc_dirs[FS_MAX];\nstatic uint32_t g_disc_dir_index[FS_MAX];\nstatic char g_disc_dir_path[FS_MAX][1024];\n#endif',
    )
    replace_once(
        root, "runtime/ppu/ppu_fs.cpp",
        'for (int i = 3; i < FS_MAX; i++) if (!g_files[i] && !g_dirs[i]) { g_files[i] = f; return i; }',
        'for (int i = 3; i < FS_MAX; i++) if (!g_files[i] && !g_dirs[i]\n#if defined(__APPLE__)\n        && !g_disc_dirs[i]\n#endif\n    ) { g_files[i] = f; return i; }',
    )
    replace_once(
        root, "runtime/ppu/ppu_fs.cpp",
        'for (int i = 3; i < FS_MAX; i++) if (!g_files[i] && !g_dirs[i]) { g_dirs[i] = d; return i; }',
        'for (int i = 3; i < FS_MAX; i++) if (!g_files[i] && !g_dirs[i]\n#if defined(__APPLE__)\n        && !g_disc_dirs[i]\n#endif\n    ) { g_dirs[i] = d; return i; }',
    )
    replace_once(
        root, "runtime/ppu/ppu_fs.cpp",
        '/* ---- handlers ---- */',
        '''#if defined(__APPLE__)
/* funopen lets the existing stdio fread/fseek/fclose handlers consume an ISO
 * file without extracting it. The cookie owns a VFS handle and a byte offset. */
struct ps3_disc_cookie { uint64_t handle, size, offset; };
static int ps3_disc_read(void* opaque, char* buffer, int length)
{
    ps3_disc_cookie* c = (ps3_disc_cookie*)opaque;
    if (!c || length <= 0) return 0;
    int32_t n = soulbrandt_disc_vfs_read(c->handle, c->offset, buffer, (uint32_t)length);
    if (n < 0) return -1;
    c->offset += (uint32_t)n;
    return n;
}
static fpos_t ps3_disc_seek(void* opaque, fpos_t offset, int whence)
{
    ps3_disc_cookie* c = (ps3_disc_cookie*)opaque;
    if (!c) { errno = EINVAL; return (fpos_t)-1; }
    int64_t base = whence == SEEK_SET ? 0 :
                   whence == SEEK_CUR ? (int64_t)c->offset :
                   whence == SEEK_END ? (int64_t)c->size : -1;
    if (base < 0 || (offset < 0 && offset < -base) ||
        (offset > 0 && base > INT64_MAX - offset)) {
        errno = EINVAL; return (fpos_t)-1;
    }
    int64_t next = base + (int64_t)offset;
    if (next < 0) { errno = EINVAL; return (fpos_t)-1; }
    c->offset = (uint64_t)next;
    return (fpos_t)next;
}
static int ps3_disc_close(void* opaque)
{
    ps3_disc_cookie* c = (ps3_disc_cookie*)opaque;
    if (c) { soulbrandt_disc_vfs_close(c->handle); free(c); }
    return 0;
}
static int ps3_is_disc_path(const char* path)
{
    return path && (!strncmp(path, "/dev_bdvd", 9) ||
                    !strncmp(path, "/app_home", 9));
}
static FILE* ps3_disc_fopen(const char* path)
{
    uint64_t handle = 0, size = 0;
    if (soulbrandt_disc_vfs_open(path, &handle, &size) != 0) return nullptr;
    ps3_disc_cookie* cookie = (ps3_disc_cookie*)calloc(1, sizeof(*cookie));
    if (!cookie) { soulbrandt_disc_vfs_close(handle); return nullptr; }
    cookie->handle = handle; cookie->size = size;
    FILE* file = funopen(cookie, ps3_disc_read, nullptr, ps3_disc_seek, ps3_disc_close);
    if (!file) ps3_disc_close(cookie);
    return file;
}
#endif

/* ---- handlers ---- */''',
    )
    replace_once(
        root, "runtime/ppu/ppu_fs.cpp",
        '''static void cellFsOpen(ppu_context* ctx)
{
    char gpath[1024], hpath[1100];
    guest_strcpy(gpath, (uint32_t)ctx->gpr[3], sizeof gpath);
    uint32_t flags  = (uint32_t)ctx->gpr[4];
    uint32_t fd_ptr = (uint32_t)ctx->gpr[5];
    host_path(hpath, sizeof hpath, gpath);''',
        '''static void cellFsOpen(ppu_context* ctx)
{
    char gpath[1024], hpath[1100];
    guest_strcpy(gpath, (uint32_t)ctx->gpr[3], sizeof gpath);
    uint32_t flags  = (uint32_t)ctx->gpr[4];
    uint32_t fd_ptr = (uint32_t)ctx->gpr[5];
#if defined(__APPLE__)
    if (ps3_is_disc_path(gpath)) {
        uint64_t ignored_size = 0; uint8_t is_directory = 0;
        if (soulbrandt_disc_vfs_stat(gpath, &ignored_size, &is_directory) == 0 && is_directory) {
            ctx->gpr[3] = (uint64_t)(int64_t)CELL_FS_EISDIR; return;
        }
        if ((flags & 0x3u) != CELL_FS_O_RDONLY) {
            ctx->gpr[3] = (uint64_t)(int64_t)CELL_FS_EIO; return;
        }
        FILE* disc_file = ps3_disc_fopen(gpath);
        if (!disc_file) { ctx->gpr[3] = (uint64_t)(int64_t)CELL_FS_ENOENT; return; }
        int disc_fd = fd_alloc_file(disc_file);
        if (disc_fd < 0) { fclose(disc_file); ctx->gpr[3] = (uint64_t)(int64_t)CELL_FS_EIO; return; }
        if (fd_ptr) vm_write32(fd_ptr, (uint32_t)disc_fd);
        strncpy(g_fd_path[disc_fd], gpath, sizeof g_fd_path[disc_fd] - 1);
        ctx->gpr[3] = CELL_OK;
        return;
    }
#endif
    host_path(hpath, sizeof hpath, gpath);''',
    )
    replace_once(
        root, "runtime/ppu/ppu_fs.cpp",
        '''    host_path(hpath, sizeof hpath, gpath);
    struct stat st;
    if (stat(hpath, &st) != 0) {''',
        '''#if defined(__APPLE__)
    if (ps3_is_disc_path(gpath)) {
        uint64_t size = 0; uint8_t is_directory = 0;
        if (soulbrandt_disc_vfs_stat(gpath, &size, &is_directory) != 0) {
            ctx->gpr[3] = (uint64_t)(int64_t)CELL_FS_ENOENT; return;
        }
        uint32_t mode = is_directory ? (CELL_FS_S_IFDIR | 0x1FF)
                                     : (CELL_FS_S_IFREG | 0x1B6);
        if (sb) write_stat(sb, mode, size);
        ctx->gpr[3] = CELL_OK;
        return;
    }
#endif
    host_path(hpath, sizeof hpath, gpath);
    struct stat st;
    if (stat(hpath, &st) != 0) {''',
    )
    replace_once(
        root, "runtime/ppu/ppu_fs.cpp",
        '''    host_path(hpath, sizeof hpath, gpath);
    DIR* d = opendir(hpath);''',
        '''#if defined(__APPLE__)
    if (ps3_is_disc_path(gpath)) {
        uint64_t ignored_size = 0; uint8_t is_directory = 0;
        if (soulbrandt_disc_vfs_stat(gpath, &ignored_size, &is_directory) != 0 || !is_directory) {
            ctx->gpr[3] = (uint64_t)(int64_t)CELL_FS_ENOENT; return;
        }
        int fd = -1;
        for (int i = 3; i < FS_MAX; i++) {
            if (!g_files[i] && !g_dirs[i] && !g_disc_dirs[i]) { fd = i; break; }
        }
        if (fd < 0) { ctx->gpr[3] = (uint64_t)(int64_t)CELL_FS_EIO; return; }
        g_disc_dirs[fd] = 1;
        g_disc_dir_index[fd] = 0;
        strncpy(g_disc_dir_path[fd], gpath, sizeof g_disc_dir_path[fd] - 1);
        if (fd_ptr) vm_write32(fd_ptr, (uint32_t)fd);
        ctx->gpr[3] = CELL_OK;
        return;
    }
#endif
    host_path(hpath, sizeof hpath, gpath);
    DIR* d = opendir(hpath);''',
    )
    replace_once(
        root, "runtime/ppu/ppu_fs.cpp",
        '''    if (fd < 0 || fd >= FS_MAX || !g_dirs[fd]) { ctx->gpr[3] = (uint64_t)(int64_t)CELL_FS_EIO; return; }
    struct dirent* e = readdir(g_dirs[fd]);''',
        '''    if (fd < 0 || fd >= FS_MAX || (!g_dirs[fd]
#if defined(__APPLE__)
        && !g_disc_dirs[fd]
#endif
    )) { ctx->gpr[3] = (uint64_t)(int64_t)CELL_FS_EIO; return; }
#if defined(__APPLE__)
    if (g_disc_dirs[fd]) {
        char name[256]; uint8_t is_directory = 0;
        int result = soulbrandt_disc_vfs_list(g_disc_dir_path[fd], g_disc_dir_index[fd]++,
                                               name, sizeof name, &is_directory);
        if (result == 0) { if (nread_ptr) vm_write64(nread_ptr, 0); ctx->gpr[3] = CELL_OK; return; }
        if (result < 0) { ctx->gpr[3] = (uint64_t)(int64_t)CELL_FS_EIO; return; }
        size_t nl = strlen(name);
        vm_base[dirent + 0] = is_directory ? CELL_FS_TYPE_DIR : CELL_FS_TYPE_REG;
        vm_base[dirent + 1] = (uint8_t)nl;
        memcpy(vm_base + dirent + 2, name, nl);
        vm_base[dirent + 2 + nl] = 0;
        if (nread_ptr) vm_write64(nread_ptr, 0x102);
        ctx->gpr[3] = CELL_OK;
        return;
    }
#endif
    struct dirent* e = readdir(g_dirs[fd]);''',
    )
    replace_once(
        root, "runtime/ppu/ppu_fs.cpp",
        '''    if (fd >= 0 && fd < FS_MAX && g_dirs[fd]) { closedir(g_dirs[fd]); g_dirs[fd] = nullptr; }
    ctx->gpr[3] = CELL_OK;''',
        '''    if (fd >= 0 && fd < FS_MAX && g_dirs[fd]) { closedir(g_dirs[fd]); g_dirs[fd] = nullptr; }
#if defined(__APPLE__)
    if (fd >= 0 && fd < FS_MAX && g_disc_dirs[fd]) {
        g_disc_dirs[fd] = 0; g_disc_dir_index[fd] = 0; g_disc_dir_path[fd][0] = 0;
    }
#endif
    ctx->gpr[3] = CELL_OK;''',
    )

    # Port the macOS PPU dispatch-cache optimization (ps3recomp-local.patch,
    # fix 68). The current iOS fork already has the diagnostics-free lean path,
    # but it still hashes every repeated guest function-pointer target. Keep a
    # small per-host-thread direct-mapped cache in front of ppu_lookup().
    replace_once(
        root, "runtime/ppu/ppu_loader.cpp",
        """extern "C" void ps3_indirect_call(ppu_context* ctx)
{
    if ((g_icall_diag_gen == ps3_env_gen ? g_icall_diag : icall_diag_load()) == 0 && g_icall_lean) {
        const uint32_t addr = (uint32_t)ctx->ctr;
        const ppu_fn fn = addr ? ppu_lookup(addr) : nullptr;
        if (fn && s_icall_depth <= 4000) {
            g_active_ctx = ctx;
            icall_run(ctx, addr, fn);
            return;
        }
    }
    ps3_indirect_call_full(ctx);
}""",
        """/* Direct-mapped per-host-thread target cache (macOS PPU fix 68).
 * The title's function table is immutable after registration. HighGraphics
 * dispatches through guest function pointers for nearly every scene-graph
 * node, so avoiding a hash-table lookup on repeated targets matters on ARM64
 * too. Misses and unregistered targets retain the full dispatcher path. */
enum { PPU_ICACHE_N = 1024 };
typedef struct ppu_icache_entry {
    uint32_t addr;
    ppu_fn fn;
} ppu_icache_entry;
static PPU_THREAD_LOCAL ppu_icache_entry g_ppu_icache[PPU_ICACHE_N];

extern "C" void ps3_indirect_call(ppu_context* ctx)
{
    if ((g_icall_diag_gen == ps3_env_gen ? g_icall_diag : icall_diag_load()) == 0 && g_icall_lean) {
        const uint32_t addr = (uint32_t)ctx->ctr;
        const uint32_t slot = (addr >> 2) & (PPU_ICACHE_N - 1);
        ppu_fn fn = (addr && g_ppu_icache[slot].addr == addr)
                  ? g_ppu_icache[slot].fn : nullptr;
        if (!fn && addr) {
            fn = ppu_lookup(addr);
            if (fn) {
                g_ppu_icache[slot].addr = addr;
                g_ppu_icache[slot].fn = fn;
            }
        }
        if (fn && s_icall_depth <= 4000) {
            g_active_ctx = ctx;
            icall_run(ctx, addr, fn);
            return;
        }
    }
    ps3_indirect_call_full(ctx);
}""",
    )

    # Implement HDD deletion against the app-owned writable overlays. The
    # imported /dev_bdvd image remains read-only and cannot be unlinked/rmdir'd.
    replace_once(
        root, "runtime/ppu/ppu_fs.cpp",
        '''static void cellFsRmdir(ppu_context* ctx)  { ctx->gpr[3] = CELL_OK; }
static void cellFsUnlink(ppu_context* ctx) { ctx->gpr[3] = CELL_OK; }''',
        '''static int ps3_is_writable_hdd_path(const char* path)
{
    return path && (strncmp(path, "/dev_hdd0/", 10) == 0 ||
                    strncmp(path, "/dev_hdd1/", 10) == 0);
}
static void cellFsRmdir(ppu_context* ctx)
{
    char guest[1024], host[1100];
    guest_strcpy(guest, (uint32_t)ctx->gpr[3], sizeof guest);
    if (!ps3_is_writable_hdd_path(guest)) {
        ctx->gpr[3] = (uint64_t)(int64_t)CELL_FS_EIO; return;
    }
    host_path(host, sizeof host, guest);
    ctx->gpr[3] = rmdir(host) == 0 ? CELL_OK :
        (uint64_t)(int64_t)(errno == ENOENT ? CELL_FS_ENOENT : CELL_FS_EIO);
}
static void cellFsUnlink(ppu_context* ctx)
{
    char guest[1024], host[1100];
    guest_strcpy(guest, (uint32_t)ctx->gpr[3], sizeof guest);
    if (!ps3_is_writable_hdd_path(guest)) {
        ctx->gpr[3] = (uint64_t)(int64_t)CELL_FS_EIO; return;
    }
    host_path(host, sizeof host, guest);
    ctx->gpr[3] = unlink(host) == 0 ? CELL_OK :
        (uint64_t)(int64_t)(errno == ENOENT ? CELL_FS_ENOENT : CELL_FS_EIO);
}''',
    )

    print("ps3recomp iOS host and macOS-derived PPU patches applied (or were already present)")


if __name__ == "__main__":
    main()
