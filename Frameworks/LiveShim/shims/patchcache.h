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

#ifndef LIVESHIM_PTRCACHE_H
#define LIVESHIM_PTRCACHE_H

#include <stdbool.h>
#include <stdint.h>

enum {
    /* for the RO file system sandbox mmap bypass */
    kDyldPtrOpen = 0,
    kDyldPtrFcntl,
    kDyldPtrFstat64,
    kDyldPtrStat64,
    kDyldPtrOpenat,
    
    /* for the dlopen with the lock bypasses */
    kDyldLockUnlockFunc,
    
    /* dyld hook ptrs */
    kDyldNSGetExecutablePathVTFN,
    kDyldProgramSDKAtLeastVTFN,
    kDyldGetProgramSDKVersionVTFN,
    
    kDyldPtrCount,
};

extern uint64_t patchcache[kDyldPtrCount];
extern int palm_patchcache_status;

bool ksurface_user_patchcache_load(void);

#endif /* LIVESHIM_PTRCACHE_H */
