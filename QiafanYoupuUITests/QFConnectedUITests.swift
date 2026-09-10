import XCTest

final class QFConnectedUITests: XCTestCase {
  private var app: XCUIApplication!
  override func setUpWithError() throws {
    continueAfterFailure = false
    #if DEBUG
      app = XCUIApplication()
    #else
      throw XCTSkip("Debug-only diagnostics integration tests")
    #endif
  }

  func testStartupRequestAppearsInPaginatedDebugLog() {
    app.launchArguments = ["-QFSkipWelcome", "-QFStartTab", "recipe"]
    app.launch()
    XCTAssertTrue(app.buttons["diagnostics.open"].waitForExistence(timeout: 10))
    app.buttons["diagnostics.open"].tap()
    XCTAssertTrue(app.buttons["diagnostics.requests.close"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["diagnostics.requests.nextPage"].exists)
    XCTAssertTrue(app.buttons["diagnostics.requests.previousPage"].exists)
    let row = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "diagnostics.request.")
    ).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    capture("debug-request-list")
    row.tap()
    XCTAssertTrue(app.staticTexts["请求头"].waitForExistence(timeout: 5))
    capture("debug-request-detail")
  }

  // Opt-in: creates/reuses this simulator's account only on the configured development service.
  func testRealQuickLoginAndSessionRestore() throws {
    guard ProcessInfo.processInfo.environment["QF_RUN_LIVE_AUTH_TEST"] == "1" else {
      throw XCTSkip("Live test is opt-in and uses the development API only")
    }
    app.launchArguments = ["-QFSkipWelcome", "-QFStartTab", "profile"]
    app.launch()
    let loginEntry = app.buttons["profile.login"]
    XCTAssertTrue(loginEntry.waitForExistence(timeout: 10))
    if loginEntry.label == "去登录" {
      loginEntry.tap()
      XCTAssertTrue(app.buttons["login.quick"].waitForExistence(timeout: 5))
      expectation(
        for: NSPredicate(format: "value == %@", "可用"), evaluatedWith: app.buttons["login.quick"])
      waitForExpectations(timeout: 30)
      let agreement = app.buttons["login.agreement"]
      if agreement.value as? String != "已勾选" { agreement.tap() }
      app.buttons["login.quick"].tap()
      XCTAssertTrue(loginEntry.waitForExistence(timeout: 30))
      XCTAssertEqual(loginEntry.label, "编辑资料")
      XCTAssertFalse(app.buttons["login.quick"].exists)
    }
    capture("profile-real-login")
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["profile.login"].waitForExistence(timeout: 10))
    let restored = NSPredicate(format: "label == %@", "编辑资料")
    expectation(for: restored, evaluatedWith: app.buttons["profile.login"])
    waitForExpectations(timeout: 25)
    capture("profile-restored-session")
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
