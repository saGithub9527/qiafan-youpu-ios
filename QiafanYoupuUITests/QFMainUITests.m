#import <XCTest/XCTest.h>
@interface QFMainUITests : XCTestCase
@property (nonatomic, strong) XCUIApplication *app;
@end
@implementation QFMainUITests
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    self.app = [XCUIApplication new];
}
- (void)capture:(NSString *)name {
    XCTAttachment *attachment = [XCTAttachment attachmentWithScreenshot:self.app.screenshot];
    attachment.name = name;
    attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
}
- (void)openLoginWithReset:(BOOL)reset {
    self.app.launchArguments = reset ? @[ @"-QFSkipWelcome", @"-QFResetUIState", @"-QFStartTab", @"profile" ]
                                     : @[ @"-QFSkipWelcome", @"-QFStartTab", @"profile" ];
    [self.app launch];
    XCTAssertTrue([self.app.buttons[@"profile.login"] waitForExistenceWithTimeout:5]);
    [self.app.buttons[@"profile.login"] tap];
    XCTAssertTrue([self.app.buttons[@"login.quick"] waitForExistenceWithTimeout:5]);
}
- (void)testWelcomePagesConsentAndDebugRelaunch {
    self.app.launchArguments = @[ @"-QFResetUIState" ];
    [self.app launch];
    XCTAssertTrue([self.app.buttons[@"welcome.skip"] waitForExistenceWithTimeout:5]);
    [self capture:@"01-welcome"];
    XCTAssertFalse(self.app.buttons[@"welcome.enter"].hittable);
    XCUIElement *pager = self.app.scrollViews[@"welcome.pages"];
    for (NSInteger i = 0; i < 4; i++)
        [pager swipeLeft];
    XCTAssertTrue(self.app.buttons[@"welcome.enter"].hittable);
    [self capture:@"02-welcome-last"];
    [self.app.buttons[@"welcome.enter"] tap];
    XCTAssertTrue([self.app.buttons[@"notice.continue"] waitForExistenceWithTimeout:5]);
    XCTAssertFalse(self.app.buttons[@"notice.continue"].enabled);
    [self capture:@"03-safety-notice"];
    [self.app.buttons[@"notice.agreement"] tap];
    XCTAssertTrue(self.app.buttons[@"notice.continue"].enabled);
    [self.app.buttons[@"notice.continue"] tap];
    XCTAssertTrue([self.app.buttons[@"tab.recipe"] waitForExistenceWithTimeout:5]);
    [self.app terminate];
    self.app.launchArguments = @[];
    [self.app launch];
    XCTAssertTrue([self.app.buttons[@"welcome.skip"] waitForExistenceWithTimeout:5]);
}
- (void)testAllFourPrimaryTabs {
    self.app.launchArguments = @[ @"-QFSkipWelcome" ];
    [self.app launch];
    NSArray *tabs = @[ @"recipe", @"plan", @"ingredient", @"profile" ];
    for (NSString *tab in tabs) {
        XCUIElement *button = self.app.buttons[[@"tab." stringByAppendingString:tab]];
        XCTAssertTrue([button waitForExistenceWithTimeout:5]);
        [button tap];
        XCTAssertTrue(button.selected);
        [self capture:[@"tab-" stringByAppendingString:tab]];
    }
    XCTAssertTrue(self.app.buttons[@"profile.login"].exists);
    [self.app.buttons[@"profile.login"] tap];
    XCTAssertTrue([self.app.buttons[@"login.quick"] waitForExistenceWithTimeout:5]);
    [self capture:@"04-login"];
    [self.app.buttons[@"login.close"] tap];
    XCTAssertTrue([self.app.buttons[@"tab.profile"] waitForExistenceWithTimeout:5]);
}
- (void)testLoginConsentPersistsBothDirectionsAndDoesNotAuthenticate {
    [self openLoginWithReset:YES];
    XCTAssertEqualObjects(self.app.buttons[@"login.agreement"].value, @"未勾选");
    [self.app.buttons[@"login.quick"] tap];
    XCTAssertTrue([self.app.buttons[@"notice.continue"] waitForExistenceWithTimeout:5]);
    XCTAssertFalse(self.app.buttons[@"notice.continue"].enabled);
    [self.app.buttons[@"notice.agreement"] tap];
    [self.app.buttons[@"notice.decline"] tap];
    XCTAssertEqualObjects(self.app.buttons[@"login.agreement"].value, @"未勾选");
    [self.app.buttons[@"login.agreement"] tap];
    [self.app terminate];
    [self openLoginWithReset:NO];
    XCTAssertEqualObjects(self.app.buttons[@"login.agreement"].value, @"已勾选");
    [self.app.buttons[@"login.apple"] tap];
    XCTAssertTrue([self.app.alerts[@"登录暂未开放"] waitForExistenceWithTimeout:5]);
    [self.app.alerts.buttons[@"知道了"] tap];
    [self.app.buttons[@"login.agreement"] tap];
    [self.app terminate];
    [self openLoginWithReset:NO];
    XCTAssertEqualObjects(self.app.buttons[@"login.agreement"].value, @"未勾选");
}
@end
