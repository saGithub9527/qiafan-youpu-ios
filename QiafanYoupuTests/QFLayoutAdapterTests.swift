import UIKit
import XCTest

@testable import QiafanYoupu

final class QFLayoutAdapterTests: XCTestCase {
  @MainActor
  func testRealLoadingButtonFitsPhoneAndTabletWidthsAndStopsItsIndicator() throws {
    let button = QFAuthLoadingButton("快速登录", size: 20)
    for width: CGFloat in [140, 320, 520] {
      button.frame = CGRect(x: 0, y: 0, width: width, height: 55)
      button.setLoading(true)
      button.setNeedsLayout()
      button.layoutIfNeeded()
      let spinner = try XCTUnwrap(descendants(button).compactMap { $0 as? UIActivityIndicatorView }.first)
      XCTAssertTrue(spinner.isAnimating)
      XCTAssertFalse(spinner.hasAmbiguousLayout)
      XCTAssertTrue(button.bounds.contains(spinner.convert(spinner.bounds, to: button)))
      XCTAssertEqual(spinner.color, UIColor.white)
      button.setLoading(false)
      button.layoutIfNeeded()
      XCTAssertFalse(spinner.isAnimating)
    }
  }

  func testAdaptiveBreakpointsPreserveTheRegularLayoutAtTheBoundary() {
    XCTAssertTrue(QFAdaptiveLayout.isCompactWidth(359.5))
    XCTAssertFalse(QFAdaptiveLayout.isCompactWidth(360))
    XCTAssertFalse(QFAdaptiveLayout.isCompactWidth(768))
    XCTAssertTrue(QFAdaptiveLayout.isCompactHeight(499.5))
    XCTAssertFalse(QFAdaptiveLayout.isCompactHeight(500))
    XCTAssertFalse(QFAdaptiveLayout.isCompactHeight(768))
  }

  @MainActor
  func testLoadingButtonAccessibilityTracksDisabledAndEnabledState() {
    let button = QFAuthLoadingButton("同意并继续")
    var actionCount = 0
    button.addAction(UIAction { _ in actionCount += 1 }, for: .touchUpInside)
    button.isEnabled = false
    XCTAssertTrue(button.accessibilityTraits.contains(.notEnabled))
    XCTAssertFalse(button.isEnabled)
    button.isEnabled = true
    XCTAssertFalse(button.accessibilityTraits.contains(.notEnabled))
    button.sendActions(for: .touchUpInside)
    XCTAssertEqual(actionCount, 1)
  }

  @MainActor
  private func descendants(_ view: UIView) -> [UIView] {
    view.subviews.flatMap { [$0] + descendants($0) }
  }
}
