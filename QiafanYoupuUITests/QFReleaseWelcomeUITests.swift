import XCTest

final class QFReleaseWelcomeUITests: XCTestCase {
  func testFirstLaunchThenPersistedCompletion() throws {
    #if DEBUG
      throw XCTSkip("需 Release 构建，测试前卸载所选模拟器中的本 App。")
    #else
      continueAfterFailure = false
      let app = XCUIApplication()
      app.launchArguments = ["-QFSkipWelcome", "-QFPreviewSignedIn"]
      app.launch()
      XCTAssertTrue(app.buttons["welcome.skip"].waitForExistence(timeout: 10))
      app.buttons["welcome.skip"].tap()
      XCTAssertTrue(app.buttons["notice.continue"].waitForExistence(timeout: 5))
      XCTAssertFalse(app.buttons["notice.continue"].isEnabled)
      app.buttons["notice.agreement"].tap()
      app.buttons["notice.continue"].tap()
      XCTAssertTrue(app.buttons["tab.recipe"].waitForExistence(timeout: 5))
      app.terminate()
      app.launchArguments = ["-QFResetUIState"]
      app.launch()
      XCTAssertTrue(app.buttons["tab.recipe"].waitForExistence(timeout: 10))
      XCTAssertFalse(app.buttons["welcome.skip"].exists)
      app.buttons["tab.profile"].tap()
      XCTAssertTrue(app.buttons["profile.login"].exists)
    #endif
  }
}
