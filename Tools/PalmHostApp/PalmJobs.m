// SPDX-License-Identifier: AGPL-3.0-or-later

#import <MobileDevelopmentKit/MDKJob.h>

@interface MDKJob (PalmBinary)
+ (instancetype)jobWithType:(MDKJobType)type withArguments:(NSArray<NSString *> *)arguments;
@end

MDKJob *PalmJob(MDKJobType type, NSArray<NSString *> *arguments, NSArray<NSURL *> *inputs, NSURL *output) {
    return [MDKJob jobWithType:type withArguments:arguments withInputFileURLs:inputs withOutputFileURL:output];
}

MDKJob *PalmLinkerJob(NSArray<NSString *> *arguments) {
    return PalmJob(MDKJobTypeLinker, arguments, @[], nil);
}
