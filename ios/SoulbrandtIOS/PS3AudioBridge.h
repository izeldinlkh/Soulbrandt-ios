#ifndef SOULBRANDT_PS3_AUDIO_BRIDGE_H
#define SOULBRANDT_PS3_AUDIO_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Lock-free single-producer/single-consumer stereo float ring.
 * Producer: ps3recomp cellAudio mixer thread.
 * Consumer: AVAudioSourceNode real-time render callback.
 */
uint32_t soulbrandt_audio_write(const float *interleaved_stereo, uint32_t frames);
uint32_t soulbrandt_audio_pull(float *interleaved_stereo, uint32_t frames);
uint32_t soulbrandt_audio_room(void);
uint32_t soulbrandt_audio_queued_frames(void);
void soulbrandt_audio_reset(void);

#ifdef __cplusplus
}
#endif
#endif
