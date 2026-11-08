/* Demon's Souls PPU setjmp/longjmp bridge, ported from the working macOS runner.
 *
 * The guest libc setjmp saves guest registers in guest RAM. A lifted longjmp
 * restores those registers, but returning normally through the generated C++
 * dispatcher would continue with host frames belonging to the wrong guest
 * call chain. Arm a host jmp_buf at each guest setjmp call site and resume it
 * when the lifted guest longjmp is reached.
 *
 * The iOS ps3recomp revision has one dispatcher depth counter (unlike the
 * macOS fork's additional virtual-call stack), so only that state is restored.
 */
#include "ppu_recomp.h"
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define DS_LONGJMP(env, value) _longjmp((env), (value))

extern "C" PPU_THREAD_LOCAL void (*g_trampoline_fn)(void*);
extern "C" int* ps3_ppu_dispatch_depth_slot(void);

namespace {
struct SjEntry {
    jmp_buf env;
    uintptr_t frame;
    uint32_t buf;
    uint32_t guest_r1;
    int depth;
};
enum { SJ_MAX = 256 };
struct SjStack { SjEntry e[SJ_MAX]; int n; };
PPU_THREAD_LOCAL SjStack* t_sj;
}

extern "C" void* ds_sj_arm(ppu_context* ctx, void* host_frame)
{
    SjStack* s = t_sj;
    if (!s) {
        s = (SjStack*)calloc(1, sizeof(SjStack));
        if (!s) abort();
        t_sj = s;
    }
    const uintptr_t f = (uintptr_t)host_frame;
    const uint32_t buf = ((uint32_t)ctx->gpr[3] + 0xFu) & ~0xFu;
    const uint32_t r1 = (uint32_t)ctx->gpr[1];

    /* Discard entries whose lifted caller has returned, or which are being
     * re-armed by the same host frame for a different guest stack/buffer. */
    while (s->n) {
        const SjEntry& top = s->e[s->n - 1];
        if (!(top.frame < f || top.guest_r1 < r1 ||
              (top.frame == f && (top.guest_r1 != r1 || top.buf == buf))))
            break;
        --s->n;
    }
    if (s->n == SJ_MAX) {
        memmove(&s->e[0], &s->e[1], sizeof(SjEntry) * (SJ_MAX - 1));
        --s->n;
        static int warned;
        if (!warned++) fprintf(stderr, "[setjmp] more than %d armed guest buffers on one thread\n", SJ_MAX);
    }

    SjEntry& e = s->e[s->n++];
    e.frame = f;
    e.buf = buf;
    e.guest_r1 = r1;
    e.depth = *ps3_ppu_dispatch_depth_slot();
    return &e.env;
}

extern "C" void ds_sj_jump(ppu_context* ctx, uint32_t buf, uint32_t from_lr)
{
    SjStack* s = t_sj;
    const uintptr_t here = (uintptr_t)__builtin_frame_address(0);
    for (int i = s ? s->n - 1 : -1; i >= 0; --i) {
        SjEntry& e = s->e[i];
        if (e.buf != buf || e.frame <= here) continue;

        s->n = i + 1;
        *ps3_ppu_dispatch_depth_slot() = e.depth;
        g_trampoline_fn = nullptr;
        DS_LONGJMP(e.env, 1);
    }

    static int warned;
    if (warned < 8) {
        ++warned;
        fprintf(stderr, "[setjmp] longjmp from %08X to guest buffer %08X has no armed host frame; continuing\n",
                from_lr, buf);
    }
    (void)ctx;
}
