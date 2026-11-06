#ifndef SOULBRANDT_PS3_PAD_BRIDGE_H
#define SOULBRANDT_PS3_PAD_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SoulbrandtPadState {
    uint16_t buttons;
    uint8_t left_x, left_y, right_x, right_y;
    uint8_t analog_l2, analog_r2;
} SoulbrandtPadState;

// Thread-safe boundary between GameController callbacks and the PS3 cellPad HLE.
void soulbrandt_pad_state_write(uint16_t buttons,
                                uint8_t left_x, uint8_t left_y,
                                uint8_t right_x, uint8_t right_y,
                                uint8_t analog_l2, uint8_t analog_r2);
void soulbrandt_pad_state_read(SoulbrandtPadState *out_state);
void soulbrandt_pad_state_reset(void);

#ifdef __cplusplus
}
#endif
#endif
