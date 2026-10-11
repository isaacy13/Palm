#import "PalmHostStubs.h"

@interface ZSigner : NSObject
@end

@implementation ZSigner
@end

@implementation NXApplicationState

+ (BOOL)extensionLessMode
{
    return NO;
}

@end

@implementation NXOSVersion

+ (NSArray *)NXOSVersionSupportedBuildVersionsRaw
{
    MDKOSVersion *minimum = [[MDKOSVersion alloc] initWithVersionString:@"18.0"];
    MDKOSVersion *maximum = [[MDKOSVersion alloc] initWithVersionString:@"26.5"];
    NSMutableArray *versions = [NSMutableArray array];
    if (minimum != nil) {
        [versions addObject:minimum];
    }
    if (maximum != nil) {
        [versions addObject:maximum];
    }
    return versions;
}

@end
