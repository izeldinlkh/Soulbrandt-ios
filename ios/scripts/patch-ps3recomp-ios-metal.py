#!/usr/bin/env python3
"""Apply the small iOS host-surface patch to the exact pinned ps3recomp checkout.

The upstream Metal RSX renderer already handles the RSX command stream, guest
shaders, textures, render targets and depth/stencil. Its iOS branch currently
forces headless rendering. This patch lets the app hand it a CAMetalLayer.
"""
from pathlib import Path
import sys


def replace_once(root: Path, relative: str, old: str, new: str) -> None:
    path = root / relative
    source = path.read_text()
    if new in source:
        return
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{relative}: expected one patch anchor, found {count}")
    path.write_text(source.replace(old, new, 1))


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-ps3recomp-ios-metal.py PS3RECOMP_SOURCE_DIR")
    root = Path(sys.argv[1]).resolve()
    if not (root / "libs/video/rsx_metal_backend.m").is_file():
        raise SystemExit(f"not a ps3recomp checkout: {root}")

    replace_once(
        root, "libs/video/rsx_metal_backend.m",
        "static NSWindow*           s_window;\n",
        "#if !TARGET_OS_IPHONE\nstatic NSWindow*           s_window;\n#endif\n",
    )
    replace_once(
        root, "libs/video/rsx_metal_backend.m",
        "int rsx_metal_backend_init(u32 width, u32 height, const char* title)\n{",
        """/* The iOS host supplies the MTKView's CAMetalLayer before init. The
 * static reference keeps the layer alive for the backend's frame lifetime. */
void rsx_metal_backend_set_layer(void* layer)
{
#if TARGET_OS_IPHONE
    @autoreleasepool { s_layer = (__bridge CAMetalLayer*)layer; }
#else
    (void)layer;
#endif
}

int rsx_metal_backend_init(u32 width, u32 height, const char* title)
{""",
    )
    replace_once(
        root, "libs/video/rsx_metal_backend.m",
        """        const char* hl = getenv("PS3RECOMP_METAL_HEADLESS");
        s_headless = (hl && *hl && *hl != '0');""",
        """#if TARGET_OS_IPHONE
        /* A supplied layer is the onscreen path; no layer means headless tests. */
        s_headless = (s_layer == nil);
#else
        const char* hl = getenv("PS3RECOMP_METAL_HEADLESS");
        s_headless = (hl && *hl && *hl != '0');
#endif""",
    )
    replace_once(
        root, "libs/video/rsx_metal_backend.m",
        """#if TARGET_OS_IPHONE
        s_headless = 1;
        rc = create_offscreen();
#else
        rc = s_headless ? create_offscreen() : create_window(title);
#endif""",
        """#if TARGET_OS_IPHONE
        if (s_layer) {
            s_layer.device = s_dev;
            s_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            s_layer.framebufferOnly = YES;
            s_layer.drawableSize = CGSizeMake((CGFloat)s_width, (CGFloat)s_height);
            rc = 0;
        } else {
            rc = create_offscreen();
        }
#else
        rc = s_headless ? create_offscreen() : create_window(title);
#endif""",
    )
    replace_once(
        root, "libs/video/rsx_metal_backend.h",
        "int  rsx_metal_backend_init(u32 width, u32 height, const char* title);",
        """/* iOS only: pass the MTKView's CAMetalLayer before init; pass NULL for
 * headless/offscreen rendering. The pointer is retained by the backend. */
void rsx_metal_backend_set_layer(void* layer);
int  rsx_metal_backend_init(u32 width, u32 height, const char* title);""",
    )
    replace_once(
        root, "CMakeLists.txt",
        """    target_link_libraries(ps3recomp_runtime PUBLIC
        "-framework Metal"
        "-framework QuartzCore"
        "-framework Foundation"
        "-framework AppKit"
    )""",
        """    target_link_libraries(ps3recomp_runtime PUBLIC
        "-framework Metal"
        "-framework QuartzCore"
        "-framework Foundation"
    )
    if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        target_link_libraries(ps3recomp_runtime PUBLIC "-framework AppKit")
    endif()""",
    )
    replace_once(
        root, "libs/video/rsx_shader_msl.cpp",
        "#include <spirv_cross_c.h>\n",
        "#include <spirv_cross_c.h>\n#include <TargetConditionals.h>\n",
    )
    replace_once(
        root, "libs/video/rsx_shader_msl.cpp",
        "    spvc_compiler_options_set_uint(opt, SPVC_COMPILER_OPTION_MSL_PLATFORM, SPVC_MSL_PLATFORM_MACOS);",
        """#if TARGET_OS_IPHONE
    spvc_compiler_options_set_uint(opt, SPVC_COMPILER_OPTION_MSL_PLATFORM, SPVC_MSL_PLATFORM_IOS);
#else
    spvc_compiler_options_set_uint(opt, SPVC_COMPILER_OPTION_MSL_PLATFORM, SPVC_MSL_PLATFORM_MACOS);
#endif""",
    )
    replace_once(
        root, "libs/input/cellPad.c",
        """#if defined(PS3RECOMP_PAD_USE_SDL2)
  #define PAD_BACKEND_SDL2  1
  #define PAD_BACKEND_XINPUT 0
#elif defined(_WIN32)
  #define PAD_BACKEND_SDL2  0
  #define PAD_BACKEND_XINPUT 1
#else
  #define PAD_BACKEND_SDL2  1
  #define PAD_BACKEND_XINPUT 0
#endif""",
        """#if defined(PS3RECOMP_PAD_IOS_NATIVE)
  #define PAD_BACKEND_IOS_NATIVE 1
  #define PAD_BACKEND_SDL2  0
  #define PAD_BACKEND_XINPUT 0
#elif defined(PS3RECOMP_PAD_USE_SDL2)
  #define PAD_BACKEND_IOS_NATIVE 0
  #define PAD_BACKEND_SDL2  1
  #define PAD_BACKEND_XINPUT 0
#elif defined(_WIN32)
  #define PAD_BACKEND_IOS_NATIVE 0
  #define PAD_BACKEND_SDL2  0
  #define PAD_BACKEND_XINPUT 1
#else
  #define PAD_BACKEND_IOS_NATIVE 0
  #define PAD_BACKEND_SDL2  1
  #define PAD_BACKEND_XINPUT 0
#endif""",
    )
    replace_once(
        root, "libs/input/cellPad.c",
        """    hs->press_r1       = (btns & CELL_PAD_CTRL_R1)       ? 255 : 0;
}""",
        """    hs->press_r1       = (btns & CELL_PAD_CTRL_R1)       ? 255 : 0;
}

#if PAD_BACKEND_IOS_NATIVE
typedef struct SoulbrandtPadState {
    u16 buttons;
    u8 connected;
    u8 left_x, left_y, right_x, right_y;
    u8 analog_l2, analog_r2;
} SoulbrandtPadState;
extern void soulbrandt_pad_state_read(SoulbrandtPadState* out_state);

/* GameController is sampled by Swift. This poll copies its latest PS3-format
 * packet into cellPad's normal host state, so the existing guest API remains
 * unchanged and no SDL controller enumeration runs on iOS. */
static void pad_poll_ios_native(void)
{
    SoulbrandtPadState state = { 0, 0, 128, 128, 128, 128, 0, 0 };
    soulbrandt_pad_state_read(&state);
    for (int i = 0; i < PAD_MAX_HOST_PORTS; i++) {
        PadHostState* hs = &s_host_state[i];
        memset(hs, 0, sizeof *hs);
        hs->connected = i == 0 && state.connected != 0;
        hs->analog_lx = hs->analog_ly = hs->analog_rx = hs->analog_ry = 128;
        s_poll_dev[i] = RUMBLE_NONE;
        if (i == 0) {
            hs->buttons = state.buttons;
            hs->analog_lx = state.left_x;
            hs->analog_ly = state.left_y;
            hs->analog_rx = state.right_x;
            hs->analog_ry = state.right_y;
            hs->trigger_l2 = state.analog_l2;
            hs->trigger_r2 = state.analog_r2;
            pad_press_from_buttons(hs);
        }
    }
} 
#endif""",
    )
    replace_once(
        root, "libs/input/cellPad.c",
        """#if PAD_BACKEND_XINPUT
    pad_poll_xinput();
    pad_poll_hid();
#elif PAD_BACKEND_SDL2
    pad_poll_sdl2();
#endif
    pad_apply_controller();
    pad_publish_devices();
    pad_apply_map();   /* the pads only: the keyboard has its own keys */
#if PAD_BACKEND_XINPUT || PAD_BACKEND_SDL2
    pad_poll_keyboard();
#endif""",
        """#if PAD_BACKEND_IOS_NATIVE
    pad_poll_ios_native();
    pad_publish_devices();
#else
#if PAD_BACKEND_XINPUT
    pad_poll_xinput();
    pad_poll_hid();
#elif PAD_BACKEND_SDL2
    pad_poll_sdl2();
#endif
    pad_apply_controller();
    pad_publish_devices();
    pad_apply_map();   /* the pads only: the keyboard has its own keys */
#if PAD_BACKEND_XINPUT || PAD_BACKEND_SDL2
    pad_poll_keyboard();
#endif
#endif""",
    )
    replace_once(
        root, "CMakeLists.txt",
        """    if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        target_link_libraries(ps3recomp_runtime PUBLIC "-framework AppKit")
    endif()""",
        """    if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
        target_link_libraries(ps3recomp_runtime PUBLIC "-framework AppKit")
    else()
        target_compile_definitions(ps3recomp_runtime PRIVATE PS3RECOMP_PAD_IOS_NATIVE=1)
    endif()""",
    )
    print("ps3recomp iOS Metal layer and native cellPad patches applied (or were already present)")


if __name__ == "__main__":
    main()
