// SPDX-License-Identifier: AGPL-3.0-or-later

#import <LindChain/PalmHost/PalmLaunch.h>
#import <LindChain/ProcEnvironment/Surface/surface.h>
#import <LindChain/ProcEnvironment/Surface/trust/signing.h>
#import <LindChain/ProcEnvironment/Surface/trust/trust.h>
#import <LindChain/ProcEnvironment/Utils/vnode.h>
#import <LindChain/ProcEnvironment/PEExtension.h>
#import <LindChain/ProcEnvironment/PEProcessManager.h>
#import <LindChain/WindowServer/NXWindowServer.h>
#import <LindChain/WindowServer/Session/NXWindowSessionApplication.h>
#import <LindChain/ProcEnvironment/Surface/cache/patchcache.h>
#import <LindChain/ProcEnvironment/LiveContainer/LCMachOUtils.h>
#include <errno.h>
#import <objc/runtime.h>
#include <CommonCrypto/CommonDigest.h>
#include <libkern/OSByteOrder.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/fcntl.h>

char palm_spawn_step[240] = "unset";
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

static id PalmShared(NSString *className) {
    Class cls = NSClassFromString(className);
    if (cls == Nil) {
        return nil;
    }
    SEL shared = NSSelectorFromString(@"shared");
    if (![cls respondsToSelector:shared]) {
        return nil;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id instance = [cls performSelector:shared];
#pragma clang diagnostic pop
    return instance;
}

static BOOL PalmInvokeBool(id target, NSString *selectorName, NSString *argument) {
    if (target == nil) {
        return NO;
    }
    SEL selector = NSSelectorFromString(selectorName);
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (signature == nil) {
        return NO;
    }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    [invocation setArgument:&argument atIndex:2];
    [invocation invoke];
    BOOL result = NO;
    if (signature.methodReturnLength == sizeof(BOOL)) {
        [invocation getReturnValue:&result];
    }
    return result;
}

static void PalmIgnoreExtensionLifecycle(id self, SEL _cmd, id note) {
    (void)self;
    (void)_cmd;
    (void)note;
}

static void PalmAppendTrace(NSString *note) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/window-trace.txt"];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    NSData *data = [[note stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (handle == nil) {
        [note writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
}

static void PalmStopBlockingOnExtension(void) {
    Class cls = NSClassFromString(@"EXConcreteExtension");
    if (cls == Nil) {
        PalmAppendTrace(@"extension lifecycle class missing");
        return;
    }
    int replaced = 0;
    for (NSString *name in @[
        @"_hostWillResignActiveNote:",
        @"_hostDidEnterBackgroundNote:",
        @"_hostWillEnterForegroundNote:",
        @"_hostDidBecomeActiveNote:",
    ]) {
        Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
        if (method != NULL) {
            method_setImplementation(method, (IMP)PalmIgnoreExtensionLifecycle);
            replaced++;
        }
    }
    PalmAppendTrace([NSString stringWithFormat:@"extension lifecycle replaced %d", replaced]);
}

void PalmBootSurface(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (ksurface == NULL) {
            ksurface_kinit();
        }
    });
    PalmStopBlockingOnExtension();
}

static uint32_t PalmBE32(uint32_t value) {
    return OSSwapHostToBigInt32(value);
}

static uint64_t PalmBE64(uint64_t value) {
    return OSSwapHostToBigInt64(value);
}

static void PalmStore32(uint8_t *cursor, uint32_t value) {
    uint32_t stored = PalmBE32(value);
    memcpy(cursor, &stored, sizeof(stored));
}

static void PalmStore64(uint8_t *cursor, uint64_t value) {
    uint64_t stored = PalmBE64(value);
    memcpy(cursor, &stored, sizeof(stored));
}

/*
 * LCPatchExecSlice rewrites the header after ld64.lld has signed it.
 * dyld then reports that the signature covers 0 bytes. Write a new
 * adhoc code directory whose codeLimit is the signature offset.
 */
static bool PalmAdhocSign(const char *path) {
    int fd = open(path, O_RDWR);
    if(fd < 0) {
        return false;
    }
    struct mach_header_64 header;
    if(read(fd, &header, sizeof(header)) != (ssize_t)sizeof(header) || header.magic != MH_MAGIC_64) {
        close(fd);
        return false;
    }
    uint32_t commandsSize = header.sizeofcmds;
    uint8_t *commands = malloc(commandsSize);
    if(commands == NULL || read(fd, commands, commandsSize) != (ssize_t)commandsSize) {
        free(commands);
        close(fd);
        return false;
    }
    struct linkedit_data_command *signature = NULL;
    uint32_t offset = 0;
    for(uint32_t index = 0; index < header.ncmds; index++) {
        struct load_command *command = (struct load_command *)(commands + offset);
        if(command->cmd == LC_CODE_SIGNATURE && command->cmdsize >= sizeof(*signature)) {
            signature = (struct linkedit_data_command *)command;
            break;
        }
        if(command->cmdsize < sizeof(*command) || offset + command->cmdsize > commandsSize) {
            break;
        }
        offset += command->cmdsize;
    }
    if(signature == NULL || signature->dataoff == 0) {
        free(commands);
        close(fd);
        return false;
    }
    uint32_t codeLimit = signature->dataoff;
    const uint32_t pageSize = 4096;
    uint32_t slotCount = (codeLimit + pageSize - 1) / pageSize;
    const char *identity = "PalmGuest";
    uint32_t identityLength = (uint32_t)strlen(identity) + 1;
    const uint32_t directoryFixed = 88;
    uint32_t hashOffset = directoryFixed + identityLength;
    uint32_t directoryLength = hashOffset + slotCount * CC_SHA256_DIGEST_LENGTH;
    uint32_t blobLength = 20 + directoryLength;
    uint8_t *blob = calloc(1, blobLength);
    uint8_t *page = calloc(1, pageSize);
    if(blob == NULL || page == NULL) {
        free(blob);
        free(page);
        free(commands);
        close(fd);
        return false;
    }
    PalmStore32(blob + 0, 0xfade0cc0);
    PalmStore32(blob + 4, blobLength);
    PalmStore32(blob + 8, 1);
    PalmStore32(blob + 12, 0);
    PalmStore32(blob + 16, 20);
    uint8_t *directory = blob + 20;
    PalmStore32(directory + 0, 0xfade0c02);
    PalmStore32(directory + 4, directoryLength);
    PalmStore32(directory + 8, 0x20400);
    PalmStore32(directory + 12, 0x00020002);
    PalmStore32(directory + 16, hashOffset);
    PalmStore32(directory + 20, directoryFixed);
    PalmStore32(directory + 24, 0);
    PalmStore32(directory + 28, slotCount);
    PalmStore32(directory + 32, codeLimit);
    directory[36] = CC_SHA256_DIGEST_LENGTH;
    directory[37] = 2;
    directory[38] = 0;
    directory[39] = 12;
    PalmStore64(directory + 56, codeLimit);
    PalmStore64(directory + 72, codeLimit);
    memcpy(directory + directoryFixed, identity, identityLength);
    signature->datasize = blobLength;
    if(pwrite(fd, commands, commandsSize, sizeof(header)) != (ssize_t)commandsSize || ftruncate(fd, codeLimit) != 0 || lseek(fd, 0, SEEK_SET) < 0) {
        free(blob);
        free(page);
        free(commands);
        close(fd);
        return false;
    }
    uint32_t remaining = codeLimit;
    uint8_t *hashes = directory + hashOffset;
    for(uint32_t slot = 0; slot < slotCount; slot++) {
        uint32_t chunk = remaining > pageSize ? pageSize : remaining;
        memset(page, 0, pageSize);
        if(read(fd, page, chunk) != (ssize_t)chunk) {
            free(blob);
            free(page);
            free(commands);
            close(fd);
            return false;
        }
        CC_SHA256(page, pageSize, hashes + slot * CC_SHA256_DIGEST_LENGTH);
        remaining -= chunk;
    }
    if(pwrite(fd, blob, blobLength, codeLimit) != (ssize_t)blobLength) {
        free(blob);
        free(page);
        free(commands);
        close(fd);
        return false;
    }
    fsignatures_t info;
    memset(&info, 0, sizeof(info));
    info.fs_file_start = 0;
    info.fs_blob_start = (void *)(uintptr_t)codeLimit;
    info.fs_blob_size = blobLength;
    int check = fcntl(fd, F_ADDFILESIGS_RETURN, &info);
    int checkError = errno;
    char result[80];
    snprintf(result, sizeof(result), "host fcntl %d errno %d\n", check, checkError);
    int noteFd = open([NSHomeDirectory() stringByAppendingPathComponent:@"Documents/sigcheck.txt"].UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if(noteFd >= 0) {
        write(noteFd, result, strlen(result));
        close(noteFd);
    }
    free(blob);
    free(page);
    free(commands);
    close(fd);
    return true;
}

bool PalmPatchExecutableForDlopen(const char *path) {
    LCMachO *machO = LCMapMachO(path, false);
    if(machO == NULL) {
        return false;
    }
    bool patched = LCPatchExecSlice(machO);
    LCUnmapMachO(machO);
    return patched;
}

static void PalmCheckSignatureFile(const char *path, int noteFd) {
    int fd = open(path, O_RDONLY);
    if(fd < 0) {
        dprintf(noteFd, "%s open %d\n", path, errno);
        return;
    }
    struct mach_header_64 header;
    if(read(fd, &header, sizeof(header)) != (ssize_t)sizeof(header)) {
        dprintf(noteFd, "%s header\n", path);
        close(fd);
        return;
    }
    uint8_t *commands = malloc(header.sizeofcmds);
    if(commands == NULL || read(fd, commands, header.sizeofcmds) != (ssize_t)header.sizeofcmds) {
        dprintf(noteFd, "%s cmds\n", path);
        free(commands);
        close(fd);
        return;
    }
    uint32_t offset = 0;
    struct linkedit_data_command *signature = NULL;
    for(uint32_t index = 0; index < header.ncmds; index++) {
        struct load_command *command = (struct load_command *)(commands + offset);
        if(command->cmd == LC_CODE_SIGNATURE) {
            signature = (struct linkedit_data_command *)command;
            break;
        }
        offset += command->cmdsize;
    }
    if(signature == NULL) {
        dprintf(noteFd, "%s no signature\n", path);
        free(commands);
        close(fd);
        return;
    }
    fsignatures_t info;
    memset(&info, 0, sizeof(info));
    info.fs_file_start = 0;
    info.fs_blob_start = (void *)(uintptr_t)signature->dataoff;
    info.fs_blob_size = signature->datasize;
    int check = fcntl(fd, F_ADDFILESIGS_RETURN, &info);
    dprintf(noteFd, "%s fcntl %d errno %d\n", path, check, errno);
    free(commands);
    close(fd);
}

pid_t PalmLaunchBundle(NSString *bundleIdentifier, NSString *bundlePath, NSString * __autoreleasing *errorOut) {
    PalmBootSurface();
    int noteFd = open([NSHomeDirectory() stringByAppendingPathComponent:@"Documents/sigcheck.txt"].UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if(noteFd >= 0) {
        PalmCheckSignatureFile([NSHomeDirectory() stringByAppendingPathComponent:@"Documents/probe.dylib"].UTF8String, noteFd);
        PalmCheckSignatureFile([NSHomeDirectory() stringByAppendingPathComponent:@"Documents/probe-team.dylib"].UTF8String, noteFd);
        close(noteFd);
    }

    id workspace = PalmShared(@"LDEApplicationWorkspace");
    if (workspace != nil && bundlePath.length > 0) {
        PalmInvokeBool(workspace, @"installApplicationAtBundlePath:", bundlePath);
    }

    id manager = PalmShared(@"PEProcessManager");
    if (manager == nil) {
        if (errorOut) {
            *errorOut = @"PEProcessManager is not loaded in this process";
        }
        return -1;
    }

    NSString *boot = [bundlePath stringByAppendingPathComponent:@"boot"];
    [[NSFileManager defaultManager] createDirectoryAtPath:boot withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *cachePath = [boot stringByAppendingPathComponent:@"patchfinder.bin"];
    kern_return_t emitted = ksurface_patchcache_write(cachePath.UTF8String);
    NSString *note = [NSString stringWithFormat:@"patchfinder %d %@\n", emitted, cachePath];
    [note writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/patchfinder.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *name = bundlePath.lastPathComponent.stringByDeletingPathExtension;
    NSString *executable = [bundlePath stringByAppendingPathComponent:name];
    NSMutableDictionary *items = [@{
        @"PEExecutablePath": executable,
        @"PEArguments": @[executable],
        @"PEEnvironment": @{
            @"HOME": bundlePath,
            @"CFFIXED_USER_HOME": bundlePath,
            @"TMPDIR": [bundlePath stringByAppendingPathComponent:@"tmp"],
            @"NXROOT": bundlePath,
        },
        @"PEWorkingDirectory": bundlePath,
    } mutableCopy];
    if (bundleIdentifier.length > 0) {
        items[@"PEBundleIdentifier"] = bundleIdentifier;
    }

    SEL selector = NSSelectorFromString(@"spawnProcessWithItems:withKernelSurfaceProcess:");
    NSMethodSignature *signature = [manager methodSignatureForSelector:selector];
    if (signature == nil) {
        if (errorOut) {
            *errorOut = @"spawn selector is missing";
        }
        return -1;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = manager;
    invocation.selector = selector;
    void *proc = NULL;
    [invocation setArgument:&items atIndex:2];
    [invocation setArgument:&proc atIndex:3];
    [invocation invoke];

    pid_t pid = -1;
    [invocation getReturnValue:&pid];
    if (pid <= 0 && errorOut) {
        const char *path = executable.UTF8String;
        int accessResult = access(path, R_OK);
        int accessError = errno;
        int file = open(path, O_RDONLY);
        int openError = errno;
        ksurface_nxt2_t blob;
        memset(&blob, 0, sizeof(blob));
        kern_return_t blobStatus = file >= 0 ? trust_nxt2_read_fd(file, &blob) : KERN_FAILURE;
        if (file >= 0) {
            close(file);
        }
        int clone = vnode_inaccessible_open(path, O_RDWR);
        int cloneError = errno;
        if (clone >= 0) {
            close(clone);
        }
        errno = 0;
        ksurface_trust_identity_t *identity = trust_identity_create_from_path(path);
        int trustError = errno;
        NSBundle *plugin = PEGetLiveProcessBundle();
        NSExtension *extension = PEGetNSExtension();
        *errorOut = [NSString stringWithFormat:@"spawn returned no process step=%s access=%d/%d open=%d nxt2=%d signed=%d valid=%d cdhash=%d vnode=%d/%d trust=%p/%d plugin=%@ ext=%@ surface=%p",
                     palm_spawn_step, accessResult, accessError, openError, blobStatus, blob.isSigned, blob.isValid, blob.isCdHashValid,
                     clone, cloneError, identity, trustError,
                     plugin.bundleIdentifier ?: @"missing",
                     extension ? @"loaded" : @"missing",
                     ksurface];
        if (blob.entitlements) {
            CFRelease(blob.entitlements);
        }
    }
    if (pid > 0) {
        NSString *bundle = [bundleIdentifier copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            NXWindowServer *server = [NXWindowServer shared];
            PEProcess *process = [[PEProcessManager shared] processForProcessIdentifier:pid];
            if (process.bundleIdentifier.length == 0 && bundle.length > 0) {
                process.bundleIdentifier = bundle;
            }
            NSString *note = [NSString stringWithFormat:@"host present pid %d server %@ process %@ bundle %@\n",
                              pid, server, process, process.bundleIdentifier ?: bundle];
            NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/window-trace.txt"];
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            if (handle == nil) {
                [note writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            } else {
                [handle seekToEndOfFile];
                [handle writeData:[note dataUsingEncoding:NSUTF8StringEncoding]];
                [handle closeFile];
            }
            PalmStopBlockingOnExtension();
        });
    }
    return pid;
}
