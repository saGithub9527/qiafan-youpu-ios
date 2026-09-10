import XCTest

@testable import QiafanYoupu

final class QFLaunchPolicyTests: XCTestCase {
  func testDebugAlwaysShowsWelcomeEvenAfterCompletion() {
    XCTAssertTrue(QFLaunchPolicy.shouldShowWelcome(isDebug: true, completed: false))
    XCTAssertTrue(QFLaunchPolicy.shouldShowWelcome(isDebug: true, completed: true))
  }

  func testReleaseOnlyShowsWelcomeUntilCompletion() {
    XCTAssertTrue(QFLaunchPolicy.shouldShowWelcome(isDebug: false, completed: false))
    XCTAssertFalse(QFLaunchPolicy.shouldShowWelcome(isDebug: false, completed: true))
  }
}
