#import <MobileDevelopmentKit/MDKOSVersion.h>

@interface NXApplicationState : NSObject
@property (class, nonatomic, readonly) BOOL extensionLessMode;
@end

@interface NXOSVersion : NSObject
@property (class, nonatomic, readonly) NSArray *NXOSVersionSupportedBuildVersionsRaw;
@end
