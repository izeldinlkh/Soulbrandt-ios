#import <Foundation/Foundation.h>

#include "PS3PadBridge.h"
#include "rsx_metal_backend.h"

static bool s_rsx_backend_initialized = false;

extern "C" int soulbrandt_rsx_backend_initialize(void)
{
    if (s_rsx_backend_initialized) return 0;

    void *layer = soulbrandt_metal_layer_get();
    if (!layer) return -2;

    rsx_metal_backend_set_layer(layer);
    const int result = rsx_metal_backend_init(1280, 720, "Soulbrandt iOS");
    if (result != 0) {
        rsx_metal_backend_shutdown();
        return result;
    }

    s_rsx_backend_initialized = true;
    return 0;
}

extern "C" void soulbrandt_rsx_backend_shutdown(void)
{
    if (!s_rsx_backend_initialized) return;
    rsx_metal_backend_shutdown();
    s_rsx_backend_initialized = false;
}
