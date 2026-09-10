#import <XCTest/XCTest.h>

@interface QFReleaseWelcomeUITests : XCTestCase
@end

@implementation QFReleaseWelcomeUITests
- (void)testFirstLaunchThenPersistedCompletion {
#if DEBUG
    XCTSkip(@"此用例需使用 Release 构建，测试前卸载模拟器中的本 App。");
#else
    self.continueAfterFailure = NO;
    XCUIApplication *app = [XCUIApplication new];
    // Release 必须忽略这些调试参数，避免意外绕过首次引导。
    app.launchArguments = @[ @"-QFSkipWelcome", @"-QFPreviewSignedIn" ];
    [app launch];
    XCTAssertTrue([app.buttons[@"welcome.skip"] waitForExistenceWithTimeout:5]);
    [app.buttons[@"welcome.skip"] tap];
    XCTAssertTrue([app.buttons[@"notice.continue"] waitForExistenceWithTimeout:5]);
    XCTAssertFalse(app.buttons[@"notice.continue"].enabled);
    [app.buttons[@"notice.agreement"] tap];
    [app.buttons[@"notice.continue"] tap];
    XCTAssertTrue([app.buttons[@"tab.recipe"] waitForExistenceWithTimeout:5]);
    [app terminate];
    app.launchArguments = @[ @"-QFResetUIState" ];
    [app launch];
    XCTAssertTrue([app.buttons[@"tab.recipe"] waitForExistenceWithTimeout:5]);
    XCTAssertFalse(app.buttons[@"welcome.skip"].exists);
    [app.buttons[@"tab.profile"] tap];
    XCTAssertTrue(app.buttons[@"profile.login"].exists);
#endif
}
@end
