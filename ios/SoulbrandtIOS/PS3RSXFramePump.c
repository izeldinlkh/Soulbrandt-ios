#include "PS3RSXFramePump.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <time.h>
#include <stdint.h>
#include <errno.h>

extern void cellGcmTickVBlank(void);
extern void cellGcmTickFlip(void);
extern void ppu_gcm_pump(void);
extern void cellGcm_rsx_process_fifo(void);
extern int cellGcm_take_flip_pending_synced(void);
extern void rsx_metal_backend_present(void);

#define RSX_VBLANK_NS 16683350L /* 59.94 Hz */
#define RSX_DRAIN_NS   4000000L /* 250 Hz: keep fences moving between vblanks */

static pthread_t s_thread;
static atomic_bool s_running = ATOMIC_VAR_INIT(false);
static atomic_uint s_frames = ATOMIC_VAR_INIT(0);
static int s_thread_created;

static int timespec_compare(const struct timespec *a, const struct timespec *b)
{
    if (a->tv_sec != b->tv_sec) return a->tv_sec < b->tv_sec ? -1 : 1;
    if (a->tv_nsec != b->tv_nsec) return a->tv_nsec < b->tv_nsec ? -1 : 1;
    return 0;
}

static struct timespec timespec_add_ns(struct timespec value, long ns)
{
    value.tv_nsec += ns;
    while (value.tv_nsec >= 1000000000L) {
        value.tv_nsec -= 1000000000L;
        value.tv_sec++;
    }
    return value;
}

static void present_completed_flip(void)
{
    if (cellGcm_take_flip_pending_synced()) {
        rsx_metal_backend_present();
        atomic_fetch_add_explicit(&s_frames, 1, memory_order_relaxed);
    }
}

static void *frame_pump_main(void *unused)
{
    (void)unused;
#if defined(__APPLE__)
    (void)pthread_setname_np("Soulbrandt RSX");
#endif
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    struct timespec next_vblank = timespec_add_ns(now, RSX_VBLANK_NS);

    while (atomic_load_explicit(&s_running, memory_order_acquire)) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (timespec_compare(&now, &next_vblank) >= 0) {
            /* Skip missed clock slots instead of bursting multiple fake vblanks. */
            next_vblank = timespec_add_ns(now, RSX_VBLANK_NS);
            cellGcmTickVBlank();
            cellGcmTickFlip();
            ppu_gcm_pump();
        }

        /* Drain after the tick, then present only at a fully consumed flip boundary. */
        cellGcm_rsx_process_fifo();
        present_completed_flip();

        struct timespec delay = {0, RSX_DRAIN_NS};
        while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
    }
    return NULL;
}

int32_t soulbrandt_rsx_frame_pump_start(void)
{
    if (s_thread_created) return 0;
    atomic_store_explicit(&s_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&s_running, true, memory_order_release);
    const int result = pthread_create(&s_thread, NULL, frame_pump_main, NULL);
    if (result != 0) {
        atomic_store_explicit(&s_running, false, memory_order_release);
        return -(int32_t)result;
    }
    s_thread_created = 1;
    return 0;
}

void soulbrandt_rsx_frame_pump_stop(void)
{
    if (!s_thread_created) return;
    atomic_store_explicit(&s_running, false, memory_order_release);
    (void)pthread_join(s_thread, NULL);
    s_thread_created = 0;
}

int32_t soulbrandt_rsx_frame_pump_is_running(void)
{
    return atomic_load_explicit(&s_running, memory_order_acquire) ? 1 : 0;
}

uint32_t soulbrandt_rsx_frame_pump_frames_presented(void)
{
    return atomic_load_explicit(&s_frames, memory_order_relaxed);
}
