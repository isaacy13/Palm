// SPDX-License-Identifier: AGPL-3.0-or-later

#ifndef PALMLAUNCH_H
#define PALMLAUNCH_H

#import <Foundation/Foundation.h>

void PalmBootSurface(void);
bool PalmPatchExecutableForDlopen(const char *path);
pid_t PalmLaunchBundle(NSString *bundleIdentifier, NSString *bundlePath, NSString * __autoreleasing *errorOut);

#endif
