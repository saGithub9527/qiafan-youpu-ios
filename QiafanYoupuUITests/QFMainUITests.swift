import XCTest

final class QFMainUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    #if DEBUG
    app = XCUIApplication()
    #else
    throw XCTSkip("Debug UI flow; use QFReleaseWelcomeUITests for Release.")
    #endif
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func openLogin(reset: Bool) {
    app.launchArguments = ["-QFSkipWelcome", "-QFStartTab", "profile"]
    if reset { app.launchArguments += ["-QFResetUIState"] }
    app.launch()
    XCTAssertTrue(app.buttons["profile.login"].waitForExistence(timeout: 10))
    app.buttons["profile.login"].tap()
    XCTAssertTrue(app.buttons["login.quick"].waitForExistence(timeout: 5))
  }

  func testAllFourPrimaryTabs() {
    app.launchArguments = ["-QFSkipWelcome"]
    app.launch()
    for tab in ["recipe", "plan", "ingredient", "profile"] {
      let button = app.buttons["tab.\(tab)"]
      XCTAssertTrue(button.waitForExistence(timeout: 10))
      button.tap()
      XCTAssertTrue(button.isSelected)
      capture("tab-\(tab)")
    }
    XCTAssertTrue(app.buttons["profile.login"].exists)
    app.buttons["profile.login"].tap()
    XCTAssertTrue(app.buttons["login.quick"].waitForExistence(timeout: 5))
    capture("04-login")
    app.buttons["login.close"].tap()
    XCTAssertTrue(app.buttons["tab.profile"].waitForExistence(timeout: 5))
  }

  func testSwitchingTabsPreservesSearchAndDismissesKeyboard() {
    app.launchArguments = ["-QFSkipWelcome", "-QFStartTab", "ingredient"]
    app.launch()
    let search = app.textFields["ingredient.search"]
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    search.typeText("milk")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    app.buttons["tab.plan"].tap()
    XCTAssertTrue(app.buttons["tab.plan"].isSelected)
    let keyboardGone = NSPredicate(format: "exists == false")
    expectation(for: keyboardGone, evaluatedWith: app.keyboards.firstMatch)
    waitForExpectations(timeout: 5)
    app.buttons["tab.ingredient"].tap()
    XCTAssertEqual(app.textFields["ingredient.search"].value as? String, "milk")
    XCTAssertFalse(app.keyboards.firstMatch.exists)
  }

  func testLoginConsentPersistsBothDirectionsAndDoesNotAuthenticate() {
    openLogin(reset: true)
    XCTAssertEqual(app.buttons["login.agreement"].value as? String, "未勾选")
    app.buttons["login.quick"].tap()
    XCTAssertTrue(app.buttons["notice.continue"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["notice.continue"].isEnabled)
    app.buttons["notice.agreement"].tap()
    app.buttons["notice.decline"].tap()
    XCTAssertEqual(app.buttons["login.agreement"].value as? String, "未勾选")
    app.buttons["login.agreement"].tap()
    app.terminate()
    openLogin(reset: false)
    XCTAssertEqual(app.buttons["login.agreement"].value as? String, "已勾选")
    app.buttons["login.apple"].tap()
    XCTAssertTrue(app.alerts["登录暂未开放"].waitForExistence(timeout: 5))
    app.alerts.buttons["知道了"].tap()
    app.buttons["login.agreement"].tap()
    app.terminate()
    openLogin(reset: false)
    XCTAssertEqual(app.buttons["login.agreement"].value as? String, "未勾选")
  }

  func testWelcomePagesConsentAndDebugRelaunch() {
    app.launchArguments = ["-QFResetUIState"]
    app.launch()
    XCTAssertTrue(app.buttons["welcome.skip"].waitForExistence(timeout: 10))
    capture("01-welcome")
    XCTAssertFalse(app.buttons["welcome.enter"].isHittable)
    for _ in 0..<4 {
      // Swipe in the illustration area so the gesture reaches the native SwiftUI pager.
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45))
      start.press(forDuration: 0.05, thenDragTo: end)
    }
    XCTAssertTrue(app.buttons["welcome.enter"].isHittable)
    capture("02-welcome-last")
    app.buttons["welcome.enter"].tap()
    XCTAssertTrue(app.buttons["notice.continue"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["notice.continue"].isEnabled)
    capture("03-safety-notice")
    app.buttons["notice.agreement"].tap()
    XCTAssertTrue(app.buttons["notice.continue"].isEnabled)
    app.buttons["notice.continue"].tap()
    XCTAssertTrue(app.buttons["tab.recipe"].waitForExistence(timeout: 5))
    app.terminate()
    app.launchArguments = []
    app.launch()
    XCTAssertTrue(app.buttons["welcome.skip"].waitForExistence(timeout: 10))
  }
}
