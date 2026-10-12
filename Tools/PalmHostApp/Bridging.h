#import <Foundation/Foundation.h>
#import <MobileDevelopmentKit/MDKJob.h>
#import <mach/kern_return.h>
#import <LindChain/PalmHost/PalmLaunch.h>
#import <LindChain/WindowServer/NXWindowServer.h>

void PalmBootSurface(void);

kern_return_t trust_nxt2_sign(const char *path, CFDictionaryRef entitlements, bool signBlob, const char *priv_der_path);

MDKJob *PalmLinkerJob(NSArray<NSString *> *arguments);
MDKJob *PalmJob(MDKJobType type, NSArray<NSString *> *arguments, NSArray<NSURL *> *inputs, NSURL *output);
CFIndex PalmMaximumCompileThreads(void);
BOOL PalmRunJobs(NSArray<MDKJob *> *jobs, BOOL parallel, CFIndex threads, BOOL (^execute)(MDKJob *job));
