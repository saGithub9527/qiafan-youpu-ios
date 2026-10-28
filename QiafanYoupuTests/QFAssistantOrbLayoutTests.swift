import UIKit
import XCTest

@testable import QiafanYoupu

final class QFAssistantOrbLayoutTests: XCTestCase {
  func testInitialPlacementKeepsReferenceSizeAndOffsets() {
    let layout = makeLayout()
    let orb = layout.orbFrame(relativePosition: nil)
    XCTAssertEqual(orb.size, CGSize(width: 92, height: 112))
    XCTAssertEqual(layout.safeBounds.maxX - orb.maxX, 14, accuracy: 0.001)
    XCTAssertEqual(layout.safeBounds.maxY - orb.maxY, 126, accuracy: 0.001)
  }

  func testDraggedLeftMiddleAndRightStayInsideAsymmetricSafeArea() {
    let layout = makeLayout(width: 320, insets: UIEdgeInsets(top: 47, left: 31, bottom: 34, right: 17))
    for center in [CGPoint(x: -500, y: -500), CGPoint(x: 160, y: 300), CGPoint(x: 900, y: 1200)] {
      let frame = layout.orbFrame(center: center)
      assertContains(layout.safeBounds, frame)
      XCTAssertEqual(frame.size, QFAssistantOrbLayout.buttonSize)
    }
  }

  func testRelativePositionSurvivesResizeWithoutAccumulatingClampDrift() {
    let original = makeLayout()
    let frame = original.orbFrame(center: CGPoint(x: 115, y: 610))
    let position = original.relativePosition(for: frame)
    let resized = makeLayout(width: 320, insets: UIEdgeInsets(top: 47, left: 19, bottom: 34, right: 7))
    let moved = resized.orbFrame(relativePosition: position)
    assertContains(resized.safeBounds, moved)
    let roundTrip = original.orbFrame(relativePosition: position)
    XCTAssertEqual(roundTrip.minX, frame.minX, accuracy: 0.001)
    XCTAssertEqual(roundTrip.minY, frame.minY, accuracy: 0.001)
    XCTAssertEqual(resized.relativePosition(for: moved).x, position.x, accuracy: 0.001)
    XCTAssertEqual(resized.relativePosition(for: moved).y, position.y, accuracy: 0.001)
  }

  func testDockedAndFloatingKeyboardAvoidancePreservesStoredScenePosition() {
    let original = makeLayout()
    let position = CGPoint(x: 0.95, y: 0.9)
    let initial = original.orbFrame(relativePosition: position)
    for keyboard in [CGRect(x: 0, y: 470, width: 390, height: 374),
                     CGRect(x: 150, y: 430, width: 230, height: 220)] {
      let layout = makeLayout(keyboard: keyboard)
      let frame = layout.orbFrame(relativePosition: position)
      assertContains(layout.safeBounds, frame)
      XCTAssertFalse(frame.intersects(keyboard))
      XCTAssertEqual(frame.size, QFAssistantOrbLayout.buttonSize)
    }
    XCTAssertEqual(original.orbFrame(relativePosition: position), initial,
                   "Temporary keyboard clamping must not overwrite the stored scene position")
  }

  func testBubbleCanUseEitherSideOrVerticalSpaceWithoutCoveringOrb() throws {
    let layout = makeLayout()
    let leftOrb = layout.orbFrame(relativePosition: CGPoint(x: 0, y: 0.5))
    let rightOrb = layout.orbFrame(relativePosition: CGPoint(x: 1, y: 0.5))
    let middleOrb = layout.orbFrame(relativePosition: CGPoint(x: 0.5, y: 0.5))
    for (orb, side) in [(leftOrb, QFAssistantOrbLayout.BubbleSide.right), (rightOrb, .left)] {
      let placement = try XCTUnwrap(layout.bubblePlacement(near: orb, sizeThatFits: longTextSize))
      XCTAssertEqual(placement.side, side)
      assertContains(layout.safeBounds, placement.frame)
      XCTAssertFalse(placement.frame.intersects(orb))
    }
    let middle = try XCTUnwrap(layout.bubblePlacement(near: middleOrb, sizeThatFits: longTextSize))
    XCTAssertTrue(middle.side == .above || middle.side == .below)
    assertContains(layout.safeBounds, middle.frame)
    XCTAssertFalse(middle.frame.intersects(middleOrb))
  }

  func testBubbleAndOrbAvoidKeyboardAtNarrowWidths() throws {
    let keyboard = CGRect(x: 0, y: 410, width: 320, height: 434)
    let layout = makeLayout(width: 320, insets: UIEdgeInsets(top: 59, left: 27, bottom: 34, right: 13), keyboard: keyboard)
    for position in [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)] {
      let orb = layout.orbFrame(relativePosition: position)
      let bubble = try XCTUnwrap(layout.bubblePlacement(near: orb, sizeThatFits: longTextSize))
      assertContains(layout.safeBounds, bubble.frame)
      XCTAssertFalse(orb.intersects(keyboard))
      XCTAssertFalse(bubble.frame.intersects(keyboard))
      XCTAssertFalse(bubble.frame.intersects(orb))
      XCTAssertLessThanOrEqual(bubble.frame.width, 240)
    }
  }

  func testDegenerateSpaceProducesFiniteContainedFramesAndNoPhantomBubble() {
    for bounds in [CGRect.zero, CGRect(x: 0, y: 0, width: 36, height: 48)] {
      let layout = QFAssistantOrbLayout(bounds: bounds, safeAreaInsets: .zero)
      let orb = layout.orbFrame(relativePosition: CGPoint(x: 1, y: 1))
      XCTAssertTrue(orb.minX.isFinite && orb.minY.isFinite && orb.width.isFinite && orb.height.isFinite)
      assertContains(bounds, orb)
      XCTAssertNil(layout.bubblePlacement(near: orb, sizeThatFits: longTextSize))
    }
    let covered = makeLayout(keyboard: CGRect(x: 0, y: 0, width: 390, height: 844))
    XCTAssertEqual(covered.orbFrame(relativePosition: nil).size, .zero)
    XCTAssertNil(covered.bubblePlacement(near: .zero, sizeThatFits: longTextSize))
  }

  @MainActor
  func testNativePanConfigurationAndActivationPolicyRejectRecognizedDragStates() {
    let pan = QFAssistantOrbLayout.makePanRecognizer(target: nil, action: nil)
    XCTAssertTrue(pan.cancelsTouchesInView)
    XCTAssertEqual(pan.minimumNumberOfTouches, 1)
    XCTAssertEqual(pan.maximumNumberOfTouches, 1)
    XCTAssertTrue(QFAssistantOrbLayout.allowsActivation(panState: .possible))
    XCTAssertTrue(QFAssistantOrbLayout.allowsActivation(panState: .failed))
    for state in [UIGestureRecognizer.State.began, .changed, .ended, .cancelled] {
      XCTAssertFalse(QFAssistantOrbLayout.allowsActivation(panState: state))
    }
  }

  @MainActor
  func testOverlayPassesEmptySpaceAndScreenEdgesButRetainsActualControlHits() {
    let window = QFAssistantOverlayWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
    let controller = UIViewController()
    window.rootViewController = controller
    controller.view.frame = window.bounds
    let button = UIButton(frame: CGRect(x: 0, y: 250, width: 92, height: 112))
    let bubble = UIView(frame: CGRect(x: 110, y: 250, width: 160, height: 90))
    controller.view.addSubview(button); controller.view.addSubview(bubble)
    window.isHidden = false
    defer { window.isHidden = true; window.rootViewController = nil; window.windowScene = nil }
    XCTAssertFalse(window.canBecomeKey)
    XCTAssertNil(window.hitTest(CGPoint(x: 160, y: 100), with: nil))
    XCTAssertNil(window.hitTest(CGPoint(x: 5, y: 300), with: nil), "The system back-edge strip belongs to the underlying window")
    XCTAssertNil(window.hitTest(CGPoint(x: 318, y: 300), with: nil))
    XCTAssertTrue(window.hitTest(CGPoint(x: 50, y: 300), with: nil) === button)
    XCTAssertTrue(window.hitTest(CGPoint(x: 150, y: 280), with: nil) === bubble)
    bubble.isHidden = true
    XCTAssertNil(window.hitTest(CGPoint(x: 150, y: 280), with: nil))
  }

  @MainActor
  func testBoundedGreetingKeepsFullAccessibleTextAndScrollableContent() throws {
    let text = String(repeating: "A complete localized greeting must remain readable. ", count: 30)
    let bubble = QFAssistantOrbSpeechView(text: text, scrollable: true)
    bubble.frame = CGRect(origin: .zero, size: bubble.fittingSize(in: CGSize(width: 170, height: 100)))
    bubble.layoutIfNeeded()
    let scroll = try XCTUnwrap(bubble.subviews.compactMap { $0 as? UIScrollView }.first)
    scroll.layoutIfNeeded()
    XCTAssertEqual(bubble.text, text)
    XCTAssertEqual(bubble.accessibilityLabel, text)
    XCTAssertEqual(bubble.bounds.height, 100, accuracy: 0.001)
    XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
    XCTAssertTrue(scroll.isScrollEnabled)
    XCTAssertFalse(scroll.scrollsToTop)
  }

  private func makeLayout(width: CGFloat = 390, insets: UIEdgeInsets = UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0),
                          keyboard: CGRect? = nil) -> QFAssistantOrbLayout {
    QFAssistantOrbLayout(bounds: CGRect(x: 0, y: 0, width: width, height: 844), safeAreaInsets: insets, keyboardFrame: keyboard)
  }

  private func longTextSize(_ limit: CGSize) -> CGSize { CGSize(width: min(limit.width, 240), height: min(limit.height, 600)) }

  private func assertContains(_ outer: CGRect, _ inner: CGRect, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertGreaterThanOrEqual(inner.minX, outer.minX - 0.001, file: file, line: line)
    XCTAssertGreaterThanOrEqual(inner.minY, outer.minY - 0.001, file: file, line: line)
    XCTAssertLessThanOrEqual(inner.maxX, outer.maxX + 0.001, file: file, line: line)
    XCTAssertLessThanOrEqual(inner.maxY, outer.maxY + 0.001, file: file, line: line)
  }
}
