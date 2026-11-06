#ifndef SOULBRANDT_RSX_FRAME_PUMP_H
#define SOULBRANDT_RSX_FRAME_PUMP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Starts the 59.94 Hz GCM interrupt clock and 4 ms RSX FIFO drain thread. */
int32_t soulbrandt_rsx_frame_pump_start(void);
void soulbrandt_rsx_frame_pump_stop(void);
int32_t soulbrandt_rsx_frame_pump_is_running(void);
uint32_t soulbrandt_rsx_frame_pump_frames_presented(void);

#ifdef __cplusplus
}
#endif
#endif
