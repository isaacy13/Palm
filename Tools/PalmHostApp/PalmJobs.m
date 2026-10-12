// SPDX-License-Identifier: AGPL-3.0-or-later

#import <MobileDevelopmentKit/MDKJob.h>
#import <MobileDevelopmentKit/MDKPhaseRunner.h>
#import <CoreCompiler/CCUtils.h>

@interface MDKJob (PalmBinary)
+ (instancetype)jobWithType:(MDKJobType)type withArguments:(NSArray<NSString *> *)arguments;
@end

MDKJob *PalmJob(MDKJobType type, NSArray<NSString *> *arguments, NSArray<NSURL *> *inputs, NSURL *output) {
    return [MDKJob jobWithType:type withArguments:arguments withInputFileURLs:inputs withOutputFileURL:output];
}

MDKJob *PalmLinkerJob(NSArray<NSString *> *arguments) {
    return PalmJob(MDKJobTypeLinker, arguments, @[], nil);
}

CFIndex PalmMaximumCompileThreads(void) {
    CFIndex cores = CCGetMaximumPerformanceCores();
    return cores < 1 ? 1 : cores;
}

@interface PalmJobDelegate : NSObject <MDKPhaseRunnerDelegate>
@property (nonatomic, copy) BOOL (^execute)(MDKJob *job);
@property (nonatomic) CFIndex threads;
@end

@implementation PalmJobDelegate
- (CFIndex)runner:(MDKPhaseRunner *)runner multithreadingThreadCountForPhase:(MDKPhase *)phase {
    return self.threads;
}

- (BOOL)runner:(MDKPhaseRunner *)runner
         phase:(MDKPhase *)phase
    executeJob:(MDKJob *)job
withOutDiagnostics:(NSArray<MDKDiagnostic *> *__autoreleasing *)diagnostics
withOutMainSource:(NSString *__autoreleasing *)mainSource {
    return self.execute(job);
}
@end

BOOL PalmRunJobs(NSArray<MDKJob *> *jobs, BOOL parallel, CFIndex threads, BOOL (^execute)(MDKJob *job)) {
    if (!parallel || jobs.count < 2) {
        for (MDKJob *job in jobs) {
            if (!execute(job)) {
                return NO;
            }
        }
        return YES;
    }
    MDKPhaseEngine *engine = [MDKPhaseEngine engineWithClangFlags:@[] withOtherLinkerFlags:@[]];
    MDKPhaseRunner *runner = [MDKPhaseRunner runnerWithEngine:engine];
    PalmJobDelegate *delegate = [PalmJobDelegate new];
    delegate.execute = execute;
    delegate.threads = threads < 1 ? 1 : threads;
    runner.delegate = delegate;
    MDKPhase *phase = [MDKPhase phaseWithJobs:jobs withJobType:MDKJobTypeCompiler withMultithreadingSupport:YES];
    return [runner runPhase:phase];
}
