/*
 SPDX-License-Identifier: AGPL-3.0-or-later

 Copyright (C) 2023 - 2026 LiveContainer
 Copyright (C) 2026 emexlab

 This file is part of LiveContainer.

 LiveContainer is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 LiveContainer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with Nyxian. If not, see <https://www.gnu.org/licenses/>.
*/

#import <LindChain/Private/FoundationPrivate.h>
#import <LindChain/ProcEnvironment/LiveContainer/LCMachOUtils.h>
#import <LindChain/ProcEnvironment/LiveContainer/utils.h>
#import <LindChain/ProcEnvironment/LiveContainer/Tweaks/DyldHook.h>

#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <objc/runtime.h>

#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <stdlib.h>
#include <unistd.h>
#include <LiveShim/patchcache.h>
#import <LindChain/ProcEnvironment/litehook/litehook.h>
#import <LindChain/ProcEnvironment/LiveContainer/Tweaks/Tweaks.h>
#include <mach-o/ldsyms.h>
#import <LindChain/Services/bootstrapd/LDEApplicationObject.h>
#import <LindChain/ProcEnvironment/Surface/surface.h>
#import <LindChain/ProcEnvironment/LiveContainer/LCBootstrap.h>
#import <malloc/malloc.h>
#import <LindChain/Utils/CFTools.h>
#import <LiveShim/LiveShimSyscall.h>
#include <ksurface_config.h>
#include <ksurface_abi.h>

#import <LindChain/ProcEnvironment/Utils/PEMachOUtils.h>

int hook__NSGetExecutablePath_overwriteExecPath(char*** dyldApiInstancePtr, char* newPath, uint32_t* bufsize)
{
    assert(dyldApiInstancePtr != 0);
    char** dyldConfig = dyldApiInstancePtr[1];
    assert(dyldConfig != 0);
    
    char** mainExecutablePathPtr = 0;
    // mainExecutablePath is at 0x10 for iOS 15~18.3.2, 0x20 for iOS 18.4+
    if(dyldConfig[2] != 0 && dyldConfig[2][0] == '/')
    {
        mainExecutablePathPtr = dyldConfig + 2;
    }
    else if(dyldConfig[4] != 0 && dyldConfig[4][0] == '/')
    {
        mainExecutablePathPtr = dyldConfig + 4;
    }
    else
    {
        assert(mainExecutablePathPtr != 0);
    }

    kern_return_t ret = builtin_vm_protect(mach_task_self(), (mach_vm_address_t)mainExecutablePathPtr, sizeof(mainExecutablePathPtr), false, PROT_READ | PROT_WRITE);
    if(ret != KERN_SUCCESS)
    {
        assert(os_tpro_is_supported());
        os_thread_self_restrict_tpro_to_rw();
    }
    /* MARK: setting a copy of the path as the new pointer (required cuz objc NSString UTF8String pointers are not safe and can become stale) */
    *mainExecutablePathPtr = strdup(newPath);
    if(ret != KERN_SUCCESS)
    {
        os_thread_self_restrict_tpro_to_ro();
    }

    return 0;
}

static void palm_guest_trace(const char *line)
{
    if(line == NULL)
    {
        return;
    }
    const char *root = getenv("NXROOT");
    if(root == NULL || root[0] == '\0')
    {
        return;
    }
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/boot/guest.txt", root);
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if(fd < 0)
    {
        return;
    }
    write(fd, line, strlen(line));
    write(fd, "\n", 1);
    close(fd);
}

void LCOverwriteExecutablePath(NSString *executablePath)
{
    /*
     * dyld4 stores executable path in a different place (iOS 15.0 +)
     * https://github.com/apple-oss-distributions/dyld/blob/ce1cc2088ef390df1c48a1648075bbd51c5bbc6a/dyld/DyldAPIs.cpp#L802
     *
     * The vtable hook needs boot/patchfinder.bin. Without that file the
     * real _NSGetExecutablePath runs, and a NULL size pointer is a crash.
     */
    int (*orig__NSGetExecutablePath)(void* dyldPtr, char* buf, uint32_t* bufsize) = NULL;
    bool hooked = performHookDyldApiFast(kDyldNSGetExecutablePathVTFN, (void**)&orig__NSGetExecutablePath, hook__NSGetExecutablePath_overwriteExecPath);
    char note[160];
    snprintf(note, sizeof(note), "overwrite hook=%d cache=%d", hooked, palm_patchcache_status);
    palm_guest_trace(note);
    if(hooked)
    {
        _NSGetExecutablePath((char*)[executablePath UTF8String], NULL);
        performHookDyldApiFast(kDyldNSGetExecutablePathVTFN, nil, orig__NSGetExecutablePath);
    }
    
    /* overwriting remaining upper systems */
    NSString *procName = [executablePath lastPathComponent];
    NSProcessInfo.processInfo.processName = procName;
    *_CFGetProgname() = strdup(procName.UTF8String);
    *_CFGetProcessPath() = strdup(executablePath.UTF8String);
    Class swiftNSProcessInfo = NSClassFromString(@"_NSSwiftProcessInfo");
    if(swiftNSProcessInfo)
    {
        /* swizzle the arguments method to return the ObjC arguments */
        SEL selector = @selector(arguments);
        method_setImplementation(class_getInstanceMethod(swiftNSProcessInfo, selector), class_getMethodImplementation(NSProcessInfo.class, selector));
    }
}

int LCBootstrapMain(NSString *executablePath,
                    int argc,
                    char *argv[])
{
    if(executablePath == nil)
    {
        return 1;
    }
    
    /* preload executable to bypass RT_NOLOAD */
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    
    int64_t ret = -1;
    char cdhash[USER_FSIGNATURES_CDHASH_LEN];
    static atomic_flag initialSpawnFlag = ATOMIC_FLAG_INIT;
    bool initialSpawn = atomic_flag_test_and_set(&initialSpawnFlag);
    if(!initialSpawn)
    {
        ret = liveshim_syscall(SYS_pectl, kPECTLCategoryCodeSigning, kPECTLCodeSigningGetCDHash, cdhash, NULL, MACH_PORT_NULL);
    }
    appMainImageIndex = _dyld_image_count();
    /* makes sure the binary gets loaded that is meant to have the ksurface capabilities */
    void *guestHandle = dlopenBypassingLockWithTrust(executablePath.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL | RTLD_FIRST | RTLD_NODELETE, ret != 0 ? NULL : cdhash);
    appExecutableHandle = guestHandle;
    if(!guestHandle || (uint64_t)guestHandle > 0xf00000000000)
    {
        const char *reason = dlerror();
        char note[2048];
        snprintf(note, sizeof(note), "dlopen failed cache=%d pectl=%lld %s", palm_patchcache_status, (long long)ret, reason ?: "no dlerror");
        palm_guest_trace(note);
        fprintf(stderr, "%s\n", reason ?: "dlopen failed");
        return 1;
    }
    palm_guest_trace("dlopen ok");
    
    /* find main */
    int (*guestMain)(int, char**, char **, const char *) = PEGetMachOEntryPointOfHeader(guestHandle)?: dlsym(guestHandle, "main");
    assert(guestHandle != NULL);
    
    /*
     * now we load the executable of the bundle, as it doesn't
     * matter anymore from now on what CF does we can safely
     * load it as it is loaded already and complete the safe
     * initilization of the bundle swap LCOverwriteExecutablePath
     * did. This is necessary cause of NSBundle's internal state,
     * it can also fix known issues with the old implementation
     * of Duy Tran. Not only the app cares about this bundle,
     * the frameworks the app uses do aswell.
     */
    CFBundleRef bundle = CFBundleGetMainBundle();
    if(CFBundleLoadExecutable(bundle))
    {
        CFBundleSetBinaryType(bundle, __CFBundleDYLDExecutableBinary);
    }
    
    /* now applying LC hooks */
    if(!initialSpawn)
    {
        NUDGuestHooksInit();
        NSFMGuestHooksInit();
        UIKitGuestHooksInit();
        initDead10ccFix();
        DyldHooksInit();
    }
    
    extern char **environ;
    return guestMain(argc, argv, environ, executablePath.fileSystemRepresentation);
}
