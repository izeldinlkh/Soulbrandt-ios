#include "PS3AudioBridge.h"
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>

#define SOULBRANDT_AUDIO_RING_FRAMES 4096u
#define SOULBRANDT_AUDIO_RING_MASK (SOULBRANDT_AUDIO_RING_FRAMES - 1u)

_Static_assert((SOULBRANDT_AUDIO_RING_FRAMES & SOULBRANDT_AUDIO_RING_MASK) == 0,
               "audio ring size must be a power of two");

static float s_audio_ring[SOULBRANDT_AUDIO_RING_FRAMES * 2u];
static _Atomic uint32_t s_audio_write_index;
static _Atomic uint32_t s_audio_read_index;

uint32_t soulbrandt_audio_queued_frames(void)
{
    const uint32_t write = atomic_load_explicit(&s_audio_write_index, memory_order_acquire);
    const uint32_t read = atomic_load_explicit(&s_audio_read_index, memory_order_acquire);
    const uint32_t queued = write - read;
    return queued > SOULBRANDT_AUDIO_RING_FRAMES ? SOULBRANDT_AUDIO_RING_FRAMES : queued;
}

uint32_t soulbrandt_audio_room(void)
{
    return SOULBRANDT_AUDIO_RING_FRAMES - soulbrandt_audio_queued_frames();
}

uint32_t soulbrandt_audio_write(const float *input, uint32_t frames)
{
    if (!input || frames == 0) return 0;

    uint32_t written = 0;
    while (written < frames) {
        const uint32_t write = atomic_load_explicit(&s_audio_write_index, memory_order_relaxed);
        const uint32_t read = atomic_load_explicit(&s_audio_read_index, memory_order_acquire);
        if (write - read >= SOULBRANDT_AUDIO_RING_FRAMES) break;

        const uint32_t slot = write & SOULBRANDT_AUDIO_RING_MASK;
        s_audio_ring[slot * 2u] = input[written * 2u];
        s_audio_ring[slot * 2u + 1u] = input[written * 2u + 1u];
        atomic_store_explicit(&s_audio_write_index, write + 1u, memory_order_release);
        written++;
    }
    return written;
}

uint32_t soulbrandt_audio_pull(float *output, uint32_t frames)
{
    if (!output || frames == 0) return 0;

    uint32_t copied = 0;
    while (copied < frames) {
        const uint32_t read = atomic_load_explicit(&s_audio_read_index, memory_order_relaxed);
        const uint32_t write = atomic_load_explicit(&s_audio_write_index, memory_order_acquire);
        if (read == write) break;

        const uint32_t slot = read & SOULBRANDT_AUDIO_RING_MASK;
        output[copied * 2u] = s_audio_ring[slot * 2u];
        output[copied * 2u + 1u] = s_audio_ring[slot * 2u + 1u];
        atomic_store_explicit(&s_audio_read_index, read + 1u, memory_order_release);
        copied++;
    }

    if (copied < frames) {
        memset(output + copied * 2u, 0, (frames - copied) * 2u * sizeof(float));
    }
    return copied;
}

void soulbrandt_audio_reset(void)
{
    /* Called after the mixer has stopped or before it starts. Keep the monotonic
     * write counter and discard everything already queued without touching the
     * samples the real-time consumer might currently be reading. */
    const uint32_t write = atomic_load_explicit(&s_audio_write_index, memory_order_acquire);
    atomic_store_explicit(&s_audio_read_index, write, memory_order_release);
}
