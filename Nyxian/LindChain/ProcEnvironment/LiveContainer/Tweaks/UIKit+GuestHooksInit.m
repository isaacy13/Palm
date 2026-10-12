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

#import <UIKit/UIKit.h>
#import "../LCUtils.h"
#import "UIKitPrivate.h"
#import "utils.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import <LindChain/Utils/Swizzle.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// Handler for AppDelegate
@implementation UIApplication(LiveContainerHook)

- (void)hook__connectUISceneFromFBSScene:(id)scene transitionContext:(UIApplicationSceneTransitionContext*)context
{
#if !TARGET_OS_MACCATALYST
    context.payload = nil;
    context.actions = nil;
#endif
    [self hook__connectUISceneFromFBSScene:scene transitionContext:context];
}

+ (BOOL)_wantsApplicationBehaviorAsExtension
{
    // Fix LiveProcess: Make _UIApplicationWantsExtensionBehavior return NO so delegate code runs in the run loop
    return YES;
}

- (CGRect)hook_statusBarFrame
{
    UIStatusBarManager* manager = [(UIWindowScene*)(UIApplication.sharedApplication.connectedScenes.anyObject) statusBarManager];
    if(manager)
    {
        return manager.statusBarFrame;
    }
    else
    {
        return [self hook_statusBarFrame];
    }
}

- (void)hook_setDelegate:(id<UIApplicationDelegate>)delegate
{
    if(![delegate respondsToSelector:@selector(application:configurationForConnectingSceneSession:options:)])
    {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
        // Fix old apps black screen when UIApplicationSupportsMultipleScenes is YES
        SwizzleObjCMethod(@selector(makeKeyAndVisible), [UIWindow class], @selector(hook_makeKeyAndVisible), nil, kSwizzleMethodTypeInstance);
        SwizzleObjCMethod(@selector(makeKeyWindow), [UIWindow class], @selector(hook_makeKeyWindow), nil, kSwizzleMethodTypeInstance);
        SwizzleObjCMethod(@selector(setHidden:), [UIWindow class], @selector(hook_setHidden:), nil, kSwizzleMethodTypeInstance);
        SwizzleObjCMethod(@selector(statusBarFrame), [UIApplication class], @selector(hook_statusBarFrame), nil, kSwizzleMethodTypeInstance);
#pragma clang diagnostic pop
    }
    [self hook_setDelegate:delegate];
}

@end

@interface UIViewController ()

- (UIInterfaceOrientationMask)__supportedInterfaceOrientations;

@end

@implementation UIViewController (LiveContainerHook)

- (UIInterfaceOrientationMask)hook___supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskAll;
}

- (BOOL)hook_shouldAutorotateToInterfaceOrientation:(NSInteger)orientation
{
    return YES;
}

@end

@implementation UIWindow (LiveContainerHook)

- (void)hook_setAutorotates:(BOOL)autorotates forceUpdateInterfaceOrientation:(BOOL)force
{
    [self hook_setAutorotates:YES forceUpdateInterfaceOrientation:YES];
}

- (void)hook_makeKeyAndVisible
{
    [self updateWindowScene];
    [self hook_makeKeyAndVisible];
}

- (void)hook_makeKeyWindow
{
    [self updateWindowScene];
    [self hook_makeKeyWindow];
}

- (void)hook_resignKeyWindow
{
    [self updateWindowScene];
    [self hook_resignKeyWindow];
}

- (void)hook_setHidden:(BOOL)hidden
{
    [self updateWindowScene];
    [self hook_setHidden:hidden];
}

- (void)updateWindowScene
{
    for(UIWindowScene *windowScene in [PrivClass(UIApplication) sharedApplication].connectedScenes)
    {
        if(!self.windowScene && self.screen == windowScene.screen)
        {
            self.windowScene = windowScene;
            break;
        }
    }
}

@end

@implementation NSObject (PalmLocalStore)

- (void)palm_ignoreCloudKitContainerOptions:(id)options
{
}

+ (id)palm_containerWithIdentifier:(NSString *)identifier
{
    /*
     CKContainer's real initializer traps when the process has no iCloud
     entitlement. GuideAI only needs accountStatus(), which then stays unavailable.
     */
    (void)identifier;
    id container = [self alloc];
    CFRetain((__bridge CFTypeRef)container);
    return container;
}

- (void)palm_accountStatusWithCompletionHandler:(void (^)(NSInteger status, NSError *error))handler
{
    if (handler != nil) {
        handler(3, nil);
    }
}

- (void)palm_loadLocalStores:(void (^)(id description, NSError *error))block
{
    /*
     GuideAI waits on this completion before UIApplication starts the run loop.
     The stock loader hops to the main queue, so that wait never returns.
     Add the local store and finish the completion on this thread.
     */
    id description = nil;
    @try {
        NSArray *descriptions = [self valueForKey:@"persistentStoreDescriptions"];
        description = descriptions.firstObject;
        id coordinator = [self valueForKey:@"persistentStoreCoordinator"];
        NSURL *url = [description valueForKey:@"URL"];
        SEL add = @selector(addPersistentStoreWithType:configuration:URL:options:error:);
        if (coordinator != nil && url != nil && [coordinator respondsToSelector:add]) {
            NSError *error = nil;
            NSDictionary *options = @{
                @"NSMigratePersistentStoresAutomaticallyOption": @YES,
                @"NSInferMappingModelAutomaticallyOption": @YES,
            };
            ((id (*)(id, SEL, id, id, id, id, NSError **))objc_msgSend)(
                coordinator, add, @"SQLite", nil, url, options, &error);
        }
    } @catch (NSException *exception) {
        (void)exception;
    }
    if (block != nil) {
        block(description, nil);
    }
}

- (NSArray *)palm_executeFetchRequest:(id)request error:(NSError **)error
{
    @try {
        return [self palm_executeFetchRequest:request error:error];
    } @catch (NSException *exception) {
        NSString *note = [NSString stringWithFormat:@"fetch exception %@ %@\n", exception.name, exception.reason];
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"boot/fetch-exception.txt"];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle == nil) {
            [note writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [handle seekToEndOfFile];
            [handle writeData:[note dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
        if (error != NULL) {
            *error = [NSError errorWithDomain:exception.name ?: @"PalmFetch" code:1 userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: @""
            }];
        }
        return @[];
    }
}

@end

void UIKitGuestHooksInit(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
        SwizzleObjCMethod(@selector(_connectUISceneFromFBSScene:transitionContext:), [UIApplication class], @selector(hook__connectUISceneFromFBSScene:transitionContext:), nil, kSwizzleMethodTypeInstance);
#pragma clang diagnostic pop
        SwizzleObjCMethod(@selector(__supportedInterfaceOrientations), [UIViewController class], @selector(hook___supportedInterfaceOrientations), nil, kSwizzleMethodTypeInstance);
        SwizzleObjCMethod(@selector(shouldAutorotateToInterfaceOrientation:), [UIViewController class], @selector(hook_shouldAutorotateToInterfaceOrientation:), nil, kSwizzleMethodTypeInstance);
        SwizzleObjCMethod(@selector(setAutorotates:forceUpdateInterfaceOrientation:), [UIWindow class], @selector(hook_setAutorotates:forceUpdateInterfaceOrientation:), nil, kSwizzleMethodTypeInstance);
        SwizzleObjCMethod(@selector(setDelegate:), [UIApplication class], @selector(hook_setDelegate:), nil, kSwizzleMethodTypeInstance);
        Class storeDescription = NSClassFromString(@"NSPersistentStoreDescription");
        if (storeDescription) {
            SwizzleObjCMethod(@selector(setCloudKitContainerOptions:), storeDescription, @selector(palm_ignoreCloudKitContainerOptions:), [NSObject class], kSwizzleMethodTypeInstance);
        }
        Class cloudContainer = NSClassFromString(@"NSPersistentCloudKitContainer");
        if (cloudContainer) {
            SwizzleObjCMethod(@selector(loadPersistentStoresWithCompletionHandler:), cloudContainer, @selector(palm_loadLocalStores:), [NSObject class], kSwizzleMethodTypeInstance);
        }
        Class context = NSClassFromString(@"NSManagedObjectContext");
        if (context) {
            SwizzleObjCMethod(@selector(executeFetchRequest:error:), context, @selector(palm_executeFetchRequest:error:), [NSObject class], kSwizzleMethodTypeInstance);
        }
        dlopen("/System/Library/Frameworks/CloudKit.framework/CloudKit", RTLD_LAZY);
        Class ckContainer = NSClassFromString(@"CKContainer");
        if (ckContainer) {
            SwizzleObjCMethod(@selector(containerWithIdentifier:), ckContainer, @selector(palm_containerWithIdentifier:), [NSObject class], kSwizzleMethodTypeClass);
            SwizzleObjCMethod(@selector(accountStatusWithCompletionHandler:), ckContainer, @selector(palm_accountStatusWithCompletionHandler:), [NSObject class], kSwizzleMethodTypeInstance);
        }
    });
}
