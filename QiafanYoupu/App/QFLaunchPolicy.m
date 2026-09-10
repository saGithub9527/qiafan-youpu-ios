#import "QFLaunchPolicy.h"
NSString *const QFOnboardingCompletedKey = @"qfyp.onboarding.completed";
@implementation QFLaunchPolicy
+ (BOOL)shouldShowWelcomeForDebug:(BOOL)isDebug completed:(BOOL)completed {
    return isDebug || !completed;
}
@end
