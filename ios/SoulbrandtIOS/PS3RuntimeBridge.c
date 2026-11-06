#include "PS3RuntimeBridge.h"
#include "PS3PadBridge.h"
#include "PS3GuestMemory.h"
#include "PS3PPUHostBridge.h"
#include "PS3RSXFramePump.h"
#include <stddef.h>

static int s_runtime_pad_ready;
static int s_runtime_rsx_ready;
static int s_runtime_layer_attached;
static int s_runtime_pump_ready;

#if defined(SOULBRANDT_LINKED_RENDER_RUNTIME)
/* These symbols are supplied by the complete des_boot host link. The generic
 * ps3recomp_runtime archive alone is not sufficient: it leaves host globals
 * and game-specific PPU/SPU symbols unresolved. */
extern int32_t cellPadInit(uint32_t max_connect);
extern int32_t cellPadEnd(void);
extern void cellPad_poll(void);
extern void rsx_metal_backend_set_layer(void *layer);
extern int rsx_metal_backend_init(uint32_t width, uint32_t height, const char *title);
extern void rsx_metal_backend_shutdown(void);
#endif

int32_t soulbrandt_runtime_prepare(void)
{
    if (s_runtime_pad_ready && s_runtime_rsx_ready && s_runtime_layer_attached && s_runtime_pump_ready)
        return 0;

    void *layer = soulbrandt_metal_layer_get();
    if (!layer) return -1000;

#if !defined(SOULBRANDT_LINKED_RENDER_RUNTIME)
    /* Renderer/input runtime is not part of this target's link. */
    return -1001;
#else
    const int32_t vm_result = soulbrandt_guest_memory_init();
    if (vm_result != 0) return -1100 + vm_result;

    rsx_metal_backend_set_layer(layer);
    s_runtime_layer_attached = 1;

    if (!s_runtime_rsx_ready) {
        const int result = rsx_metal_backend_init(1280, 720, "Soulbrandt");
        if (result != 0) {
            rsx_metal_backend_shutdown();
            rsx_metal_backend_set_layer(NULL);
            s_runtime_layer_attached = 0;
            soulbrandt_guest_memory_shutdown();
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
            soulbrandt_guest_memory_shutdown();
            return result;
        }
        s_runtime_pad_ready = 1;
    }

    if (!s_runtime_pump_ready) {
        const int32_t result = soulbrandt_rsx_frame_pump_start();
        if (result != 0) {
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
            soulbrandt_guest_memory_shutdown();
            return -1200 + result;
        }
        s_runtime_pump_ready = 1;
    }
    return 0;
#endif
}

void soulbrandt_runtime_poll_pad(void)
{
#if defined(SOULBRANDT_LINKED_RENDER_RUNTIME)
    if (s_runtime_pad_ready) cellPad_poll();
#endif
}

void soulbrandt_runtime_shutdown(void)
{
    /* ppu_run has no cooperative stop API. Never unmap vm_base or tear down
     * RSX/HLE state while the guest entry thread is still executing. */
    if (soulbrandt_ppu_host_is_running()) return;
#if defined(SOULBRANDT_LINKED_RENDER_RUNTIME)
    if (s_runtime_pump_ready) {
        soulbrandt_rsx_frame_pump_stop();
        s_runtime_pump_ready = 0;
    }
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
    soulbrandt_ppu_host_reset_image();
    soulbrandt_guest_memory_shutdown();
#else
    s_runtime_pad_ready = 0;
    s_runtime_rsx_ready = 0;
    s_runtime_layer_attached = 0;
    s_runtime_pump_ready = 0;
#endif
}

int32_t soulbrandt_runtime_is_ready(void)
{
    return s_runtime_pad_ready && s_runtime_rsx_ready && s_runtime_layer_attached && s_runtime_pump_ready;
}
