#ifndef SOULBRANDT_DISC_VFS_BRIDGE_H
#define SOULBRANDT_DISC_VFS_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Read-only virtual disc API. Paths accept /dev_bdvd/... and /app_home/...
 * or volume-relative absolute paths. list returns 1=entry, 0=end, <0=error.
 * read returns byte count, 0=EOF, <0=error. */
int32_t soulbrandt_disc_vfs_open(const char *path, uint64_t *handle, uint64_t *size);
int32_t soulbrandt_disc_vfs_read(uint64_t handle, uint64_t offset,
                                void *output, uint32_t length);
int32_t soulbrandt_disc_vfs_close(uint64_t handle);
int32_t soulbrandt_disc_vfs_list(const char *path, uint32_t index,
                                char *name, uint32_t capacity, uint8_t *is_directory);
int32_t soulbrandt_disc_vfs_stat(const char *path, uint64_t *size,
                                uint8_t *is_directory);

#ifdef __cplusplus
}
#endif
#endif
