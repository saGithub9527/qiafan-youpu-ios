import Combine
import Foundation
import StoreKit

/// StoreKit delivers purchases; only the authenticated V2 server response grants access.
/// All operations share one queue, and every await is fenced by the login generation.
@MainActor
final class QFStoreKitCoordinator: ObservableObject {
  enum Issue: Equatable { case unavailable, unverified, conflict, pending, productsUnavailable }
  @Published private(set) var status: QFMembershipStatus?
  @Published private(set) var products: [Product] = []
  @Published private(set) var isBusy = false
  @Published private(set) var issue: Issue?
  @Published private(set) var accessRevision = 0

  private weak var app: QFAppSession?
  private var binding: QFMembershipBinding?
  private var context: QFMembershipPurchaseContext?
  private var snapshot: QFMembershipVerifiedSnapshot?
  private var offline = false
  private var recoveredLocalTransactions = false
  private var pendingPurchase = false
  private var accessEpoch = 0
  private var authorizationRefreshQueued = false
  private var confirmedOriginalChains = Set<String>()
  private var pendingUpdateKeys = Set<String>()
  private var listener: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  private var operationID: UUID?
  private var expiry: Task<Void, Never>?

  init(app: QFAppSession) { self.app = app }
  deinit { listener?.cancel(); operation?.cancel(); expiry?.cancel() }

  var hasBusinessAccess: Bool {
    guard let app, app.user != nil, let snapshot else { return false }
    return snapshot.allowsAccess(for: app.membershipBinding,
      at: QFMembershipMonotonicClock.now, offline: offline)
  }
  var hasOrbSpeech: Bool { hasBusinessAccess && snapshot?.hasOrbSpeech == true }
  var canPurchase: Bool {
    guard !isBusy, issue == nil, !pendingPurchase, recoveredLocalTransactions,
      context != nil, products.count == 2, !hasBusinessAccess else { return false }
    return [.none, .expired, .revoked].contains(QFMembershipAccessPhase(status: status))
  }

  func activate() {
    guard let app, app.user != nil else { reset(); return }
    if binding != app.membershipBinding {
      reset(); binding = app.membershipBinding
      let expected = app.membershipBinding
      listener = Task { [weak self] in
        for await result in Transaction.updates {
          guard let self, !Task.isCancelled, self.isCurrent(expected) else { return }
          self.invalidateKnownRevocation(result, binding: expected)
          let key: String
          if case .verified(let transaction) = result {
            key = String(transaction.id) + "/" + String(transaction.signedDate.timeIntervalSince1970)
              + "/" + String(transaction.revocationDate?.timeIntervalSince1970 ?? -1)
          } else { key = "unverified-update" }
          guard self.pendingUpdateKeys.insert(key).inserted else { continue }
          self.enqueue { coordinator in
            defer { if coordinator.binding == expected { coordinator.pendingUpdateKeys.remove(key) } }
            try await coordinator.accept(result, binding: expected)
          }
        }
      }
      refresh()
    }
  }

  func reset() {
    accessEpoch += 1; authorizationRefreshQueued = false
    listener?.cancel(); listener = nil
    operation?.cancel(); operation = nil; operationID = nil
    expiry?.cancel(); expiry = nil
    binding = nil; context = nil; snapshot = nil; offline = false
    confirmedOriginalChains.removeAll()
    pendingUpdateKeys.removeAll()
    status = nil; products = []; recoveredLocalTransactions = false
    pendingPurchase = false; issue = nil; isBusy = false; accessRevision += 1
  }

  func resetIfBound() { if binding != nil { reset() } }

  func refresh() {
    guard let binding, operation == nil else { return }
    enqueue { coordinator in try await coordinator.reconcile(binding: binding, restore: false) }
  }

  func foreground() {
    if snapshot != nil, !hasBusinessAccess {
      snapshot = nil; expiry?.cancel(); expiry = nil; accessRevision += 1
    }
    refresh()
  }

  func restore() {
    guard let binding, operation == nil else { return }
    enqueue { coordinator in try await coordinator.reconcile(binding: binding, restore: true) }
  }

  func purchase(_ product: Product) {
    guard canPurchase, let binding, let context,
      products.contains(where: { $0.id == product.id }) else { return }
    enqueue { coordinator in
      try coordinator.check(binding)
      // This token comes from the signed-in service account, never a client-generated UUID.
      let result = try await product.purchase(options: [.appAccountToken(context.appAccountToken)])
      try coordinator.check(binding)
      switch result {
      case .success(let verification):
        try await coordinator.accept(verification, binding: binding)
        try await coordinator.reconcile(binding: binding, restore: false)
      case .pending: coordinator.pendingPurchase = true; coordinator.issue = .pending
      case .userCancelled: break
      @unknown default: coordinator.issue = .unavailable
      }
    }
  }

  /// A direct business 403 is authoritative now; an old cached snapshot cannot override it.
  func rejectBusinessAccess() {
    accessEpoch += 1
    snapshot = nil; recoveredLocalTransactions = false
    expiry?.cancel(); expiry = nil; issue = .unavailable; accessRevision += 1
    guard let expected = binding, !authorizationRefreshQueued else { return }
    authorizationRefreshQueued = true
    enqueue { coordinator in
      coordinator.authorizationRefreshQueued = false
      try await coordinator.reconcile(binding: expected, restore: false)
    }
  }

  private func enqueue(_ work: @escaping @MainActor (QFStoreKitCoordinator) async throws -> Void) {
    let previous = operation
    let id = UUID(), expected = binding
    operationID = id; isBusy = true
    operation = Task { [weak self] in
      await previous?.value
      guard let self, !Task.isCancelled, self.binding == expected else { return }
      do { try await work(self) }
      catch is CancellationError { }
      catch {
        guard self.binding == expected else { return }
        self.handle(error)
      }
      guard self.operationID == id else { return }
      self.operation = nil; self.operationID = nil; self.isBusy = false
      self.accessRevision += 1
    }
  }

  private func reconcile(binding: QFMembershipBinding, restore: Bool) async throws {
    try check(binding)
    issue = nil; recoveredLocalTransactions = false
    if restore { try await AppStore.sync(); try check(binding) }
    let initial = try await readStatus(binding)
    guard let app else { throw CancellationError() }
    let ids = Set(initial.productIds)
    var processed = Set<UInt64>()
    // A server NONE does not mean the Apple Account has no recoverable purchase.
    // Any verification/binding error aborts this pass before exposing a buy button.
    for await result in Transaction.currentEntitlements {
      try check(binding)
      let transaction = try verified(result)
      guard transaction.productType == .autoRenewable,
        ids.isEmpty || ids.contains(transaction.productID) else { continue }
      try await accept(result, binding: binding)
      processed.insert(transaction.id)
    }
    for await result in Transaction.unfinished {
      try check(binding)
      let transaction = try verified(result)
      guard transaction.productType == .autoRenewable,
        ids.isEmpty || ids.contains(transaction.productID), !processed.contains(transaction.id) else { continue }
      try await accept(result, binding: binding)
    }
    try check(binding)
    if !processed.isEmpty || QFMembershipAccessPhase(status: initial) == .unknown {
      _ = try await readStatus(binding)
    }
    guard QFMembershipAccessPhase(status: status) != .unknown else { throw Failure.unavailable }
    recoveredLocalTransactions = true
    // Closing new sales must not prevent a subscriber from recovering a paid chain.
    let purchaseContext: QFMembershipPurchaseContext
    do {
      purchaseContext = try await app.contentRequest(path: "me/membership/apple/purchase-context", method: "POST")
    } catch {
      try check(binding)
      context = nil; products = []; issue = .productsUnavailable; return
    }
    try check(binding)
    guard purchaseContext.contractVersion == "core-subscription-v2",
      Set(purchaseContext.productIds).count == 2 else {
      context = nil; products = []; issue = .productsUnavailable; return
    }
    context = purchaseContext
    let loaded: [Product]
    do { loaded = try await Product.products(for: purchaseContext.productIds) }
    catch {
      try check(binding)
      products = []; issue = .productsUnavailable; return
    }
    try check(binding)
    guard Self.validCatalog(loaded, context: purchaseContext) else {
      products = []; issue = .productsUnavailable; return
    }
    products = loaded.sorted { ($0.subscription?.subscriptionPeriod.unit == .month ? 0 : 1)
      < ($1.subscription?.subscriptionPeriod.unit == .month ? 0 : 1) }
    if pendingPurchase { issue = .pending }
  }

  static func validCatalog(_ products: [Product], context: QFMembershipPurchaseContext) -> Bool {
    guard products.count == 2, Set(products.map(\.id)) == Set(context.productIds),
      products.allSatisfy({ $0.type == .autoRenewable && $0.subscription != nil && !$0.isFamilyShareable }) else { return false }
    let subscriptions = products.compactMap(\.subscription)
    let groups = Set(subscriptions.map(\.subscriptionGroupID))
    guard groups.count == 1, let group = groups.first, !group.isEmpty,
      context.subscriptionGroupId == nil || context.subscriptionGroupId == group else { return false }
    return subscriptions.contains { $0.subscriptionPeriod.unit == .month && $0.subscriptionPeriod.value == 1 }
      && subscriptions.contains { $0.subscriptionPeriod.unit == .year && $0.subscriptionPeriod.value == 1 }
  }

  @discardableResult
  private func readStatus(_ binding: QFMembershipBinding) async throws -> QFMembershipStatus {
    try check(binding)
    guard let app else { throw CancellationError() }
    let start = QFMembershipMonotonicClock.now
    let epoch = accessEpoch
    let value: QFMembershipStatus = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
      try await app.contentRequest(path: "me/membership")
    }
    try check(binding)
    guard epoch == accessEpoch else { throw CancellationError() }
    apply(value, binding: binding, startedAt: start)
    return value
  }

  private func accept(_ result: VerificationResult<Transaction>, binding: QFMembershipBinding) async throws {
    try check(binding)
    let transaction = try verified(result)
    guard transaction.productType == .autoRenewable else { return }
    if let context {
      guard context.productIds.contains(transaction.productID) else { return }
      if let token = transaction.appAccountToken, token != context.appAccountToken { throw Failure.conflict }
    }
    invalidateKnownRevocation(result, binding: binding)
    guard let app else { throw CancellationError() }
    let start = QFMembershipMonotonicClock.now
    let epoch = accessEpoch
    let identity = Self.identity(transaction)
    try await QFVerifiedAppleTransactionDelivery.deliver(signedTransactionInfo: result.jwsRepresentation,
      identity: identity,
      isCurrent: { self.isCurrent(binding) && self.accessEpoch == epoch }, verify: { payload in
        let body = try JSONEncoder().encode(SignedTransaction(signedTransactionInfo: payload))
        return try await app.contentRequest(path: "me/membership/apple/transactions", method: "POST", body: body)
      }, apply: { value in
        self.confirmedOriginalChains.insert(QFMembershipRevocationPolicy.originalChain(identity))
        self.apply(value, binding: binding, startedAt: start)
      }, finish: { await transaction.finish() })
    // A verified revocation may legitimately return REVOKED. A successful committed
    // server response, not an optimistic local entitlement, acknowledges delivery.
    try check(binding)
    pendingPurchase = false; issue = nil
  }

  private func invalidateKnownRevocation(_ result: VerificationResult<Transaction>, binding: QFMembershipBinding) {
    guard isCurrent(binding), case .verified(let transaction) = result,
      transaction.revocationDate != nil, transaction.productType == .autoRenewable else { return }
    let identity = Self.identity(transaction)
    guard QFMembershipRevocationPolicy.matches(identity: identity, bundleId: Bundle.main.bundleIdentifier,
      productId: transaction.productID, appAccountToken: transaction.appAccountToken,
      context: context, confirmedChains: confirmedOriginalChains) else { return }
    // This runs immediately in the updates listener, before waiting for a slow
    // purchase/restore operation. A foreign account's old transaction cannot do it.
    accessEpoch += 1
    snapshot = nil; expiry?.cancel(); expiry = nil; accessRevision += 1
  }

  private static func identity(_ transaction: Transaction) -> QFAppleTransactionIdentity {
    let environment: String
    if #available(iOS 16.0, *) { environment = transaction.environment.rawValue.uppercased() }
    else { environment = transaction.environmentStringRepresentation.uppercased() }
    return QFAppleTransactionIdentity(transactionId: String(transaction.id),
      originalTransactionId: String(transaction.originalID), bundleId: transaction.appBundleID,
      appleEnvironment: environment)
  }

  private func apply(_ value: QFMembershipStatus, binding: QFMembershipBinding, startedAt: TimeInterval) {
    // revision belongs to the selected original chain, not to the whole account.
    // A legitimate new chain may start at 1 after an older chain reached 20.
    // Queue ordering, accessEpoch and login generation fence stale responses.
    let now = QFMembershipMonotonicClock.now
    status = value; offline = false
    snapshot = QFMembershipVerifiedSnapshot(status: value, binding: binding,
      receivedUptime: now, requestDuration: max(0, now - startedAt))
    accessRevision += 1
    scheduleExpiry()
  }

  private func scheduleExpiry() {
    expiry?.cancel(); expiry = nil
    guard let snapshot, let expected = binding else { return }
    let deadline = offline ? (snapshot.offlineDeadline ?? snapshot.receivedUptime) : snapshot.onlineDeadline
    let delay = max(0, deadline - QFMembershipMonotonicClock.now)
    guard delay > 0 else { return }
    expiry = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: UInt64(min(900, delay) * 1_000_000_000)) }
      catch { return }
      guard let self, self.isCurrent(expected) else { return }
      self.accessRevision += 1
      self.refresh()
    }
  }

  private func handle(_ error: Error) {
    recoveredLocalTransactions = false
    if (error as? QFAPIError)?.code == 40904 || (error as? Failure) == .conflict {
      issue = .conflict
    } else if (error as? Failure) == .unverified { issue = .unverified }
    else { issue = .unavailable }
    // Only transport failure can reuse a still-valid same-process offline proof.
    // A server refusal/UNKNOWN never becomes permission to buy or to keep stale access.
    let transport = error is URLError
    offline = transport
    if !transport || snapshot?.allowsAccess(for: binding ?? QFMembershipBinding(scope: "", generation: -1),
      at: QFMembershipMonotonicClock.now, offline: true) != true { snapshot = nil }
    scheduleExpiry(); accessRevision += 1
  }

  private func verified(_ result: VerificationResult<Transaction>) throws -> Transaction {
    switch result {
    case .verified(let transaction): return transaction
    case .unverified: throw Failure.unverified
    }
  }
  private func isCurrent(_ binding: QFMembershipBinding) -> Bool {
    app?.user != nil && self.binding == binding && app?.membershipBinding == binding
  }
  private func check(_ binding: QFMembershipBinding) throws {
    try Task.checkCancellation()
    guard isCurrent(binding) else { throw CancellationError() }
  }
  private enum Failure: Error, Equatable { case unavailable, unverified, conflict }
  private struct SignedTransaction: Encodable { let signedTransactionInfo: String }
}
