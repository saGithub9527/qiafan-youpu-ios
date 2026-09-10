#import "QFSceneDelegate.h"
#import "QFRootViewController.h"
@implementation QFSceneDelegate
- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class])
        return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.window.rootViewController = [QFRootViewController new];
    [self.window makeKeyAndVisible];
}
@end
