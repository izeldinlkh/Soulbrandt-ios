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
    print("ps3recomp iOS Metal layer patch applied (or was already present)")


if __name__ == "__main__":
    main()
