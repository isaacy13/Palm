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

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#import <AVFoundation/AVFoundation.h>
#import <LindChain/ProcEnvironment/Shims/application.h>
#import <LindChain/ProcEnvironment/Shims/environment.h>
#import <LindChain/Utils/Swizzle.h>
#import <LindChain/ProcEnvironment/Shims/proxy.h>
#import <LindChain/ProcEnvironment/Surface/sys/syscall.h>
#import <LiveShim/LiveShimSyscall.h>
#include <ksurface_config.h>
#include <ksurface_abi.h>

#pragma mark - Initilizer

static dispatch_source_t global_signal_source = nil;


int palm_guest_ui_ready = 0;

@implementation UIApplication (ProcEnvironment)

- (void)hook_run
{
    palm_guest_ui_ready = 1;
    /* tell host app to let our process appear as a window */
    const char *root = getenv("NXROOT");
    if (root != NULL && root[0] != '\0') {
        char path[1024];
        char note[64];
        snprintf(path, sizeof(path), "%s/boot/guest.txt", root);
        int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            snprintf(note, sizeof(note), "hook_run\n");
            write(fd, note, strlen(note));
            close(fd);
        }
    }
    liveshim_syscall(SYS_pectl, kPECTLCategoryUserInterface, kPECTLUserInterfaceInit, 0, 0, MACH_PORT_NULL, NULL);
    
    while(errno == EAGAIN)
    {
        usleep(500);
        liveshim_syscall(SYS_pectl, kPECTLCategoryUserInterface, kPECTLUserInterfaceInit, 0, 0, MACH_PORT_NULL, NULL);
    }
    if (root != NULL && root[0] != '\0') {
        char path[1024];
        char note[64];
        snprintf(path, sizeof(path), "%s/boot/guest.txt", root);
        int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            snprintf(note, sizeof(note), "hook_run errno %d\n", errno);
            write(fd, note, strlen(note));
            close(fd);
        }
    }
    
    [self hook_run];
}

@end

void environment_application_init(void)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    SwizzleObjCMethod(@selector(_run), [UIApplication class], @selector(hook_run), nil, kSwizzleMethodTypeInstance);
#pragma clang diagnostic pop
    
    signal(SIGUSR1, SIG_IGN);
    global_signal_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
    if(global_signal_source)
    {
        dispatch_source_set_event_handler(global_signal_source, ^{
            UIApplication *sharedApplication = [PrivClass(UIApplication) sharedApplication];
            
            if(sharedApplication)
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    // TODO: Shall be done by the runLoop and not by the handler, this could lead to some strange behaviour
                    
                    /* finding active scene */
                    UIWindowScene *activeScene = nil;
                    for(UIWindowScene *scene in sharedApplication.connectedScenes)
                    {
                        if(scene.activationState == UISceneActivationStateForegroundActive)
                        {
                            activeScene = scene;
                            break;
                        }
                    }
                    
                    /* null pointer check */
                    if(!activeScene)
                    {
                        return;
                    }
                    
                    /* getting view we wanna capture with our own eyes ^^ */
                    UIWindow *rootWindow = activeScene.keyWindow;
                    UIViewController *topVC = rootWindow.rootViewController;
                    UIView *viewToCapture = topVC.view ?: rootWindow;
                    
                    /* preparing format for renderer */
                    CGFloat scale = [UIScreen mainScreen].scale;
                    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
                    format.scale = scale;
                    format.opaque = viewToCapture.isOpaque;
                    
                    /* creating renderer */
                    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:viewToCapture.bounds.size format:format];
                    
                    /* and snapshotting... */
                    UIImage *snapshot = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull rendererContext) {
                        /* crafting screenshot */
                        [viewToCapture drawViewHierarchyInRect:viewToCapture.bounds afterScreenUpdates:YES];
                    }];
                    
                    /* sending to host */
                    environment_proxy_set_snapshot(snapshot);
                });
                return;
            }
        });
        
        dispatch_resume(global_signal_source);
    }
}
