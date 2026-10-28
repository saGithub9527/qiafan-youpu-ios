import Foundation

/// Called only after StoreKit's VerificationResult is .verified. The injected
/// effects keep the real finish-order/account fencing independently testable.
@MainActor
enum QFVerifiedAppleTransactionDelivery {
  enum Failure: Error { case unconfirmed }

  static func deliver(signedTransactionInfo: String,
    identity: QFAppleTransactionIdentity,
    isCurrent: () -> Bool,
    verify: (String) async throws -> QFMembershipStatus,
    apply: (QFMembershipStatus) throws -> Void,
    finish: () async -> Void) async throws {
    func check() throws {
      try Task.checkCancellation()
      guard isCurrent() else { throw CancellationError() }
    }
    try check()
    let receipt = try await verify(signedTransactionInfo)
    try check()
    guard receipt.contractVersion == "core-subscription-v2",
      [.active, .grace, .expired, .revoked].contains(QFMembershipAccessPhase(status: receipt)),
      let revision = receipt.revision, revision > 0,
      (receipt.accessSource == "APPLE_PRODUCTION" && receipt.appleEnvironment == "PRODUCTION")
        || (receipt.accessSource == "APPLE_SANDBOX" && receipt.appleEnvironment == "SANDBOX"),
      let accepted = receipt.acceptedTransaction,
      accepted.transactionId == identity.transactionId,
      accepted.originalTransactionId == identity.originalTransactionId,
      accepted.bundleId == identity.bundleId,
      accepted.appleEnvironment == identity.appleEnvironment,
      ["PRODUCTION", "SANDBOX"].contains(accepted.appleEnvironment),
      let now = date(receipt.serverTime), let verified = date(receipt.verifiedAt), verified <= now,
      let committed = date(accepted.acceptedAt), committed <= now else { throw Failure.unconfirmed }
    try apply(receipt)
    try check()
    await finish()
    try check()
  }

  private static func date(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let value = format.date(from: raw) { return value }
    format.formatOptions = [.withInternetDateTime]
    return format.date(from: raw)
  }
}
