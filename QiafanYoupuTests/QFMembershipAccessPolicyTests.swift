import XCTest
@testable import QiafanYoupu

final class QFMembershipAccessPolicyTests: XCTestCase {
  private let binding = QFMembershipBinding(scope: "production/account-a", generation: 7)

  func testRevocationWithTheCurrentAccountTokenMatchesOnlyItsConfiguredProducts() {
    let token = UUID()
    let context = QFMembershipPurchaseContext(contractVersion: "core-subscription-v2",
      appAccountToken: token, productIds: ["monthly"], subscriptionGroupId: nil, serverTime: "fixture")
    let identity = QFAppleTransactionIdentity(transactionId: "1", originalTransactionId: "1",
      bundleId: "app", appleEnvironment: "SANDBOX")
    XCTAssertTrue(QFMembershipRevocationPolicy.matches(identity: identity, bundleId: "app",
      productId: "monthly", appAccountToken: token, context: context, confirmedChains: []))
    XCTAssertFalse(QFMembershipRevocationPolicy.matches(identity: identity, bundleId: "app",
      productId: "monthly", appAccountToken: UUID(), context: context, confirmedChains: []))
    XCTAssertFalse(QFMembershipRevocationPolicy.matches(identity: identity, bundleId: "app",
      productId: "unrelated-product", appAccountToken: token, context: context, confirmedChains: []))
  }

  func testLegacyTokenlessRevocationNeedsAConfirmedOriginalChainInThisBinding() {
    let identity = QFAppleTransactionIdentity(transactionId: "2", originalTransactionId: "1",
      bundleId: "app", appleEnvironment: "SANDBOX")
    XCTAssertFalse(QFMembershipRevocationPolicy.matches(identity: identity, bundleId: "app",
      productId: "monthly", appAccountToken: nil, context: nil, confirmedChains: []))
    XCTAssertTrue(QFMembershipRevocationPolicy.matches(identity: identity, bundleId: "app",
      productId: "monthly", appAccountToken: nil, context: nil,
      confirmedChains: [QFMembershipRevocationPolicy.originalChain(identity)]))
  }

  func testRevocationCannotCrossBundleOrAppleEnvironment() {
    let sandbox = QFAppleTransactionIdentity(transactionId: "1", originalTransactionId: "1",
      bundleId: "app", appleEnvironment: "SANDBOX")
    let production = QFAppleTransactionIdentity(transactionId: "1", originalTransactionId: "1",
      bundleId: "app", appleEnvironment: "PRODUCTION")
    let known: Set<String> = [QFMembershipRevocationPolicy.originalChain(sandbox)]
    XCTAssertFalse(QFMembershipRevocationPolicy.matches(identity: production, bundleId: "app",
      productId: "monthly", appAccountToken: nil, context: nil, confirmedChains: known))
    XCTAssertFalse(QFMembershipRevocationPolicy.matches(identity: sandbox, bundleId: "other-app",
      productId: "monthly", appAccountToken: nil, context: nil, confirmedChains: known))
  }

  private func status(_ changes: [String: Any] = [:]) throws -> QFMembershipStatus {
    var value: [String: Any] = [
      "launchState": "OPEN", "activeSubscription": true, "productIds": [],
      "benefitsActive": true, "entitlementSource": "APPLE", "contractVersion": "core-subscription-v2",
      "accessState": "ACTIVE", "accessSource": "APPLE_PRODUCTION", "appleEnvironment": "PRODUCTION",
      "serverTime": "2026-01-01T00:00:00Z", "verifiedAt": "2026-01-01T00:00:00Z",
      "effectiveUntil": "2026-01-01T01:00:00Z", "appleExpiresAt": "2026-01-01T01:00:00Z",
      "offlineUntil": "2026-01-01T00:15:00Z", "revision": 3,
      "accessEntitlements": ["CORE_COOKING", "ORB_PROACTIVE_SPEECH"]
    ]
    changes.forEach { value[$0.key] = $0.value }
    return try JSONDecoder().decode(QFMembershipStatus.self,
      from: JSONSerialization.data(withJSONObject: value))
  }

  func testLegacyTestFlagsCannotGrantV2BusinessAccess() throws {
    let old = try JSONDecoder().decode(QFMembershipStatus.self, from: Data(
      #"{"launchState":"TEST","activeSubscription":true,"productIds":[],"benefitsActive":true,"entitlementSource":"TEST"}"#.utf8))
    XCTAssertTrue(old.isTestAccess)
    XCTAssertEqual(QFMembershipAccessPhase(status: old), .unknown)
    XCTAssertNil(QFMembershipVerifiedSnapshot(status: old, binding: binding, receivedUptime: 100))
    XCTAssertNil(QFMembershipVerifiedSnapshot(status: try status(["accessSource": "TEST"]),
      binding: binding, receivedUptime: 100))
  }

  func testOfflineWindowEndsAtFifteenMinutesWithNoExactBoundaryPass() throws {
    let snapshot = try XCTUnwrap(QFMembershipVerifiedSnapshot(status: status(), binding: binding, receivedUptime: 100))
    XCTAssertTrue(snapshot.allowsAccess(for: binding, at: 999.999, offline: true))
    XCTAssertFalse(snapshot.allowsAccess(for: binding, at: 1_000, offline: true))
    XCTAssertFalse(snapshot.allowsAccess(for: binding, at: 1_001, offline: false))
  }

  func testEveryActiveAuthorizationIsClampedToTheServerLeaseBeforeAnyNetworkFailure() throws {
    let snapshot = try XCTUnwrap(QFMembershipVerifiedSnapshot(status: status([
      "serverTime": "2026-01-01T00:01:00Z"
    ]), binding: binding, receivedUptime: 100, requestDuration: 2))
    XCTAssertTrue(snapshot.allowsAccess(for: binding, at: 937.999, offline: false))
    XCTAssertFalse(snapshot.allowsAccess(for: binding, at: 938, offline: false))
    XCTAssertFalse(snapshot.allowsAccess(for: binding, at: 938, offline: true))
    XCTAssertNil(QFMembershipVerifiedSnapshot(status: try status(["offlineUntil": NSNull()]),
      binding: binding, receivedUptime: 100))
  }

  func testGraceFreshnessCountsAgeAlreadySpentInTheServerCache() throws {
    let snapshot = try XCTUnwrap(QFMembershipVerifiedSnapshot(status: status([
      "accessState": "IN_GRACE_PERIOD", "serverTime": "2026-01-01T00:00:55Z"
    ]), binding: binding, receivedUptime: 100, requestDuration: 2))
    XCTAssertTrue(snapshot.allowsAccess(for: binding, at: 102.999, offline: false))
    XCTAssertFalse(snapshot.allowsAccess(for: binding, at: 103, offline: false))
    XCTAssertFalse(snapshot.allowsAccess(for: binding, at: 100, offline: true))
  }

  func testJavaInstantNanosecondsPreserveTheExactServerLeaseBoundary() throws {
    let snapshot = try XCTUnwrap(QFMembershipVerifiedSnapshot(status: status([
      "serverTime": "2026-01-01T00:00:00.123456789Z",
      "verifiedAt": "2026-01-01T00:00:00.123456789Z",
      "offlineUntil": "2026-01-01T00:15:00.123456789Z"
    ]), binding: binding, receivedUptime: 100))
    XCTAssertTrue(snapshot.allowsAccess(for: binding, at: 999.999, offline: false))
    XCTAssertFalse(snapshot.allowsAccess(for: binding, at: 1_000, offline: false))
  }

  func testNewOriginalChainMayStartAtRevisionOne() throws {
    let snapshot = try XCTUnwrap(QFMembershipVerifiedSnapshot(status: status(["revision": 1]),
      binding: binding, receivedUptime: 100))
    XCTAssertTrue(snapshot.allowsAccess(for: binding, at: 101, offline: false))
  }

  func testAppleExpiryAndTransportAgeShortenTheWindow() throws {
    let snapshot = try XCTUnwrap(QFMembershipVerifiedSnapshot(status: status([
      "appleExpiresAt": "2026-01-01T00:02:00Z"
    ]), binding: binding, receivedUptime: 100, requestDuration: 10))
    XCTAssertTrue(snapshot.allowsAccess(for: binding, at: 209.999, offline: true))
    XCTAssertFalse(snapshot.allowsAccess(for: binding, at: 210, offline: true))
  }

  func testScopeGenerationAndMonotonicClockCannotReuseAnotherOwnerSnapshot() throws {
    let snapshot = try XCTUnwrap(QFMembershipVerifiedSnapshot(status: status(), binding: binding, receivedUptime: 100))
    for other in [QFMembershipBinding(scope: "test/account-a", generation: 7),
                  QFMembershipBinding(scope: "production/account-b", generation: 7),
                  QFMembershipBinding(scope: "production/account-a", generation: 8)] {
      XCTAssertFalse(snapshot.allowsAccess(for: other, at: 101, offline: false))
    }
    XCTAssertFalse(snapshot.allowsAccess(for: binding, at: 99, offline: false))
  }

  func testGraceCanUseVerifiedOnlineExtensionButNeverOffline() throws {
    let snapshot = try XCTUnwrap(QFMembershipVerifiedSnapshot(status: status([
      "accessState": "IN_GRACE_PERIOD", "appleExpiresAt": "2025-12-31T23:59:00Z",
      "effectiveUntil": "2026-01-01T00:05:00Z"
    ]), binding: binding, receivedUptime: 100))
    XCTAssertTrue(snapshot.allowsAccess(for: binding, at: 101, offline: false))
    XCTAssertFalse(snapshot.allowsAccess(for: binding, at: 101, offline: true))
    XCTAssertFalse(snapshot.allowsAccess(for: binding, at: 160, offline: false))
  }

  func testUnknownExpiredRevokedAndUnscopedBenefitsNeverCreateAnAccessSnapshot() throws {
    for phase in ["UNKNOWN", "NONE", "EXPIRED", "REVOKED", "FUTURE_UNKNOWN_STATE"] {
      XCTAssertNil(QFMembershipVerifiedSnapshot(status: try status(["accessState": phase]),
        binding: binding, receivedUptime: 100))
    }
    XCTAssertNil(QFMembershipVerifiedSnapshot(status: try status(["accessEntitlements": ["BARCODE"]]),
      binding: binding, receivedUptime: 100))
  }

  func testSandboxRequiresItsOwnVerifiedSourceAndCannotBecomeProduction() throws {
    XCTAssertNil(QFMembershipVerifiedSnapshot(status: try status(["appleEnvironment": "SANDBOX"]),
      binding: binding, receivedUptime: 100))
    let snapshot = try XCTUnwrap(QFMembershipVerifiedSnapshot(status: status([
      "accessSource": "APPLE_SANDBOX", "appleEnvironment": "SANDBOX"
    ]), binding: binding, receivedUptime: 100))
    XCTAssertEqual(snapshot.status.accessSource, "APPLE_SANDBOX")
    XCTAssertTrue(snapshot.allowsAccess(for: binding, at: 101, offline: false))
  }
}
