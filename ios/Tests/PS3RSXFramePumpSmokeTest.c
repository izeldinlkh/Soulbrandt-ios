#include "PS3RSXFramePump.h"

#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

static atomic_uint s_vblanks;
static atomic_uint s_flips;
static atomic_uint s_pumps;
static atomic_uint s_drains;
static atomic_uint s_presents;
static atomic_int s_flip_pending;

void cellGcmTickVBlank(void) { atomic_fetch_add(&s_vblanks, 1); }
void cellGcmTickFlip(void) { atomic_fetch_add(&s_flips, 1); }
void ppu_gcm_pump(void) { atomic_fetch_add(&s_pumps, 1); }
void cellGcm_rsx_process_fifo(void)
{
    const unsigned n = atomic_fetch_add(&s_drains, 1) + 1;
    if ((n % 3u) == 0u) atomic_store(&s_flip_pending, 1);
}
int cellGcm_take_flip_pending_synced(void) { return atomic_exchange(&s_flip_pending, 0); }
void rsx_metal_backend_present(void) { atomic_fetch_add(&s_presents, 1); }

static void sleep_ms(long ms)
{
    struct timespec delay = {ms / 1000, (ms % 1000) * 1000000L};
    nanosleep(&delay, NULL);
}

int main(void)
{
    if (soulbrandt_rsx_frame_pump_start() != 0) return 1;
    if (!soulbrandt_rsx_frame_pump_is_running()) return 2;
    if (soulbrandt_rsx_frame_pump_start() != 0) return 3;
    sleep_ms(90);
    soulbrandt_rsx_frame_pump_stop();
    if (soulbrandt_rsx_frame_pump_is_running()) return 4;
    if (atomic_load(&s_vblanks) < 3) return 5;
    if (atomic_load(&s_flips) < 3 || atomic_load(&s_pumps) < 3) return 6;
    if (atomic_load(&s_drains) < 10) return 7;
    if (atomic_load(&s_presents) == 0) return 8;
    const unsigned drains = atomic_load(&s_drains);
    sleep_ms(20);
    if (atomic_load(&s_drains) != drains) return 9;
    soulbrandt_rsx_frame_pump_stop();
    if (soulbrandt_rsx_frame_pump_frames_presented() == 0) return 10;
    puts("PS3 RSX frame pump smoke test passed");
    return 0;
}
