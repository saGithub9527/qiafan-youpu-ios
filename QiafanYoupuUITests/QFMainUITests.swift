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

  private func assertAgreementIsVerticallyCentered(_ identifier: String) {
    let checkbox = app.buttons[identifier]
    let copy = app.descendants(matching: .any).matching(identifier: "\(identifier).text").firstMatch
    XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
    XCTAssertTrue(copy.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(copy.frame.height, 0)
    XCTAssertEqual(checkbox.frame.midY, copy.frame.midY, accuracy: 2)
  }

  private func openLogin(reset: Bool) {
    app.launchArguments = ["-QFSkipWelcome", "-QFStartTab", "profile"]
    if reset { app.launchArguments += ["-QFResetUIState"] }
    app.launch()
    XCTAssertTrue(app.buttons["profile.login"].waitForExistence(timeout: 10))
    app.buttons["profile.login"].tap()
    if !app.buttons["login.quick"].waitForExistence(timeout: 5) {
      // Session restoration can finish between reading the profile label and tapping it.
      // Check the actual destination, then revoke only this simulator's test session.
      XCTAssertTrue(app.alerts["编辑资料"].waitForExistence(timeout: 5))
      app.alerts["编辑资料"].buttons["知道了"].tap()
      app.buttons["diagnostics.open"].tap()
      let menu = app.buttons["diagnostics.menu"]
      XCTAssertTrue(menu.waitForExistence(timeout: 5))
      expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: menu)
      waitForExpectations(timeout: 30)
      menu.tap()
      app.buttons["退出当前测试会话"].tap()
      expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: menu)
      waitForExpectations(timeout: 30)
      app.buttons["diagnostics.requests.close"].tap()
      expectation(
        for: NSPredicate(format: "label == %@", "去登录"),
        evaluatedWith: app.buttons["profile.login"])
      waitForExpectations(timeout: 10)
      app.buttons["profile.login"].tap()
    }
    XCTAssertTrue(app.buttons["login.quick"].waitForExistence(timeout: 5))
    let ready = NSPredicate(format: "value == %@", "可用")
    expectation(for: ready, evaluatedWith: app.buttons["login.quick"])
    waitForExpectations(timeout: 30)
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
    assertAgreementIsVerticallyCentered("login.agreement")
    capture("login-centered-agreement")
    XCTAssertTrue(app.buttons["login.quick"].isEnabled)
    XCTAssertTrue(app.buttons["login.apple"].isEnabled)
    XCTAssertNotEqual(app.buttons["login.apple"].value as? String, "正在等待 Apple 授权")
    XCTAssertNotEqual(app.buttons["login.apple"].value as? String, "正在登录")
    XCTAssertEqual(app.buttons["login.agreement"].value as? String, "未勾选")
    app.buttons["login.quick"].tap()
    XCTAssertTrue(app.buttons["notice.continue"].waitForExistence(timeout: 5))
    assertAgreementIsVerticallyCentered("notice.agreement")
    capture("notice-centered-agreement")
    XCTAssertFalse(app.buttons["notice.continue"].isEnabled)
    app.buttons["notice.agreement"].tap()
    app.buttons["notice.decline"].tap()
    XCTAssertEqual(app.buttons["login.agreement"].value as? String, "未勾选")
    app.buttons["login.agreement"].tap()
    app.terminate()
    openLogin(reset: false)
    XCTAssertEqual(app.buttons["login.agreement"].value as? String, "已勾选")
    // Toggling consent must not start real Apple authorization or create an account.
    XCTAssertTrue(app.buttons["login.quick"].exists)
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
