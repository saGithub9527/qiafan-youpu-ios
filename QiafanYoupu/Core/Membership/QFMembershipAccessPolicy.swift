import Foundation
import Darwin

enum QFMembershipMonotonicClock {
  private static let secondsPerTick: Double = {
    var value = mach_timebase_info_data_t()
    mach_timebase_info(&value)
    return Double(value.numer) / Double(value.denom) / 1_000_000_000
  }()

  /// Includes device sleep. ProcessInfo.systemUptime can extend a paid snapshot
  /// through sleep, so it is not the clock used for financial authorization.
  static var now: TimeInterval { Double(mach_continuous_time()) * secondsPerTick }
}

/// Negative evidence is immediate only when it can be tied to this app account.
/// Callers must first require StoreKit .verified and a revocationDate.
enum QFMembershipRevocationPolicy {
  static func originalChain(_ identity: QFAppleTransactionIdentity) -> String {
    identity.bundleId + "/" + identity.appleEnvironment + "/" + identity.originalTransactionId
  }

  static func matches(identity: QFAppleTransactionIdentity, bundleId: String?, productId: String,
    appAccountToken: UUID?, context: QFMembershipPurchaseContext?, confirmedChains: Set<String>) -> Bool {
    guard identity.bundleId == bundleId else { return false }
    if confirmedChains.contains(originalChain(identity)) { return true }
    guard let context else { return false }
    return context.productIds.contains(productId) && appAccountToken == context.appAccountToken
  }
}

/// An in-memory, same-process snapshot of an authenticated server response.
/// It is never persisted as a local subscription Boolean or trusted after boot.
struct QFMembershipVerifiedSnapshot: Equatable {
  let binding: QFMembershipBinding
  let status: QFMembershipStatus
  let receivedUptime: TimeInterval
  let onlineDeadline: TimeInterval
  let offlineDeadline: TimeInterval?

  init?(status: QFMembershipStatus, binding: QFMembershipBinding,
        receivedUptime: TimeInterval, requestDuration: TimeInterval = 0) {
    let phase = QFMembershipAccessPhase(status: status)
    guard phase == .active || phase == .grace,
      (status.accessSource == "APPLE_PRODUCTION" && status.appleEnvironment == "PRODUCTION")
        || (status.accessSource == "APPLE_SANDBOX" && status.appleEnvironment == "SANDBOX"),
      status.accessEntitlements?.contains("CORE_COOKING") == true,
      let revision = status.revision, revision >= 0,
      let serverTime = Self.date(status.serverTime),
      let verifiedAt = Self.date(status.verifiedAt), verifiedAt <= serverTime,
      let effectiveUntil = Self.date(status.effectiveUntil),
      let appleExpiresAt = Self.date(status.appleExpiresAt),
      receivedUptime.isFinite, requestDuration.isFinite, requestDuration >= 0 else { return nil }
    let lifetime = (phase == .grace ? effectiveUntil.timeIntervalSince(serverTime)
      : min(effectiveUntil.timeIntervalSince(serverTime), appleExpiresAt.timeIntervalSince(serverTime)))
      - requestDuration
    guard lifetime > 0 else { return nil }
    let authorizationLifetime: TimeInterval
    if phase == .active {
      // A successful response does not prove the device stays online. Every
      // local authorization is bounded by the server's verified lease, even
      // before a transport error has been observed.
      guard let until = Self.date(status.offlineUntil) else { return nil }
      authorizationLifetime = min(900, min(lifetime, until.timeIntervalSince(serverTime) - requestDuration))
    } else {
      let freshness = 60 - serverTime.timeIntervalSince(verifiedAt) - requestDuration
      authorizationLifetime = min(lifetime, freshness)
    }
    guard authorizationLifetime > 0 else { return nil }
    self.binding = binding; self.status = status; self.receivedUptime = receivedUptime
    onlineDeadline = receivedUptime + authorizationLifetime
    offlineDeadline = phase == .active ? onlineDeadline : nil
  }

  func allowsAccess(for binding: QFMembershipBinding, at uptime: TimeInterval, offline: Bool) -> Bool {
    guard self.binding == binding, uptime.isFinite, uptime >= receivedUptime else { return false }
    guard let deadline = offline ? offlineDeadline : onlineDeadline else { return false }
    return uptime < deadline
  }

  var hasOrbSpeech: Bool { status.accessEntitlements?.contains("ORB_PROACTIVE_SPEECH") == true }

  fileprivate static func date(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

/// Authenticated, same-account in-memory lease. Never accepted as an Apple receipt.
struct QFComplimentaryAccessSnapshot {
  let binding: QFMembershipBinding
  let receivedUptime: TimeInterval
  let deadline: TimeInterval

  init?(access: QFComplimentaryAccess?, binding: QFMembershipBinding,
        receivedUptime: TimeInterval, requestDuration: TimeInterval) {
    guard let access, access.contractVersion == "provided-access-v1", access.source == "PROVIDED",
      access.revision >= 1, access.entitlements == ["CORE_COOKING"],
      let now = QFMembershipVerifiedSnapshot.date(access.serverTime),
      let expires = QFMembershipVerifiedSnapshot.date(access.expiresAt),
      let lease = QFMembershipVerifiedSnapshot.date(access.leaseUntil), lease <= expires,
      receivedUptime.isFinite, requestDuration.isFinite, requestDuration >= 0 else { return nil }
    let remaining = min(60, lease.timeIntervalSince(now)) - requestDuration
    guard remaining > 0 else { return nil }
    self.binding = binding; self.receivedUptime = receivedUptime; self.deadline = receivedUptime + remaining
  }

  func allowsAccess(for binding: QFMembershipBinding, at uptime: TimeInterval, offline: Bool) -> Bool {
    self.binding == binding && !offline && uptime.isFinite && uptime >= receivedUptime && uptime < deadline
  }
}
