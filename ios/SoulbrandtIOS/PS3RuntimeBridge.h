#ifndef SOULBRANDT_PS3_RUNTIME_BRIDGE_H
#define SOULBRANDT_PS3_RUNTIME_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Prepares the patched PS3 runtime's native cellPad backend and gives its
 * Metal RSX backend the CAMetalLayer owned by the app's MTKView. */
int32_t soulbrandt_runtime_prepare(void);
void soulbrandt_runtime_poll_pad(void);
void soulbrandt_runtime_shutdown(void);
int32_t soulbrandt_runtime_is_ready(void);

#ifdef __cplusplus
}
#endif
#endif
