#ifndef SOULBRANDT_PPU_HOST_BRIDGE_H
#define SOULBRANDT_PPU_HOST_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Load the decrypted EBOOT through ps3recomp, then register the compiled PPU
 * lift, HLE NIDs, sysPrx CRT, cellFs VFS and LV2 syscall table. This does not
 * dispatch guest code; ppu_run remains gated on a real title lift. */
uint32_t soulbrandt_ppu_host_load_elf(const char *path);
/* Initializes the title ID/name/version from the disc PARAM.SFO before boot. */
int32_t soulbrandt_ppu_host_init_title_metadata(const char *paramsfo_path);
int32_t soulbrandt_ppu_host_set_storage_roots(const char *hdd0_root, const char *hdd1_root);
/* Clear the cached image entry before guest memory is unmapped. */
void soulbrandt_ppu_host_reset_image(void);
uint32_t soulbrandt_ppu_host_function_count(void);
uint32_t soulbrandt_ppu_host_hle_count(void);
int32_t soulbrandt_ppu_host_is_ready(void);
/* Starts ppu_run on a dedicated host thread. Requires a non-empty title lift. */
int32_t soulbrandt_ppu_host_start_game(void);
int32_t soulbrandt_ppu_host_is_running(void);
/* INT32_MIN means ppu_run has not returned yet. */
int32_t soulbrandt_ppu_host_run_result(void);

#ifdef __cplusplus
}
#endif
#endif
