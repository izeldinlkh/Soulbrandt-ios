#include "ppu_recomp.h"
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#if defined(_WIN32)
#define DS_LONGJMP(env, v) longjmp(env, v)
#else
#define DS_LONGJMP(env, v) _longjmp(env, v)
#endif

extern "C" PPU_THREAD_LOCAL void (*g_trampoline_fn)(void*);
extern "C" int* ps3_ppu_dispatch_depth_slot(void);
extern "C" int* ps3_ppu_vcall_sp_slot(void);

namespace {
struct SjEntry {
    jmp_buf env;
    uintptr_t frame;
    uint32_t buf;
    uint32_t guest_r1;
    int depth, vcall_sp;
};
enum { SJ_MAX = 256 };
struct SjStack { SjEntry e[SJ_MAX]; int n; };
PPU_THREAD_LOCAL SjStack* t_sj;
int s_log = -1;
bool sj_log()
{
    if (s_log < 0) {
        const char* v = getenv("DES_SETJMP_LOG");
        s_log = (v && *v == '1') ? 1 : 0;
    }
    return s_log != 0;
}
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
    const uint32_t buf = ((uint32_t)ctx->gpr[3] + 0xF) & ~0xFu;
    const uint32_t r1 = (uint32_t)ctx->gpr[1];

    while (s->n) {
        const SjEntry& t = s->e[s->n - 1];
        if (!(t.frame < f || t.guest_r1 < r1 ||
              (t.frame == f && (t.guest_r1 != r1 || t.buf == buf))))
            break;
        s->n--;
    }
    if (s->n == SJ_MAX) {
        memmove(&s->e[0], &s->e[1], sizeof(SjEntry) * (SJ_MAX - 1));
        s->n--;
        static int warned;
        if (!warned++)
            fprintf(stderr, "[setjmp] more than %d armed jmp_bufs on one thread\\n", SJ_MAX);
    }

    SjEntry& e = s->e[s->n++];
    e.frame = f;
    e.buf = buf;
    e.guest_r1 = r1;
    e.depth = *ps3_ppu_dispatch_depth_slot();
    e.vcall_sp = *ps3_ppu_vcall_sp_slot();
    return &e.env;
}

extern "C" void ds_sj_jump(ppu_context* ctx, uint32_t buf, uint32_t from_lr)
{
    SjStack* s = t_sj;
    const uintptr_t here = (uintptr_t)__builtin_frame_address(0);
    for (int i = s ? s->n - 1 : -1; i >= 0; i--) {
        SjEntry& e = s->e[i];
        if (e.buf != buf || e.frame <= here) continue;
        if (sj_log())
            fprintf(stderr, "[setjmp] longjmp from %08X to buf %08X (entry %d of %d) val %d\\n",
                    from_lr, buf, i, s->n, (int)ctx->gpr[3]);
        s->n = i + 1;
        *ps3_ppu_dispatch_depth_slot() = e.depth;
        *ps3_ppu_vcall_sp_slot() = e.vcall_sp;
        g_trampoline_fn = 0;
#if defined(_WIN64) && defined(_MSC_VER)
        ((_JUMP_BUFFER*)e.env)->Frame = 0;
#endif
        DS_LONGJMP(e.env, 1);
    }
    static int warned;
    if (warned < 8) {
        warned++;
        fprintf(stderr, "[setjmp] longjmp from %08X to buf %08X with no armed setjmp: falling through\\n",
                from_lr, buf);
    }
}
