#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSString *const QFOnboardingCompletedKey;
@interface QFLaunchPolicy : NSObject
+ (BOOL)shouldShowWelcomeForDebug:(BOOL)isDebug completed:(BOOL)completed;
@end
