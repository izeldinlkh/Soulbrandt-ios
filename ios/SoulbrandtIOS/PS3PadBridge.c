#include "PS3PadBridge.h"
#include <pthread.h>
#include <string.h>

static pthread_mutex_t s_pad_lock = PTHREAD_MUTEX_INITIALIZER;
static SoulbrandtPadState s_pad_state = {
    .buttons = 0,
    .left_x = 128, .left_y = 128,
    .right_x = 128, .right_y = 128,
    .analog_l2 = 0, .analog_r2 = 0
};

void soulbrandt_pad_state_write(uint16_t buttons,
                                uint8_t left_x, uint8_t left_y,
                                uint8_t right_x, uint8_t right_y,
                                uint8_t analog_l2, uint8_t analog_r2)
{
    SoulbrandtPadState next = {
        .buttons = buttons,
        .left_x = left_x, .left_y = left_y,
        .right_x = right_x, .right_y = right_y,
        .analog_l2 = analog_l2, .analog_r2 = analog_r2
    };
    pthread_mutex_lock(&s_pad_lock);
    s_pad_state = next;
    pthread_mutex_unlock(&s_pad_lock);
}

void soulbrandt_pad_state_read(SoulbrandtPadState *out_state)
{
    if (!out_state) return;
    pthread_mutex_lock(&s_pad_lock);
    *out_state = s_pad_state;
    pthread_mutex_unlock(&s_pad_lock);
}

void soulbrandt_pad_state_reset(void)
{
    soulbrandt_pad_state_write(0, 128, 128, 128, 128, 0, 0);
}
