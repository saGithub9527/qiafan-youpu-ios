import UIKit
import XCTest

final class QFAdaptiveUITests: XCTestCase {
  @MainActor
  func testPrimaryTabsRemainReachableAcrossSupportedOrientations() throws {
    #if !DEBUG
      throw XCTSkip("Layout navigation uses the existing Debug -QFSkipWelcome option.")
    #else
      continueAfterFailure = false
      let app = XCUIApplication()
      XCUIDevice.shared.orientation = .portrait
      defer {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
      }
      app.launchArguments = ["-QFSkipWelcome"]
      app.launch()
      XCTAssertTrue(app.buttons["tab.recipe"].waitForExistence(timeout: 10))
      assertWindowOrientation(app, landscape: false)
      inspectTabs(app, orientation: "portrait")

      if UIDevice.current.userInterfaceIdiom == .pad {
        XCUIDevice.shared.orientation = .landscapeLeft
        assertWindowOrientation(app, landscape: true)
        inspectTabs(app, orientation: "landscape")
        XCUIDevice.shared.orientation = .portrait
        assertWindowOrientation(app, landscape: false)
      }
    #endif
  }

  private func inspectTabs(_ app: XCUIApplication, orientation: String) {
    let screens = [
      (tab: "recipe", action: "recipe.search"),
      (tab: "plan", action: "plan.create"),
      (tab: "ingredient", action: "ingredient.add"),
      (tab: "profile", action: "profile.login"),
    ]
    for screen in screens {
      let tab = app.buttons["tab.\(screen.tab)"]
      assertReachable(tab, in: app)
      tab.tap()
      let selected = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "selected == true"), object: tab)
      XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)

      // Verify the current page's primary action without invoking a business or login action.
      assertReachable(app.buttons[screen.action], in: app)
      for other in screens {
        assertReachable(app.buttons["tab.\(other.tab)"], in: app)
      }
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = "adaptive-\(orientation)-\(screen.tab)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  private func assertReachable(
    _ element: XCUIElement, in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard element.waitForExistence(timeout: 5) else {
      XCTFail("Missing layout control: \(element.identifier)", file: file, line: line)
      return
    }
    let reachable = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        let frame = element.frame
        let window = app.windows.firstMatch.frame
        return element.isHittable && frame.width > 0 && frame.height > 0
          && window.insetBy(dx: -1, dy: -1).contains(frame)
      }, object: element)
    XCTAssertEqual(
      XCTWaiter.wait(for: [reachable], timeout: 5), .completed,
      "Control must fit inside the current window: \(element.identifier)", file: file, line: line)
  }

  private func assertWindowOrientation(_ app: XCUIApplication, landscape: Bool) {
    let resized = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        let frame = app.windows.firstMatch.frame
        return frame.width > 0 && frame.height > 0
          && (landscape ? frame.width > frame.height : frame.height > frame.width)
      }, object: app)
    XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 10), .completed)
  }
}
