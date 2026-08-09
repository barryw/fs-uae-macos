#ifndef FS_UAE_CONFIG_DRIVES_H
#define FS_UAE_CONFIG_DRIVES_H

#include "config-common.h"

void fs_uae_configure_floppies(void);
void fs_uae_configure_hard_drives(void);
void fs_uae_configure_host_directory(const char *path, const char *device,
                                     const char *label, int boot_priority);
void fs_uae_configure_cdrom(void);

#endif /* FS_UAE_CONFIG_DRIVES_H */
