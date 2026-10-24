import ActivityKit
import Combine
import CryptoKit
import Foundation

private struct QFMealLiveDeviceDraft: Encodable {
  let householdId: String?
  let scopeKey: String
  let environment: String
  let enabled: Bool
  let startToken: String?
  let clientSequence: Int64
}

private struct QFMealLiveActivityDraft: Encodable, Equatable {
  let scopeKey: String
  let entryId: String
  let planId: String
  let pushToken: String?
  let dismissed: Bool
}

private struct QFMealLiveReceipt: Decodable {
  let status: String
  let clientSequence: Int64
}

@MainActor
private extension QFAppSession {
  func registerMealLiveDevice(_ id: String, draft: QFMealLiveDeviceDraft) async throws -> QFMealLiveReceipt {
    try await contentRequest(path: "me/meal-surfaces/devices/\(id)", method: "PUT", body: JSONEncoder().encode(draft))
  }

  func registerMealLiveActivity(_ device: String, activity: String, draft: QFMealLiveActivityDraft) async throws -> QFMealLiveReceipt {
    try await contentRequest(path: "me/meal-surfaces/devices/\(device)/activities/\(activity)", method: "PUT", body: JSONEncoder().encode(draft))
  }

  func deleteMealLiveDevice(_ id: String) async throws {
    try await contentMutation(path: "me/meal-surfaces/devices/\(id)", method: "DELETE")
  }
}

/// One authenticated account owns these observers. Push tokens remain in memory and authenticated requests only.
@MainActor
final class QFMealLivePushService {
  static let shared = QFMealLivePushService()
  private static let sequenceKey = "qf.meal-live-push.client-sequence.v1"
  private static let leaseRefresh: TimeInterval = 6 * 60 * 60

  private struct Binding: Equatable {
    let user: String
    let server: String
    let contentScope: String
    let household: String?
    let language: String
    let scopeKey: String
    let consent: Bool
  }
  private struct Intent: Equatable {
    let household: String?
    let scopeKey: String
    let environment: String
    let enabled: Bool
    let startToken: String?
    func draft(sequence: Int64) -> QFMealLiveDeviceDraft {
      .init(householdId: household, scopeKey: scopeKey, environment: environment,
            enabled: enabled, startToken: startToken, clientSequence: sequence)
    }
  }
  private struct Lease {
    let intent: Intent
    let sequence: Int64
    let registeredAt: Date
  }

  private weak var app: QFAppSession?
  private let identity = QFDeviceIdentity()
  private var privacyConsentAccepted = false
  private var subscriptions = Set<AnyCancellable>()
  private var generation = UUID()
  private var binding: Binding?
  private var closingBinding: Binding?
  private var document: QFMealSurfaceDocument?
  private var intent: Intent?
  private var lease: Lease?
  private var pendingDeviceWrite: (intent: Intent, sequence: Int64)?
  private var startToken: String?
  private var flushTask: Task<Void, Never>?
  private var startObserver: Task<Void, Never>?
  private var activityObserver: Task<Void, Never>?
  private var authorizationObserver: Task<Void, Never>?
  private var activityTasks: [String: [Task<Void, Never>]] = [:]
  private var pendingActivities: [String: QFMealLiveActivityDraft] = [:]
  private var acknowledgedActivities: [String: QFMealLiveActivityDraft] = [:]
  private var nextAttemptAt = Date.distantPast

  private init() {}

  func bind(app: QFAppSession, privacyConsentAccepted: Bool) {
    let replaced = self.app !== app || self.privacyConsentAccepted != privacyConsentAccepted
    self.app = app
    self.privacyConsentAccepted = privacyConsentAccepted
    subscriptions.removeAll()
    app.$user.map { $0?.userId }.removeDuplicates().sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.reconcileBinding() }
    }.store(in: &subscriptions)
    app.$planningScope.removeDuplicates().dropFirst().sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.reconcileBinding() }
    }.store(in: &subscriptions)
    app.$interfaceLanguage.removeDuplicates().dropFirst().sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.reconcileBinding() }
    }.store(in: &subscriptions)
    app.$userSettings.map { $0?.planReminders }.removeDuplicates().dropFirst().sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.updateIntent() }
    }.store(in: &subscriptions)
    reconcileBinding(force: replaced)
  }

  /// Enqueues bounded network work; the coordinator does not wait for token registration to render its surfaces.
  func synchronize(document: QFMealSurfaceDocument) async {
    reconcileBinding()
    guard let binding, document.schemaVersion == 1, document.scopeKey == binding.scopeKey,
      document.language == binding.language else { return }
    self.document = document
    updateIntent()
  }

  @available(iOS 16.1, *)
  func observe(activity: Activity<QFMealActivityAttributes>) {
    #if DEBUG
    if QFMealDisplayProbe.owns(activity.attributes) { return }
    #endif
    reconcileBinding()
    guard let binding, binding.consent, activity.attributes.scopeKey == binding.scopeKey,
      validActivityID(activity.id) else { return }
    let initialState: QFMealSurfaceEntry
    if #available(iOS 16.2, *) { initialState = activity.content.state }
    else { initialState = activity.contentState }
    if initialState.id == activity.attributes.entryID, QFMealSurfaceSelector.isValid(initialState) {
      QFMealActivityStartHistory.record(scope: binding.scopeKey, entryID: initialState.id)
    }
    guard activityTasks[activity.id] == nil, activity.activityState != .dismissed, activity.activityState != .ended else { return }
    let captured = generation
    if let token = activity.pushToken { stage(activity: activity, token: hex(token), dismissed: false) }
    let tokens = Task { [weak self] in
      for await value in activity.pushTokenUpdates {
        guard let self, self.current(binding, captured), !Task.isCancelled else { return }
        self.stage(activity: activity, token: self.hex(value), dismissed: false)
      }
    }
    let states = Task { [weak self] in
      for await state in activity.activityStateUpdates {
        guard let self, self.current(binding, captured), !Task.isCancelled else { return }
        if state == .dismissed || state == .ended {
          self.stage(activity: activity, token: nil, dismissed: true)
          self.activityTasks.removeValue(forKey: activity.id)?.forEach { $0.cancel() }
          return
        }
      }
    }
    activityTasks[activity.id] = [tokens, states]
  }

  /// Must be called before the original session is revoked. A nil/new account never deletes an old account's row.
  func unregisterBeforeSignOut() async {
    guard let app, let original = makeBinding(), let device = try? identity.deviceID() else { return }
    reset()
    closingBinding = original
    let captured = generation
    for attempt in 0...2 {
      guard generation == captured, self.app === app, makeBinding() == original, !Task.isCancelled else { return }
      do { try await app.deleteMealLiveDevice(device); return }
      catch {
        guard attempt < 2, retryable(error), !Task.isCancelled else { return }
        do { try await Task.sleep(nanoseconds: attempt == 0 ? 1_000_000_000 : 3_000_000_000) }
        catch { return }
      }
    }
  }

  func signOutDidFail() {
    closingBinding = nil
    reconcileBinding(force: true)
    QFMealSurfaceCoordinator.shared.refresh(force: true)
  }

  #if DEBUG
  /// Metadata only. Never export ActivityKit capability tokens, account IDs or meal content.
  func diagnosticStatus() -> [String: Any] {
    var result: [String: Any] = ["bindingReady": binding != nil, "documentStatus": document?.status.rawValue ?? "none",
      "deviceLeaseRegistered": lease != nil, "deviceLeaseEnabled": lease?.intent.enabled ?? false,
      "startTokenAvailable": startToken != nil, "pendingActivityCount": pendingActivities.count,
      "acknowledgedActivityCount": acknowledgedActivities.count, "registrationRunning": flushTask != nil]
    if #available(iOS 16.1, *) {
      result["liveActivitiesEnabled"] = ActivityAuthorizationInfo().areActivitiesEnabled
      result["activeActivityCount"] = Activity<QFMealActivityAttributes>.activities.count
    }
    if #available(iOS 17.2, *) { result["remoteStartSupported"] = true }
    else { result["remoteStartSupported"] = false }
    return result
  }
  #endif

  private func makeBinding() -> Binding? {
    guard let app, let user = app.user?.userId else { return nil }
    let raw = [app.contentScope, app.planningHouseholdID ?? "personal", app.interfaceLanguage].joined(separator: "\u{0}")
    let hash = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    return .init(user: user, server: app.api.environment.name, contentScope: app.contentScope,
                 household: app.planningHouseholdID, language: app.interfaceLanguage, scopeKey: hash, consent: privacyConsentAccepted)
  }

  private func reconcileBinding(force: Bool = false) {
    let next = makeBinding()
    // A concurrent surface refresh must not re-enable a channel while logout is disabling it.
    if let closingBinding, next == closingBinding { return }
    closingBinding = nil
    if force || next != binding {
      reset()
      binding = next
    }
    guard let next else { return } // Restoration/user=nil is not permission to DELETE with another session.
    if #available(iOS 16.1, *), next.consent { startObservers(binding: next) }
    if !next.consent { updateIntent() }
  }

  private func reset() {
    generation = UUID()
    flushTask?.cancel(); flushTask = nil
    startObserver?.cancel(); startObserver = nil
    activityObserver?.cancel(); activityObserver = nil
    authorizationObserver?.cancel(); authorizationObserver = nil
    activityTasks.values.flatMap { $0 }.forEach { $0.cancel() }; activityTasks.removeAll()
    binding = nil; document = nil; intent = nil; lease = nil; pendingDeviceWrite = nil
    startToken = nil; pendingActivities.removeAll(); acknowledgedActivities.removeAll()
    nextAttemptAt = .distantPast
  }

  private func current(_ expected: Binding, _ captured: UUID) -> Bool {
    !Task.isCancelled && generation == captured && binding == expected && makeBinding() == expected
  }

  private func updateIntent() {
    guard let binding, makeBinding() == binding else { return }
    let enabled: Bool
    if !binding.consent || document?.status == .disabled || document?.status == .signedOut
      || app?.userSettings?.planReminders == false {
      enabled = false
    } else {
      guard let document, document.scopeKey == binding.scopeKey else { return }
      // An unavailable cold-start read is not evidence that the account enabled this feature.
      guard document.status == .ready || document.status == .empty || app?.userSettings?.planReminders == true else { return }
      if #available(iOS 16.1, *) { enabled = ActivityAuthorizationInfo().areActivitiesEnabled }
      else { enabled = false }
    }
    #if DEBUG
    let environment = "SANDBOX"
    #else
    let environment = "PRODUCTION"
    #endif
    let next = Intent(household: binding.household, scopeKey: binding.scopeKey,
                      environment: environment, enabled: enabled, startToken: enabled ? startToken : nil)
    if next != intent { pendingDeviceWrite = nil; nextAttemptAt = .distantPast }
    intent = next
    scheduleFlush()
  }

  @available(iOS 16.1, *)
  private func startObservers(binding: Binding) {
    let captured = generation
    if authorizationObserver == nil {
      authorizationObserver = Task { [weak self] in
        for await _ in ActivityAuthorizationInfo().activityEnablementUpdates {
          guard let self, self.current(binding, captured), !Task.isCancelled else { return }
          self.updateIntent()
        }
      }
    }
    if activityObserver == nil {
      activityObserver = Task { [weak self] in
        for await activity in Activity<QFMealActivityAttributes>.activityUpdates {
          guard let self, self.current(binding, captured), !Task.isCancelled else { return }
          self.observe(activity: activity)
        }
      }
      for activity in Activity<QFMealActivityAttributes>.activities { observe(activity: activity) }
    }
    if #available(iOS 17.2, *), startObserver == nil {
      if let value = Activity<QFMealActivityAttributes>.pushToStartToken {
        let encoded = hex(value)
        if validToken(encoded) { startToken = encoded }
      }
      startObserver = Task { [weak self] in
        for await value in Activity<QFMealActivityAttributes>.pushToStartTokenUpdates {
          guard let self, self.current(binding, captured), !Task.isCancelled else { return }
          let encoded = self.hex(value)
          guard self.validToken(encoded) else { continue }
          self.startToken = encoded
          self.updateIntent()
        }
      }
    }
  }

  @available(iOS 16.1, *)
  private func stage(activity: Activity<QFMealActivityAttributes>, token: String?, dismissed: Bool) {
    guard let binding, binding.consent, makeBinding() == binding,
      activity.attributes.scopeKey == binding.scopeKey else { return }
    let state: QFMealSurfaceEntry
    if #available(iOS 16.2, *) { state = activity.content.state }
    else { state = activity.contentState }
    guard state.id == activity.attributes.entryID, QFMealSurfaceSelector.isValid(state),
      validActivityID(activity.id), token == nil || validToken(token!), dismissed || token != nil else { return }
    let draft = QFMealLiveActivityDraft(scopeKey: binding.scopeKey, entryId: state.id, planId: state.planID,
                                       pushToken: token, dismissed: dismissed)
    if acknowledgedActivities[activity.id]?.dismissed == true { return }
    if pendingActivities[activity.id] != draft {
      pendingActivities[activity.id] = draft
      nextAttemptAt = .distantPast
    }
    scheduleFlush()
  }

  private func scheduleFlush() {
    guard flushTask == nil, let binding, intent != nil, Date() >= nextAttemptAt else { return }
    let captured = generation
    flushTask = Task { [weak self] in
      guard let self else { return }
      await self.flush(binding: binding, captured: captured)
      guard self.generation == captured else { return }
      self.flushTask = nil
    }
  }

  private func flush(binding: Binding, captured: UUID) async {
    guard let app, let device = try? identity.deviceID(), UUID(uuidString: device) != nil else { return }
    while current(binding, captured), let desired = intent {
      let needsDevice = lease?.intent != desired || Date().timeIntervalSince(lease?.registeredAt ?? .distantPast) >= Self.leaseRefresh
      if needsDevice {
        let sequence: Int64
        if let pendingDeviceWrite, pendingDeviceWrite.intent == desired { sequence = pendingDeviceWrite.sequence }
        else {
          guard let next = nextSequence() else { return }
          sequence = next; pendingDeviceWrite = (desired, sequence)
        }
        let receipt: QFMealLiveReceipt? = await retry(binding: binding, captured: captured) {
          try await app.registerMealLiveDevice(device, draft: desired.draft(sequence: sequence))
        }
        guard current(binding, captured) else { return }
        guard let receipt else { nextAttemptAt = Date().addingTimeInterval(60); return }
        guard intent == desired else { continue }
        guard receipt.clientSequence == sequence,
          [desired.enabled ? "REGISTERED" : "DISABLED", "UNCHANGED"].contains(receipt.status) else {
          advanceSequence(to: receipt.clientSequence)
          pendingDeviceWrite = nil; lease = nil; nextAttemptAt = Date().addingTimeInterval(60); return
        }
        lease = .init(intent: desired, sequence: sequence, registeredAt: Date())
        pendingDeviceWrite = nil
      }
      guard current(binding, captured), intent == desired, desired.enabled, let currentLease = lease else { return }
      guard let candidate = pendingActivities.sorted(by: { $0.key < $1.key }).first(where: { acknowledgedActivities[$0.key] != $0.value }) else { return }
      let activity = candidate.key; let draft = candidate.value
      let receipt: QFMealLiveReceipt? = await retry(binding: binding, captured: captured) {
        try await app.registerMealLiveActivity(device, activity: activity, draft: draft)
      }
      guard current(binding, captured) else { return }
      guard let receipt else { nextAttemptAt = Date().addingTimeInterval(60); return }
      guard intent == desired, lease?.sequence == currentLease.sequence else { continue }
      if receipt.clientSequence == currentLease.sequence, receipt.status == "DISMISSED" {
        let terminal = QFMealLiveActivityDraft(scopeKey: draft.scopeKey, entryId: draft.entryId,
          planId: draft.planId, pushToken: nil, dismissed: true)
        QFMealActivityStartHistory.record(scope: draft.scopeKey, entryID: draft.entryId)
        acknowledgedActivities[activity] = terminal
        pendingActivities.removeValue(forKey: activity)
        if #available(iOS 16.1, *), let live = Activity<QFMealActivityAttributes>.activities.first(where: {
          $0.id == activity && $0.attributes.scopeKey == draft.scopeKey
        }) { await live.end(using: nil, dismissalPolicy: .immediate) }
        continue
      }
      guard receipt.clientSequence == currentLease.sequence,
        receipt.status == (draft.dismissed ? "DISMISSED" : "ACTIVE") else {
        advanceSequence(to: receipt.clientSequence); pendingDeviceWrite = nil; lease = nil
        nextAttemptAt = Date().addingTimeInterval(60); return
      }
      acknowledgedActivities[activity] = draft
      // A newer token/state staged during this await is still pending and is sent next.
    }
  }

  private func retry<Value>(binding: Binding, captured: UUID, operation: () async throws -> Value) async -> Value? {
    for attempt in 0...2 {
      guard current(binding, captured) else { return nil }
      do { return try await operation() }
      catch {
        guard current(binding, captured), attempt < 2, retryable(error) else { return nil }
        do { try await Task.sleep(nanoseconds: attempt == 0 ? 1_000_000_000 : 3_000_000_000) }
        catch { return nil }
      }
    }
    return nil
  }

  private func retryable(_ error: Error) -> Bool {
    if error is CancellationError { return false }
    if let error = error as? QFAPIError { return error.code >= 50000 || error.code == 42900 }
    if let error = error as? URLError { return error.code != .cancelled && error.code != .userAuthenticationRequired }
    return false
  }

  private func nextSequence() -> Int64? {
    let defaults = UserDefaults.standard
    let previous = (defaults.object(forKey: Self.sequenceKey) as? NSNumber)?.int64Value ?? 0
    guard previous < Int64.max else { return nil }
    let now = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    let value = max(now, previous + 1)
    defaults.set(NSNumber(value: value), forKey: Self.sequenceKey)
    return value
  }

  private func advanceSequence(to value: Int64) {
    let defaults = UserDefaults.standard
    let previous = (defaults.object(forKey: Self.sequenceKey) as? NSNumber)?.int64Value ?? 0
    if value > previous { defaults.set(NSNumber(value: value), forKey: Self.sequenceKey) }
  }

  private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
  private func validToken(_ value: String) -> Bool {
    (64...256).contains(value.utf8.count) && value.utf8.count % 2 == 0
      && value.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil
  }
  private func validActivityID(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z0-9-]{1,128}$", options: .regularExpression) != nil
  }
}
