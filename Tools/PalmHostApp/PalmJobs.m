// SPDX-License-Identifier: AGPL-3.0-or-later

#import <MobileDevelopmentKit/MDKJob.h>

@interface MDKJob (PalmBinary)
+ (instancetype)jobWithType:(MDKJobType)type withArguments:(NSArray<NSString *> *)arguments;
@end

MDKJob *PalmLinkerJob(NSArray<NSString *> *arguments) {
    return [MDKJob jobWithType:MDKJobTypeLinker withArguments:arguments];
}
