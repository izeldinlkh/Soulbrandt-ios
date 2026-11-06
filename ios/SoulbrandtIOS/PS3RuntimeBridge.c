#include "PS3RuntimeBridge.h"
#include "PS3PadBridge.h"
#include <stddef.h>

/* Exported by the linked ps3recomp_runtime static library. */
extern int32_t cellPadInit(uint32_t max_connect);
extern int32_t cellPadEnd(void);
extern void cellPad_poll(void);
extern void rsx_metal_backend_set_layer(void *layer);
extern int rsx_metal_backend_init(uint32_t width, uint32_t height, const char *title);
extern void rsx_metal_backend_shutdown(void);

static int s_runtime_pad_ready;
static int s_runtime_rsx_ready;
static int s_runtime_layer_attached;

int32_t soulbrandt_runtime_prepare(void)
{
    if (s_runtime_pad_ready && s_runtime_rsx_ready && s_runtime_layer_attached)
        return 0;

    void *layer = soulbrandt_metal_layer_get();
    if (!layer) return -1000;

    /* The iOS host supplies the MTKView's CAMetalLayer before RSX init. */
    rsx_metal_backend_set_layer(layer);
    s_runtime_layer_attached = 1;

    if (!s_runtime_rsx_ready) {
        const int result = rsx_metal_backend_init(1280, 720, "Soulbrandt");
        if (result != 0) {
            rsx_metal_backend_shutdown();
            rsx_metal_backend_set_layer(NULL);
            s_runtime_layer_attached = 0;
            return result;
        }
        s_runtime_rsx_ready = 1;
    }

    if (!s_runtime_pad_ready) {
        const int32_t result = cellPadInit(1);
        if (result != 0) {
            rsx_metal_backend_shutdown();
            s_runtime_rsx_ready = 0;
            rsx_metal_backend_set_layer(NULL);
            s_runtime_layer_attached = 0;
            return result;
        }
        s_runtime_pad_ready = 1;
    }
    return 0;
}

void soulbrandt_runtime_poll_pad(void)
{
    if (s_runtime_pad_ready) cellPad_poll();
}

void soulbrandt_runtime_shutdown(void)
{
    if (s_runtime_pad_ready) {
        (void)cellPadEnd();
        s_runtime_pad_ready = 0;
    }
    if (s_runtime_rsx_ready) {
        rsx_metal_backend_shutdown();
        s_runtime_rsx_ready = 0;
    }
    if (s_runtime_layer_attached) {
        rsx_metal_backend_set_layer(NULL);
        s_runtime_layer_attached = 0;
    }
}

int32_t soulbrandt_runtime_is_ready(void)
{
    return s_runtime_pad_ready && s_runtime_rsx_ready && s_runtime_layer_attached;
}
