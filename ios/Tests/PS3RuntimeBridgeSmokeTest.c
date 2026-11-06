#include "PS3RuntimeBridge.h"
#include "PS3GuestMemory.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>

static int s_layer_token;
static void *s_layer;
static int s_rsx_init_result;
static int s_pad_init_result;
static int s_rsx_init_calls, s_rsx_shutdown_calls, s_pad_init_calls;
static int s_pad_end_calls, s_pad_poll_calls, s_layer_set_calls;
static int s_pump_start_result;
static int s_pump_start_calls, s_pump_stop_calls;

int32_t soulbrandt_rsx_frame_pump_start(void)
{
    s_pump_start_calls++;
    return s_pump_start_result;
}
void soulbrandt_rsx_frame_pump_stop(void) { s_pump_stop_calls++; }

void *soulbrandt_metal_layer_get(void) { return s_layer; }
void soulbrandt_metal_layer_set(void *layer) { s_layer = layer; }
void soulbrandt_metal_layer_clear(void *layer) { if (s_layer == layer) s_layer = NULL; }

void rsx_metal_backend_set_layer(void *layer)
{
    s_layer = layer;
    s_layer_set_calls++;
}
int rsx_metal_backend_init(uint32_t width, uint32_t height, const char *title)
{
    assert(width == 1280 && height == 720);
    assert(title != NULL);
    assert(s_layer == &s_layer_token);
    s_rsx_init_calls++;
    return s_rsx_init_result;
}
void rsx_metal_backend_shutdown(void) { s_rsx_shutdown_calls++; }
int32_t cellPadInit(uint32_t max_connect)
{
    assert(max_connect == 1);
    s_pad_init_calls++;
    return s_pad_init_result;
}
int32_t cellPadEnd(void) { s_pad_end_calls++; return 0; }
void cellPad_poll(void) { s_pad_poll_calls++; }

int main(void)
{
    /* A view must publish its layer before runtime preparation. */
    assert(soulbrandt_runtime_prepare() == -1000);
    assert(s_rsx_init_calls == 0 && s_pad_init_calls == 0);
    assert(!soulbrandt_guest_memory_is_ready());

    s_layer = &s_layer_token;
    assert(soulbrandt_runtime_prepare() == 0);
    assert(soulbrandt_runtime_is_ready());
    assert(s_rsx_init_calls == 1 && s_pad_init_calls == 1);
    assert(s_pump_start_calls == 1 && s_pump_stop_calls == 0);
    assert(soulbrandt_guest_memory_is_ready());

    /* Repeated SwiftUI updates must not initialise the runtime twice. */
    assert(soulbrandt_runtime_prepare() == 0);
    assert(s_rsx_init_calls == 1 && s_pad_init_calls == 1);
    soulbrandt_runtime_poll_pad();
    assert(s_pad_poll_calls == 1);

    soulbrandt_runtime_shutdown();
    assert(!soulbrandt_runtime_is_ready());
    assert(s_pad_end_calls == 1 && s_rsx_shutdown_calls == 1);
    assert(s_pump_stop_calls == 1);
    assert(!soulbrandt_guest_memory_is_ready());
    assert(s_layer == NULL);

    /* A failed RSX init is cleaned up and can be retried. */
    s_layer = &s_layer_token;
    s_rsx_init_result = -9;
    assert(soulbrandt_runtime_prepare() == -9);
    assert(!soulbrandt_runtime_is_ready());
    assert(s_rsx_shutdown_calls == 2 && s_layer == NULL);
    assert(!soulbrandt_guest_memory_is_ready());

    /* A pad init failure also tears down the already-created RSX backend. */
    s_rsx_init_result = 0;
    s_pad_init_result = -7;
    s_layer = &s_layer_token;
    assert(soulbrandt_runtime_prepare() == -7);
    assert(!soulbrandt_runtime_is_ready());
    assert(s_rsx_shutdown_calls == 3 && s_layer == NULL);
    assert(!soulbrandt_guest_memory_is_ready());

    /* A frame-pump start failure must unwind pad, RSX, layer and guest VM. */
    s_pad_init_result = 0;
    s_pump_start_result = -5;
    s_layer = &s_layer_token;
    assert(soulbrandt_runtime_prepare() == -1205);
    assert(!soulbrandt_runtime_is_ready());
    assert(s_pad_end_calls == 2 && s_rsx_shutdown_calls == 4);
    assert(s_pump_start_calls == 2 && s_pump_stop_calls == 1);
    assert(s_layer == NULL);
    assert(!soulbrandt_guest_memory_is_ready());

    /* All subsystems can be started cleanly after the failed pump attempt. */
    s_pump_start_result = 0;
    s_layer = &s_layer_token;
    assert(soulbrandt_runtime_prepare() == 0);
    assert(soulbrandt_runtime_is_ready());
    assert(s_pump_start_calls == 3);
    soulbrandt_runtime_shutdown();
    assert(!soulbrandt_runtime_is_ready());
    assert(s_pump_stop_calls == 2);

    puts("PS3 runtime bridge lifecycle smoke test passed");
    return 0;
}
