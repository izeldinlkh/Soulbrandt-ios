#import <Foundation/Foundation.h>

#include "PS3RuntimeBridge.h"

extern "C" int soulbrandt_rsx_backend_initialize(void)
{
    return soulbrandt_runtime_prepare();
}

extern "C" void soulbrandt_rsx_backend_shutdown(void)
{
    soulbrandt_runtime_shutdown();
}
