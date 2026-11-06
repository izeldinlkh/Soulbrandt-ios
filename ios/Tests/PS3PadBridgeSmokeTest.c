#include "../SoulbrandtIOS/PS3PadBridge.h"
#include <assert.h>
#include <stdio.h>

int main(void)
{
    SoulbrandtPadState state;
    soulbrandt_pad_state_reset();
    soulbrandt_pad_state_read(&state);
    assert(state.buttons == 0);
    assert(state.left_x == 128 && state.left_y == 128);
    soulbrandt_pad_state_write(0xC00F, 1, 2, 253, 254, 255, 128);
    soulbrandt_pad_state_read(&state);
    assert(state.buttons == 0xC00F);
    assert(state.left_x == 1 && state.left_y == 2);
    assert(state.right_x == 253 && state.right_y == 254);
    assert(state.analog_l2 == 255 && state.analog_r2 == 128);
    soulbrandt_pad_state_reset();
    soulbrandt_pad_state_read(&state);
    assert(state.buttons == 0 && state.analog_l2 == 0 && state.analog_r2 == 0);
    puts("PS3 pad C bridge smoke test passed");
    return 0;
}
