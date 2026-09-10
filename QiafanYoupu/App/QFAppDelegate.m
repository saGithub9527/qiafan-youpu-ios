#import "QFAppDelegate.h"
#import "QFSceneDelegate.h"
@implementation QFAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)session
                                   options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Default"
                                                                         sessionRole:session.role];
    configuration.delegateClass = QFSceneDelegate.class;
    return configuration;
}
@end
