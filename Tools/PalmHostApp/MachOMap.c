// SPDX-License-Identifier: AGPL-3.0-or-later

#include <LindChain/ProcEnvironment/LiveContainer/LCMachOUtils.h>
#include <limits.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/fcntl.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <libkern/OSByteOrder.h>

LCMachO *LCMapMachOFromFDRO(int fd)
{
    if (fd < 0) {
        return NULL;
    }

    LCMachO *machO = calloc(1, sizeof(LCMachO));
    if (machO == NULL) {
        close(fd);
        return NULL;
    }

    machO->fd = fd;
    machO->ro = true;
    machO->path = malloc(PATH_MAX);
    if (machO->path == NULL) {
        goto fail;
    }
    if (fcntl(machO->fd, F_GETPATH, machO->path) != 0) {
        goto fail;
    }

    struct stat info;
    if (fstat(machO->fd, &info) != 0 || info.st_size <= 0) {
        goto fail;
    }
    machO->size = (size_t)info.st_size;
    machO->map = mmap(NULL, machO->size, PROT_READ, MAP_SHARED, machO->fd, 0);
    if (machO->map == MAP_FAILED) {
        goto fail;
    }

    uint32_t magic = *(uint32_t *)machO->map;
    if (magic == FAT_CIGAM) {
        struct fat_header *header = (struct fat_header *)machO->map;
        struct fat_arch *arch = (struct fat_arch *)((uint8_t *)machO->map + sizeof(struct fat_header));
        uint32_t count = OSSwapInt32(header->nfat_arch);
        for (uint32_t index = 0; index < count; index++) {
            if (OSSwapInt32(arch->cputype) == CPU_TYPE_ARM64) {
                machO->header = (struct mach_header_64 *)((uint8_t *)machO->map + OSSwapInt32(arch->offset));
            }
            arch = (struct fat_arch *)((uint8_t *)arch + sizeof(struct fat_arch));
        }
    } else if (magic == MH_MAGIC_64 || magic == MH_MAGIC) {
        machO->header = (struct mach_header_64 *)machO->map;
    }

    if (machO->header == NULL) {
        munmap(machO->map, machO->size);
        goto fail;
    }
    return machO;

fail:
    free(machO->path);
    free(machO);
    close(fd);
    return NULL;
}

void LCUnmapMachO(LCMachO *machO)
{
    if (machO == NULL) {
        return;
    }
    if (machO->map != NULL && machO->map != MAP_FAILED) {
        munmap(machO->map, machO->size);
    }
    if (machO->fd >= 0) {
        close(machO->fd);
    }
    free(machO->path);
    free(machO);
}
