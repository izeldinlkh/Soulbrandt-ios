#include "PS3AudioBridge.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    float input[8] = { 0.1f, -0.1f, 0.2f, -0.2f, 0.3f, -0.3f, 0.4f, -0.4f };
    float output[8] = { 1, 1, 1, 1, 1, 1, 1, 1 };

    soulbrandt_audio_reset();
    assert(soulbrandt_audio_room() == 4096u);
    assert(soulbrandt_audio_write(input, 4) == 4u);
    assert(soulbrandt_audio_queued_frames() == 4u);
    assert(soulbrandt_audio_pull(output, 2) == 2u);
    assert(output[0] == input[0] && output[1] == input[1]);
    assert(output[2] == input[2] && output[3] == input[3]);
    assert(soulbrandt_audio_queued_frames() == 2u);

    for (unsigned i = 0; i < 8; ++i) output[i] = 1.0f;
    assert(soulbrandt_audio_pull(output, 4) == 2u);
    assert(output[0] == input[4] && output[1] == input[5]);
    assert(output[2] == input[6] && output[3] == input[7]);
    assert(output[4] == 0.0f && output[5] == 0.0f);
    assert(output[6] == 0.0f && output[7] == 0.0f);
    assert(soulbrandt_audio_queued_frames() == 0u);

    float *large = calloc(4096u * 2u, sizeof(float));
    assert(large);
    for (unsigned i = 0; i < 4096u * 2u; ++i) large[i] = (float)i;
    assert(soulbrandt_audio_write(large, 4096u) == 4096u);
    assert(soulbrandt_audio_room() == 0u);
    assert(soulbrandt_audio_write(input, 1u) == 0u);
    assert(soulbrandt_audio_pull(output, 4u) == 4u);
    assert(output[0] == large[0] && output[1] == large[1]);
    assert(soulbrandt_audio_room() == 4u);
    free(large);

    soulbrandt_audio_reset();
    assert(soulbrandt_audio_queued_frames() == 0u);
    puts("PS3 audio bridge smoke test passed");
    return 0;
}
