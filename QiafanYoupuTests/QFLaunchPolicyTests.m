#import "QFLaunchPolicy.h"
#import <XCTest/XCTest.h>
@interface QFLaunchPolicyTests : XCTestCase
@end
@implementation QFLaunchPolicyTests
- (void)testDebugAlwaysShowsWelcomeEvenAfterCompletion {
    XCTAssertTrue([QFLaunchPolicy shouldShowWelcomeForDebug:YES completed:NO]);
    XCTAssertTrue([QFLaunchPolicy shouldShowWelcomeForDebug:YES completed:YES]);
}
- (void)testReleaseOnlyShowsWelcomeUntilCompletion {
    XCTAssertTrue([QFLaunchPolicy shouldShowWelcomeForDebug:NO completed:NO]);
    XCTAssertFalse([QFLaunchPolicy shouldShowWelcomeForDebug:NO completed:YES]);
}
@end
