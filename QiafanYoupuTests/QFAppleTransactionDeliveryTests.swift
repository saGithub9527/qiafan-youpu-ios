import XCTest
@testable import QiafanYoupu

@MainActor
final class QFAppleTransactionDeliveryTests: XCTestCase {
  private let identity = QFAppleTransactionIdentity(transactionId: "transaction-a",
    originalTransactionId: "original-a", bundleId: "com.talka.qiafanyoupu", appleEnvironment: "SANDBOX")

  private func receipt(_ changes: [String: Any] = [:]) throws -> QFMembershipStatus {
    var value: [String: Any] = ["launchState": "OPEN", "activeSubscription": false,
      "productIds": [], "contractVersion": "core-subscription-v2", "accessState": "REVOKED",
      "revision": 3, "accessSource": "APPLE_SANDBOX", "appleEnvironment": "SANDBOX",
      "serverTime": "2026-01-01T00:01:00Z", "verifiedAt": "2026-01-01T00:00:30Z",
      "acceptedTransaction": ["transactionId": "transaction-a", "originalTransactionId": "original-a",
        "bundleId": "com.talka.qiafanyoupu", "appleEnvironment": "SANDBOX",
        "acceptedAt": "2026-01-01T00:00:59Z"]]
    changes.forEach { value[$0.key] = $0.value }
    return try JSONDecoder().decode(QFMembershipStatus.self,
      from: JSONSerialization.data(withJSONObject: value))
  }

  func testReliableRevocationIsAppliedBeforeDeliveryIsFinished() async throws {
    let status = try receipt()
    var events: [String] = []
    try await QFVerifiedAppleTransactionDelivery.deliver(signedTransactionInfo: "fixture-jws", identity: identity,
      isCurrent: { true }, verify: { payload in
        XCTAssertEqual(payload, "fixture-jws"); events.append("server"); return status
      }, apply: { value in
        XCTAssertEqual(value.accessState, "REVOKED"); events.append("apply")
      }, finish: { events.append("finish") })
    XCTAssertEqual(events, ["server", "apply", "finish"])
  }

  func testUnavailableAndBindingConflictNeverFinishTheTransaction() async {
    for code in [50300, 40904] {
      var finished = false, applied = false
      do {
        try await QFVerifiedAppleTransactionDelivery.deliver(signedTransactionInfo: "fixture-jws", identity: identity,
          isCurrent: { true }, verify: { _ in throw QFAPIError(code: code, message: "fixture") },
          apply: { _ in applied = true }, finish: { finished = true })
        XCTFail("Expected server rejection")
      } catch { XCTAssertEqual((error as? QFAPIError)?.code, code) }
      XCTAssertFalse(finished); XCTAssertFalse(applied)
    }
  }

  func testAccountSwitchDuringServerVerificationCannotApplyOrFinish() async throws {
    let status = try receipt()
    var current = true, finished = false, applied = false
    do {
      try await QFVerifiedAppleTransactionDelivery.deliver(signedTransactionInfo: "fixture-jws", identity: identity,
        isCurrent: { current }, verify: { _ in current = false; return status },
        apply: { _ in applied = true }, finish: { finished = true })
      XCTFail("Expected account cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertFalse(finished); XCTAssertFalse(applied)
  }

  func testOldAccountNeverStartsVerification() async {
    var verified = false, finished = false
    do {
      try await QFVerifiedAppleTransactionDelivery.deliver(signedTransactionInfo: "fixture-jws", identity: identity,
        isCurrent: { false }, verify: { _ in verified = true; throw CancellationError() },
        apply: { _ in XCTFail("No receipt") }, finish: { finished = true })
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertFalse(verified); XCTAssertFalse(finished)
  }

  func testUnknownOrLegacyResponseDoesNotAcknowledgeDelivery() async throws {
    for changes in [["accessState": "UNKNOWN"], ["accessState": "NONE"], ["contractVersion": "legacy"], ["acceptedTransaction": NSNull()]] as [[String: Any]] {
      let status = try receipt(changes)
      var finished = false
      do {
        try await QFVerifiedAppleTransactionDelivery.deliver(signedTransactionInfo: "fixture-jws", identity: identity,
          isCurrent: { true }, verify: { _ in status },
          apply: { _ in XCTFail("Unconfirmed receipt") }, finish: { finished = true })
        XCTFail("Expected unconfirmed response")
      } catch { }
      XCTAssertFalse(finished)
    }
  }

  func testApplicationRejectionCannotFinish() async throws {
    let status = try receipt()
    var finished = false
    do {
      try await QFVerifiedAppleTransactionDelivery.deliver(signedTransactionInfo: "fixture-jws", identity: identity,
        isCurrent: { true }, verify: { _ in status },
        apply: { _ in throw CancellationError() }, finish: { finished = true })
      XCTFail("Expected stale result rejection")
    } catch { }
    XCTAssertFalse(finished)
  }
  func testTransactionReceiptMustMatchAllVerifiedAppleIdentityFields() async throws {
    for field in ["transactionId", "originalTransactionId", "bundleId", "appleEnvironment", "acceptedAt"] {
      var accepted = ["transactionId": "transaction-a", "originalTransactionId": "original-a",
        "bundleId": "com.talka.qiafanyoupu", "appleEnvironment": "SANDBOX",
        "acceptedAt": "2026-01-01T00:00:59Z"]
      accepted[field] = "unrelated-or-invalid"
      let status = try receipt(["acceptedTransaction": accepted])
      var finished = false
      do {
        try await QFVerifiedAppleTransactionDelivery.deliver(signedTransactionInfo: "fixture-jws", identity: identity,
          isCurrent: { true }, verify: { _ in status },
          apply: { _ in XCTFail("Wrong transaction") }, finish: { finished = true })
        XCTFail("Expected transaction-specific receipt rejection")
      } catch { }
      XCTAssertFalse(finished, field)
    }
  }

  func testJavaInstantNanosecondReceiptAllowsFinishingAcceptedDelivery() async throws {
    let status = try receipt([
      "serverTime": "2026-01-01T00:01:00.123456789Z",
      "verifiedAt": "2026-01-01T00:01:00.123456700Z",
      "acceptedTransaction": ["transactionId": "transaction-a", "originalTransactionId": "original-a",
        "bundleId": "com.talka.qiafanyoupu", "appleEnvironment": "SANDBOX",
        "acceptedAt": "2026-01-01T00:01:00.123456789Z"]])
    var finished = false
    try await QFVerifiedAppleTransactionDelivery.deliver(signedTransactionInfo: "fixture-jws", identity: identity,
      isCurrent: { true }, verify: { _ in status }, apply: { _ in }, finish: { finished = true })
    XCTAssertTrue(finished)
  }

  func testAggregateProductionAccessCanAcknowledgeThisSandboxTransaction() async throws {
    let status = try receipt(["accessState": "ACTIVE", "appleEnvironment": "PRODUCTION",
      "accessSource": "APPLE_PRODUCTION"])
    var finished = false
    try await QFVerifiedAppleTransactionDelivery.deliver(signedTransactionInfo: "fixture-jws", identity: identity,
      isCurrent: { true }, verify: { _ in status }, apply: { _ in }, finish: { finished = true })
    XCTAssertTrue(finished)
  }

}
