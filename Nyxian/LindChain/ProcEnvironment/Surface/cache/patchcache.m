/*
 SPDX-License-Identifier: AGPL-3.0-or-later

 Copyright (C) 2025 - 2026 emexlab

 This file is part of Nyxian.

 Nyxian is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Nyxian is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with Nyxian. If not, see <https://www.gnu.org/licenses/>.
*/

#import <LindChain/IDEFoundation/NXBootstrap.h>
#import <LindChain/ProcEnvironment/Surface/cache/patchcache.h>
#import <LindChain/ProcEnvironment/Surface/fs/mount.h>
#import <LindChain/ProcEnvironment/Surface/libkern/klog.h>
#import <LindChain/ProcEnvironment/litehook/litehook.h>
#import <LindChain/ProcEnvironment/LiveContainer/LCMachOUtils.h>
#import <LindChain/ProcEnvironment/LiveContainer/utils.h>
#include <string.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <mach-o/dyld_images.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <dlfcn.h>
#import <Foundation/Foundation.h>

typedef struct {
    uint64_t signature;
    void *found;
} dyld_search_entry_t;

static struct dyld_all_image_infos *_alt_dyld_get_all_image_infos(void)
{
    static struct dyld_all_image_infos *result;
    if(result != NULL)
    {
        return result;
    }
    
    struct task_dyld_info dyldInfo = {0};
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_DYLD_INFO, (task_info_t)&dyldInfo, &count);
    if(kr != KERN_SUCCESS ||
       dyldInfo.all_image_info_addr == 0)
    {
        return NULL;
    }
    
    result = (struct dyld_all_image_infos *)(uintptr_t)dyldInfo.all_image_info_addr;
    
    return result;
}

static inline bool a64_is_bl(uint32_t insn)
{
    return (insn & 0xFC000000u) == 0x94000000u;
}

static inline uintptr_t a64_resolve_bl(const uint32_t *pc)
{
    uint32_t insn = *pc;
    int64_t imm26 = (int64_t)(insn & 0x03FFFFFFu);
    if(imm26 & 0x02000000LL)
    {
        imm26 |= ~0x03FFFFFFLL;
    }
    return (uintptr_t)pc + (imm26 << 2);
}

static void *findDyldFcntl17(const char *base)
{
    static const uint32_t movFAddFileSigsReturn = 0x52800C21;
    static const uint32_t movFGetSigsInfo = 0x52800D21;
    
    const size_t scanSize = 0x80000;
    const uint32_t *text = (const uint32_t *)base;
    const size_t count = scanSize / sizeof(uint32_t);
    
    for(size_t i = 0; i < count; i++)
    {
        if(text[i] != movFAddFileSigsReturn)
        {
            continue;
        }
        
        size_t bl1End = i + 12;
        if(bl1End > count)
        {
            bl1End = count;
        }
        
        for (size_t j = i + 1; j < bl1End; j++)
        {
            if(!a64_is_bl(text[j]))
            {
                continue;
            }
            
            uintptr_t target1 = a64_resolve_bl(&text[j]);
            size_t secondEnd = i + 0x100;
            if(secondEnd > count)
            {
                secondEnd = count;
            }
            
            for (size_t k = j + 1; k < secondEnd; k++)
            {
                if(text[k] != movFGetSigsInfo)
                {
                    continue;
                }
                
                size_t bl2End = k + 12;
                if(bl2End > count)
                {
                    bl2End = count;
                }
                
                for(size_t l = k + 1; l < bl2End; l++)
                {
                    if(!a64_is_bl(text[l]))
                    {
                        continue;
                    }
                    
                    uintptr_t target2 =
                    a64_resolve_bl(&text[l]);
                    
                    if(target1 == target2)
                    {
                        return (void *)target1;
                    }
                }
            }
        }
    }
    
    return NULL;
}

static void searchDyldFunctions(const char *base,
                                dyld_search_entry_t *entries,
                                size_t count)
{
    if(base == NULL || entries == NULL || count == 0)
    {
        return;
    }
    
    size_t remaining = count;
    
    for(size_t i = 0; i < count; i++)
    {
        entries[i].found = NULL;
    }
    
    for(size_t off = 0; off + sizeof(uint64_t) <= (0x80000); off += 4)
    {
        uint64_t value;
        memcpy(&value, base + off, sizeof(value));
        for(size_t i = 0; i < count; i++)
        {
            if(entries[i].found != NULL)
            {
                continue;
            }
            if(entries[i].signature != value)
            {
                continue;
            }
            entries[i].found =
            (void *)(base + off);
            if(--remaining == 0)
            {
                return;
            }
        }
    }
}


static kern_return_t findDyldFunctionPointers(uint64_t out[kDyldPtrCount])
{
    if(out == NULL)
    {
        return KERN_INVALID_ARGUMENT;
    }
    
    memset(out, 0, sizeof(uint64_t) * kDyldPtrCount);
    struct dyld_all_image_infos *infos = _alt_dyld_get_all_image_infos();
    if(infos == NULL)
    {
        klog_log("patchfinder:emit", "couldn't obtain dyld_all_image_infos");
        return KERN_FAILURE;
    }
    
    const char *dyldBase = (const char *)infos->dyldImageLoadAddress;
    if(dyldBase == NULL)
    {
        klog_log("patchfinder:emit", "dyldImageLoadAddress is NULL");
        return KERN_FAILURE;
    }
    
    static dyld_search_entry_t entries[kDyldPtrCount] = {
        /* first shit */
        [kDyldPtrOpen] = {
            .signature = 0xD4001001D28000B0ULL,
            .found = NULL,
        },
        [kDyldPtrFcntl] = {
            .signature = 0xD4001001D2800B90ULL,
            .found = NULL,
        },
        [kDyldPtrFstat64] = {
            .signature = 0xD4001001D2802A70ULL,
            .found = NULL,
        },
        [kDyldPtrStat64] = {
            .signature = 0xD4001001D2802A50ULL,
            .found = NULL,
        },
        [kDyldPtrOpenat] = {
            .signature = 0xD4001001D28039F0ULL,
            .found = NULL,
        },
        
        /* rest is null by default */
    };
    searchDyldFunctions(dyldBase, entries, kDyldPtrOpenat + 1);
    
    /* now the shit that takes 20~30ms if not cached properly */
    const char *libdyldPath = "/usr/lib/system/libdyld.dylib";
    mach_header_u *libdyldHeader = LCGetLoadedImageHeader(0, libdyldPath);
    if(libdyldHeader == NULL)
    {
        klog_log("patchfinder:emit", "libdyld is not loaded");
        return KERN_FAILURE;
    }
    void **lockUnlockPtr = NULL;
    void **vtableLibSystemHelpers = litehook_find_dsc_symbol(libdyldPath, "__ZTVN5dyld416LibSystemHelpersE");
    void *lockFunc = litehook_find_dsc_symbol(libdyldPath, "__ZNK5dyld416LibSystemHelpers42os_unfair_recursive_lock_lock_with_optionsEP26os_unfair_recursive_lock_s24os_unfair_lock_options_t");
    if(vtableLibSystemHelpers == NULL || lockFunc == NULL)
    {
        klog_log("patchfinder:emit", "libdyld lock vtable is missing");
        return KERN_FAILURE;
    }
#if DEBUG
    void *unlockFunc = litehook_find_dsc_symbol(libdyldPath, "__ZNK5dyld416LibSystemHelpers31os_unfair_recursive_lock_unlockEP26os_unfair_recursive_lock_s");
#endif /* DEBUG */
    for(int slot = 0; slot < 512 && lockUnlockPtr == NULL; slot++)
    {
        if(vtableLibSystemHelpers[0] == lockFunc)
        {
            lockUnlockPtr = vtableLibSystemHelpers;
#if DEBUG
            NSCAssert(vtableLibSystemHelpers[1] == unlockFunc, @"dyld has changed: lock and unlock functions are not next to each other");
#endif /* DEBUG */
            break;
        }
        vtableLibSystemHelpers++;
    }
    if(lockUnlockPtr == NULL)
    {
        klog_log("patchfinder:emit", "lock function is not in the libdyld vtable");
        return KERN_FAILURE;
    }
    
    entries[kDyldLockUnlockFunc].found = lockUnlockPtr;
    
    /* now stuffing the hook data */
    typedef struct {
        const char *name;
        uint32_t adrpOffset;
    } dyld_hook_segment_t;
    
    static const dyld_hook_segment_t dyldNames[3] = {
        {
            .name = "_NSGetExecutablePath",
            .adrpOffset = 2,
        },
        {
            .name = "dyld_program_sdk_at_least",
            .adrpOffset = 1,
        },
        {
            .name = "dyld_get_program_sdk_version",
            .adrpOffset = 0,
        }
    };
    
    int offset = kDyldLockUnlockFunc;
    for(size_t i = 0; i < 3; i++)
    {
        uint32_t* baseAddr = dlsym(RTLD_DEFAULT, dyldNames[i].name);
        if(baseAddr == NULL)
        {
            break;
        }
        
        uint32_t* adrpInstPtr = baseAddr + dyldNames[i].adrpOffset;
        
        // find the following instruction pattern: 1 adrp + 2 ldr
        // adrp    x8, 0x1e6cf0000
        // ldr     x0, [x8, #0x30]  {dyld4::gAPIs}
        // ldr     x16, [x0]
        
        static long adrpExtraOffset = -1;
        if(adrpExtraOffset == -1)
        {
            // let't hope the function is not longer than 200 instructions
            uint32_t* end = baseAddr + 200;
            for(uint32_t* cur = adrpInstPtr;cur < end;++cur)
            {
                if((*cur & 0x9f000000) != 0x90000000)
                {
                    continue;
                }
                if((*(cur+1) & 0xFFC00000) != 0xF9400000)
                {
                    continue;
                }
                if((*(cur+2) & 0xFFC00000) != 0xF9400000)
                {
                    continue;
                }
                adrpExtraOffset = cur - adrpInstPtr;
                break;
            }
            if(adrpExtraOffset == -1)
            {
                klog_log("patchfinder:emit", "adrp/ldr pattern missing in %s", dyldNames[i].name);
                break;
            }
        }
        
        adrpInstPtr += adrpExtraOffset;
        
        void *dptr = (void*)aarch64_emulate_adrp_ldr(*adrpInstPtr, *(adrpInstPtr + 1), (uint64_t)adrpInstPtr);
        
        if(dptr == NULL || *(void**)dptr == NULL)
        {
            klog_log("patchfinder:emit", "dyld API pointer missing in %s", dyldNames[i].name);
            break;
        }
        void* vtablePtr = **(void***)dptr;
        
        void* vtableFunctionPtr = 0;
        uint32_t* movInstPtr = adrpInstPtr + 6;

        if((*movInstPtr & 0x7F800000) == 0x52800000)
        {
            // arm64e, mov imm + add + ldr
            uint32_t imm16 = (*movInstPtr & 0x1FFFE0) >> 5;
            vtableFunctionPtr = vtablePtr + imm16;
        }
        else if ((*movInstPtr & 0xFFE00C00) == 0xF8400C00)
        {
            // arm64e, ldr immediate Pre-index 64bit
            uint32_t imm9 = (*movInstPtr & 0x1FF000) >> 12;
            vtableFunctionPtr = vtablePtr + imm9;
        }
        else
        {
            // arm64
            uint32_t* ldrInstPtr2 = adrpInstPtr + 3;
            if((*ldrInstPtr2 & 0xBFC00000) != 0xB9400000)
            {
                klog_log("patchfinder:emit", "vtable load missing in %s", dyldNames[i].name);
                break;
            }
            uint32_t size2 = (*ldrInstPtr2 & 0xC0000000) >> 30;
            uint32_t imm12_2 = (*ldrInstPtr2 & 0x3FFC00) >> 10;
            vtableFunctionPtr = vtablePtr + (imm12_2 << size2);
        }
        
        entries[offset + 1].found = vtableFunctionPtr;
        
        offset++;
    }
    
    /* on iOS 17 it seems like there is no normal fcntl call */
    if(!@available(iOS 18.0, *))
    {
        if(entries[kDyldPtrFcntl].found == NULL)
        {
            entries[kDyldPtrFcntl].found = findDyldFcntl17(dyldBase);
        }
    }
    
    static const char *names[kDyldPtrCount] = {
        "dyld.open",
        "dyld.fcntl",
        "dyld.fstat64",
        "dyld.stat64",
        "dyld.openat",
        "dyld.lockUnlockFunc",
        
        "_NSGetExecutablePath.vtable.fn",
        "dyld_program_sdk_at_least.vtable.fn",
        "dyld_get_program_sdk_version.vtable.fn",
    };
    
    bool entryNotFound = false;
    for(size_t i = 0; i < kDyldPtrCount; i++)
    {
        if(entries[i].found == NULL)
        {
            entryNotFound = true;
        }
        
        out[i] = (uint64_t)(uintptr_t)entries[i].found;
        klog_log("patchfinder:emit", "%s @ %p", names[i], (void*)out[i]);
    }
    
    if(entryNotFound)
    {
        klog_log("patchfinder:emit", "couldn't find all pointers");
        return KERN_FAILURE;
    }
    
    return KERN_SUCCESS;
}

kern_return_t ksurface_patchcache_write(const char *path)
{
    if(path == NULL)
    {
        return KERN_INVALID_ARGUMENT;
    }
    
    uint64_t patches[kDyldPtrCount];
    kern_return_t kr = findDyldFunctionPointers(patches);
    if(kr != KERN_SUCCESS)
    {
        return kr;
    }
    
    NSData *data = [NSData dataWithBytes:patches length:sizeof(patches)];
    if(data == nil)
    {
        return KERN_RESOURCE_SHORTAGE;
    }
    
    NSError *error = nil;
    if(![data writeToFile:[NSString stringWithUTF8String:path] options:NSDataWritingAtomic error:&error])
    {
        klog_log("patchfinder:emit", "couldn't write dyld.ptrs: %@", error);
        return KERN_FAILURE;
    }
    
    return KERN_SUCCESS;
}

kern_return_t ksurface_patchcache_emit(void)
{
    NSURL *url = [NXBootstrap.shared.rootURL URLByAppendingPathComponent:@"mntfs/bootfs/patchfinder.bin"];
    if(url.path == nil)
    {
        return KERN_FAILURE;
    }
    return ksurface_patchcache_write(url.path.UTF8String);
}
