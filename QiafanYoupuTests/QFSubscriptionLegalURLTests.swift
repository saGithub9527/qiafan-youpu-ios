import XCTest
@testable import QiafanYoupu

@MainActor
final class QFSubscriptionLegalURLTests: XCTestCase {
  func testPurchaseLegalURLsRequireHTTPSAndAnUncredentialedHost() {
    for raw in [nil, "", "/terms", "http://example.org/terms", "https:///",
      "https://user:secret@example.org/terms"] as [String?] {
      XCTAssertNil(QFMembershipViewController.https(raw))
    }
  }

  func testRealHTTPSPathAndQueryArePreserved() {
    let raw = "https://example.org/legal/terms?language=en"
    XCTAssertEqual(QFMembershipViewController.https(raw)?.absoluteString, raw)
  }
}
