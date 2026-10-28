import Foundation

/// Original seven fields remain readable. Missing V2 evidence is UNKNOWN,
/// never an implicit upgrade of historical TEST/legacy benefits.
struct QFMembershipStatus: Decodable, Equatable, Sendable {
  let launchState: String
  let activeSubscription: Bool
  let productIds: [String]
  let benefitsActive: Bool?
  let entitlementSource: String?
  let expiresAt: String?
  let entitlements: [String]?
  let contractVersion: String?
  let accessState: String?
  let accessSource: String?
  let appleEnvironment: String?
  let verifiedAt: String?
  let serverTime: String?
  let effectiveUntil: String?
  let appleExpiresAt: String?
  let offlineUntil: String?
  let revision: Int64?
  let accessEntitlements: [String]?
  /// Only transaction sync attaches this committed, transaction-specific receipt.
  let acceptedTransaction: QFAppleAcceptedTransaction?

  var isTestAccess: Bool { benefitsActive == true && entitlementSource == "TEST" }
}

struct QFAppleAcceptedTransaction: Decodable, Equatable, Sendable {
  let transactionId: String
  let originalTransactionId: String
  let bundleId: String
  let appleEnvironment: String
  let acceptedAt: String
}

struct QFAppleTransactionIdentity: Equatable, Sendable {
  let transactionId: String
  let originalTransactionId: String
  let bundleId: String
  let appleEnvironment: String
}

struct QFMembershipPurchaseContext: Decodable, Sendable {
  let contractVersion: String
  let appAccountToken: UUID
  let productIds: [String]
  let subscriptionGroupId: String?
  let serverTime: String
}

struct QFMembershipBinding: Equatable, Sendable {
  /// API deployment/account namespace, not Apple's transaction environment.
  let scope: String
  let generation: Int
}

enum QFMembershipAccessPhase: String, Sendable {
  case unknown = "UNKNOWN", none = "NONE", active = "ACTIVE"
  case grace = "IN_GRACE_PERIOD", expired = "EXPIRED", revoked = "REVOKED"

  init(status: QFMembershipStatus?) {
    guard let status, status.contractVersion == "core-subscription-v2",
      let raw = status.accessState, let value = Self(rawValue: raw) else {
      self = .unknown; return
    }
    self = value
  }
}
