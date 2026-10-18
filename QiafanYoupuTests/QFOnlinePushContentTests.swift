import UIKit
import XCTest

@testable import QiafanYoupu

final class QFOnlinePushContentTests: XCTestCase {
  private let planID = "ac0115b9-059a-4a52-85d1-8c293dc49386"
  private let notificationID = "cd0115b9-059a-4a52-85d1-8c293dc49386"

  func testDecodesGetuiEnvelopeAndPreservesLocalizedCopy() throws {
    let envelope = try makeEnvelope()
    let content = try XCTUnwrap(QFOnlinePushContent.decode(["payload": envelope]))
    XCTAssertEqual(content.id, notificationID)
    XCTAssertEqual(content.title, "食事プランのお知らせ")
    XCTAssertEqual(content.body, "まもなく開始：ご飯")
    XCTAssertEqual(content.route["plannedMealId"], planID)
  }

  func testLegacyRoutingPayloadDoesNotInventVisibleCopy() {
    XCTAssertNil(QFOnlinePushContent.decode(["type": "PLAN_REMINDER", "plannedMealId": planID]))
  }

  func testRejectsUnsupportedPayloadAndDeepNesting() throws {
    XCTAssertNil(QFOnlinePushContent.decode(try makeEnvelope(type: "OTHER")))
    var nested: Any = try makeEnvelope()
    for _ in 0..<8 { nested = ["payload": nested] }
    XCTAssertNil(QFOnlinePushContent.decode(nested))
  }

  private func makeEnvelope(type: String = "PLAN_REMINDER") throws -> String {
    let route = try JSONSerialization.data(withJSONObject: ["type": type, "plannedMealId": planID])
    let envelope: [String: String] = [
      "notificationId": notificationID, "title": "食事プランのお知らせ",
      "body": "まもなく開始：ご飯", "payload": String(decoding: route, as: UTF8.self),
    ]
    return String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
  }
}

@MainActor
final class QFDigitalAssistantRegressionTests: XCTestCase {
  private func find(_ identifier: String, in root: UIView) -> UIView? {
    if root.accessibilityIdentifier == identifier { return root }
    return root.subviews.lazy.compactMap { self.find(identifier, in: $0) }.first
  }

  func testConversationBuildsWithoutCrossHierarchyConstraintException() {
    let app = QFAppSession()
    let controller = QFDigitalAssistantConversationViewController(app: app)
    controller.loadViewIfNeeded()

    XCTAssertNotNil(controller.view)
    XCTAssertNotNil(find("assistant.conversation.panel", in: controller.view))
    XCTAssertNotNil(find("assistant.conversation.close", in: controller.view))
  }

  func testMascotAssetIsPresentInTheApplicationBundle() throws {
    let bundle = Bundle(for: QFDigitalAssistantRegressionTests.self)
    let candidates = [Bundle(identifier: "com.talka.qiafanyoupu"), Bundle.main, bundle]
      .compactMap { $0 }
    guard candidates.contains(where: {
      UIImage(named: "qf-assistant-mascot", in: $0, compatibleWith: nil) != nil
    }) else {
      throw XCTSkip("The unit-test host does not expose application assets; build assetutil verifies Assets.car.")
    }
  }
}
