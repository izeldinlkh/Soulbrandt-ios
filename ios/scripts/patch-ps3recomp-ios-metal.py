#!/usr/bin/env python3
"""Patch the pinned ps3recomp Metal backend to accept an iOS CAMetalLayer."""
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch-ps3recomp-ios-metal.py PATH_TO_PS3RECOMP")

root = Path(sys.argv[1])
source_path = root / "libs/video/rsx_metal_backend.m"
header_path = root / "libs/video/rsx_metal_backend.h"
cmake_path = root / "CMakeLists.txt"

def replace_once(path: Path, old: str, new: str) -> None:
    content = path.read_text()
    count = content.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one patch anchor, found {count}: {old[:90]!r}")
    path.write_text(content.replace(old, new, 1))

replace_once(source_path, '#import <QuartzCore/CAMetalLayer.h>\n',
             '#import <QuartzCore/CAMetalLayer.h>\n#import <TargetConditionals.h>\n')
replace_once(source_path,
             'static CAMetalLayer*       s_layer;      /* windowed only   */\n',
             'static CAMetalLayer*       s_layer;      /* AppKit window or host-provided UIKit layer */\n'
             '#if TARGET_OS_IPHONE\nstatic CAMetalLayer*       s_external_layer;\n#endif\n')
replace_once(source_path, 'static NSWindow*           s_window;\n',
             '#if !TARGET_OS_IPHONE\nstatic NSWindow*           s_window;\n#endif\n')
replace_once(source_path, '#endif\n\nstatic int create_placeholders(void)\n',
             '#endif\n\n'
             '#if TARGET_OS_IPHONE\n'
             '/* UIKit owns this CAMetalLayer; no NSWindow or AppKit event pump exists on iOS. */\n'
             'static int attach_ios_layer(void)\n'
             '{\n'
             '    if (!s_external_layer) return -1;\n'
             '    s_layer = s_external_layer;\n'
             '    s_layer.device = s_dev;\n'
             '    s_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;\n'
             '    s_layer.framebufferOnly = YES;\n'
             '    if (s_layer.drawableSize.width <= 0 || s_layer.drawableSize.height <= 0)\n'
             '        s_layer.drawableSize = CGSizeMake((CGFloat)s_width, (CGFloat)s_height);\n'
             '    return 0;\n'
             '}\n'
             '#endif\n\n'
             'static int create_placeholders(void)\n')
replace_once(source_path,
             '/* ---- public API ---------------------------------------------------------- */\n\nint rsx_metal_backend_init(u32 width, u32 height, const char* title)\n',
             '/* ---- public API ---------------------------------------------------------- */\n\n'
             'void rsx_metal_backend_set_layer(void* layer)\n'
             '{\n'
             '#if TARGET_OS_IPHONE\n'
             '    @autoreleasepool { s_external_layer = layer ? (__bridge CAMetalLayer*)layer : nil; }\n'
             '#else\n'
             '    (void)layer;\n'
             '#endif\n'
             '}\n\n'
             'int rsx_metal_backend_init(u32 width, u32 height, const char* title)\n')
replace_once(source_path,
             '#if TARGET_OS_IPHONE\n        s_headless = 1;\n        rc = create_offscreen();\n#else\n',
             '#if TARGET_OS_IPHONE\n'
             '        s_headless = (s_external_layer == nil);\n'
             '        rc = s_headless ? create_offscreen() : attach_ios_layer();\n'
             '#else\n')
replace_once(header_path,
             'int  rsx_metal_backend_init(u32 width, u32 height, const char* title);\n',
             '/* On iOS, pass the host-owned CAMetalLayer (normally MTKView.layer) before init. */\n'
             'void rsx_metal_backend_set_layer(void* layer);\n'
             'int  rsx_metal_backend_init(u32 width, u32 height, const char* title);\n')
replace_once(cmake_path,
             '    target_link_libraries(ps3recomp_runtime PUBLIC\n'
             '        "-framework Metal"\n'
             '        "-framework QuartzCore"\n'
             '        "-framework Foundation"\n'
             '        "-framework AppKit"\n'
             '    )\n',
             '    target_link_libraries(ps3recomp_runtime PUBLIC\n'
             '        "-framework Metal"\n'
             '        "-framework QuartzCore"\n'
             '        "-framework Foundation"\n'
             '    )\n'
             '    if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")\n'
             '        target_link_libraries(ps3recomp_runtime PUBLIC "-framework AppKit")\n'
             '    endif()\n')
print("iOS CAMetalLayer patch applied to pinned ps3recomp source")
