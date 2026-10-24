import ActivityKit
import Combine
import CryptoKit
import Foundation
import UIKit
import WidgetKit

extension Notification.Name {
  static let qfOpenMealSurface = Notification.Name("qf.open-meal-surface")
}

/// One session owns every external meal surface. The extension receives display data, never credentials.
@MainActor
final class QFMealSurfaceCoordinator: ObservableObject {
  static let shared = QFMealSurfaceCoordinator()
  @Published private(set) var document: QFMealSurfaceDocument?
  @Published private(set) var isLoading = false
  private weak var app: QFAppSession?
  private var consent = false
  private var subscriptions = Set<AnyCancellable>()
  private var task: Task<Void, Never>?
  private var generation = UUID()
  private var scopeKey = ""
  private var lastRefresh: Date = .distantPast
  private var lastPersisted: QFMealSurfaceDocument?
  private var activityObservers: [String: Task<Void, Never>] = [:]
  private var foregroundTimer: Timer?
  private(set) var cacheAvailable = false

  func bind(to app: QFAppSession, privacyConsentAccepted: Bool) {
    self.app = app; consent = privacyConsentAccepted
    subscriptions.removeAll()
    app.$user.map { $0?.userId }.removeDuplicates().sink { [weak self] _ in
      // @Published delivers before storage changes; defer reads to the next main-actor turn.
      Task { @MainActor [weak self] in self?.refresh(force: true) }
    }.store(in: &subscriptions)
    app.$sessionRestorationCompleted.removeDuplicates().dropFirst().sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh(force: true) }
    }.store(in: &subscriptions)
    app.$planningScope.removeDuplicates().dropFirst().sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh(force: true) }
    }.store(in: &subscriptions)
    app.$interfaceLanguage.removeDuplicates().dropFirst().sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh(force: true) }
    }.store(in: &subscriptions)
    app.$userSettings.map { $0?.planReminders }.removeDuplicates().dropFirst().sink { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
      if self.app?.userSettings?.planReminders == false { self.disableImmediately() }
      else if !self.isLoading { self.refresh(force: true) }
      }
    }.store(in: &subscriptions)
    for name in [Notification.Name("qf.planningReminderDataDidChange"), .qfLocalSettingsDidChange] {
      NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
        Task { @MainActor [weak self] in self?.refresh(force: true) }
      }.store(in: &subscriptions)
    }
    NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.applicationDidBecomeActive() }
    }.store(in: &subscriptions)
    NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.foregroundTimer?.invalidate(); self?.foregroundTimer = nil }
    }.store(in: &subscriptions)
    refresh(force: true)
  }

  func privacyConsentWasAccepted() { consent = true; refresh(force: true) }

  func applicationDidBecomeActive() {
    refresh()
    // Only while foreground: cross a meal boundary without leaving a stale home card.
    foregroundTimer?.invalidate()
    foregroundTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
  }

  func refresh(force: Bool = false) {
    guard let app else { return }
    // A cold-start nil user is not a logout. Leave the last privacy gate and valid activity intact
    // until the saved session has been conclusively restored or rejected.
    guard app.user != nil || !app.sessionRestorationUnconfirmed else { return }
    let newScope = binding(app)
    if newScope != scopeKey {
      scopeKey = newScope; generation = UUID(); task?.cancel(); task = nil
      clearActivities(keepingScope: newScope)
      persist(.init(scopeKey: newScope, language: app.interfaceLanguage, updatedAt: Date(),
        status: app.user == nil ? .signedOut : .unavailable, entries: []))
      lastRefresh = .distantPast
    }
    guard consent, app.user != nil else {
      generation = UUID(); task?.cancel(); task = nil; isLoading = false
      clearActivities()
      persist(.init(scopeKey: newScope, language: app.interfaceLanguage, updatedAt: Date(), status: .signedOut, entries: []))
      return
    }
    if app.userSettings?.planReminders == false { disableImmediately(); return }
    guard force || (!isLoading && Date().timeIntervalSince(lastRefresh) >= 60) else { return }
    generation = UUID(); let request = generation; let scope = newScope
    task?.cancel(); isLoading = true
    task = Task { [weak self, weak app] in
      guard let self, let app else { return }
      do {
        try await Task.sleep(nanoseconds: 200_000_000)
        let next = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
          try await self.load(app: app, scope: scope, request: request)
        }
        guard self.current(app, scope, request) else { return }
        if app.userSettings?.planReminders == false { self.disableImmediately(); return }
        self.lastRefresh = Date(); self.isLoading = false
        self.persist(next)
        await QFMealLivePushService.shared.synchronize(document: next)
        await self.updateActivities(next, app: app, request: request)
      } catch {
        guard self.current(app, scope, request) else { return }
        self.isLoading = false; self.lastRefresh = Date()
        // Failed reads never become an empty plan or a claim that stock is sufficient.
        self.persist(.init(scopeKey: scope, language: app.interfaceLanguage, updatedAt: Date(), status: .unavailable, entries: []))
      }
    }
  }

  private func load(app: QFAppSession, scope: String, request: UUID) async throws -> QFMealSurfaceDocument {
    let now = Date(); let household = app.planningHouseholdID; let language = app.interfaceLanguage
    func check() throws { guard current(app, scope, request) else { throw CancellationError() } }
    let master = try await app.loadUserSettings(); try check()
    if !master.planReminders {
      return .init(scopeKey: scope, language: language, updatedAt: now, status: .disabled, entries: [])
    }
    let settings = try await app.reminderSettings(householdID: household); try check()
    guard settings.householdId == household else { throw Invalid.snapshot }
    guard settings.enabled else {
      return .init(scopeKey: scope, language: language, updatedAt: now, status: .disabled, entries: [])
    }
    // The fixed surfaces describe every planned meal. Per-meal push selection does not hide a dinner plan.
    let zone = settings.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
    guard let dates = QFNextMealReminderSelection.dates(now: now, timezone: zone.identifier, count: 8),
      let first = dates.first, let last = dates.last else { throw Invalid.snapshot }
    var plans: [QFPlannedMeal] = []; var complete = false
    for page in 0..<20 {
      let result = try await app.plannedMeals(startDate: first, endDate: last, page: page, householdID: household)
      try check()
      guard result.total >= 0, result.items.allSatisfy({ dates.contains($0.date) && $0.householdId == household }),
        !result.items.isEmpty || plans.count >= result.total else { throw Invalid.snapshot }
      plans += result.items
      guard Set(plans.map(\.id)).count == plans.count else { throw Invalid.snapshot }
      if plans.count >= result.total { complete = true; break }
    }
    guard complete else { throw Invalid.snapshot }
    guard Set(settings.meals.map(\.meal)).count == settings.meals.count else { throw Invalid.snapshot }
    let configured = Dictionary(uniqueKeysWithValues: settings.meals.map { ($0.meal, $0.localTime) })
    let rules = QFMealReminder.defaults.map { QFMealSurfaceProjection.Rule(meal: $0.meal, localTime: configured[$0.meal] ?? $0.localTime) }
    var entries = QFMealSurfaceProjection.entries(plans: plans.map {
      .init(id: $0.id, date: $0.date, meal: $0.meal, title: $0.title, completed: $0.completed,
        skipped: $0.skipped, contentAvailable: $0.contentAvailable)
    }, rules: rules, timezone: zone.identifier, now: now)
    if let nextDate = entries.first?.date,
      let availability = try? await app.planAvailability(date: nextDate, householdID: household) {
      try check()
      if availability.date == nextDate, availability.householdId == household,
        Set(availability.items.map(\.planId)).count == availability.items.count {
        for index in entries.indices where entries[index].date == nextDate {
          let group = plans.filter { $0.date == nextDate && $0.meal == entries[index].meal && !$0.completed && !$0.skipped }
          let items = group.compactMap { plan in availability.items.first { $0.planId == plan.id && $0.planRevision == plan.revision } }
          guard items.count == group.count, !items.isEmpty else { continue }
          let materials = items.flatMap(\.materials)
          let known = !materials.isEmpty && items.allSatisfy { ["AVAILABLE", "SHORT"].contains($0.status) }
            && materials.allSatisfy { ["AVAILABLE", "SHORT"].contains($0.status) }
          func names(_ filter: (QFPlanMaterialAvailability) -> Bool) -> [String] {
            var seen = Set<String>()
            return Array(materials.filter(filter).map { QFMealSurfaceProjection.compact($0.name) }
              .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(3))
          }
          entries[index].requiredIngredients = names { _ in true }
          entries[index].stockKnown = known
          if known {
            entries[index].inStockIngredients = names { (Decimal(string: $0.availableQuantity ?? "0") ?? 0) > 0 }
            entries[index].missingIngredients = names { $0.status == "SHORT" }
          }
        }
      }
    }
    try check()
    return .init(scopeKey: scope, language: language, updatedAt: now, status: entries.isEmpty ? .empty : .ready, entries: entries)
  }

  private func binding(_ app: QFAppSession) -> String {
    let raw = [app.contentScope, app.planningHouseholdID ?? "personal", app.interfaceLanguage].joined(separator: "\u{0}")
    return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  private func current(_ app: QFAppSession, _ scope: String, _ request: UUID) -> Bool {
    !Task.isCancelled && generation == request && binding(app) == scope && consent && app.user != nil
  }
  private enum Invalid: Error { case snapshot }

  private func persist(_ next: QFMealSurfaceDocument) {
    let previous = lastPersisted
    document = next
    // Coalesce identical refreshes, but keep the 24-hour cache lease fresh on genuine server reads.
    guard previous?.scopeKey != next.scopeKey || previous?.language != next.language || previous?.status != next.status
      || previous?.entries != next.entries || next.updatedAt.timeIntervalSince(previous?.updatedAt ?? .distantPast) >= 900 else { return }
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: QFMealSurfaceConfiguration.appGroupID) else {
      cacheAvailable = false; return
    }
    do {
      let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(next)
      try data.write(to: container.appendingPathComponent(QFMealSurfaceConfiguration.fileName), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      cacheAvailable = true
      lastPersisted = next
      WidgetCenter.shared.reloadTimelines(ofKind: QFMealSurfaceConfiguration.widgetKind)
    } catch { cacheAvailable = false }
  }

  private func disableImmediately() {
    guard let app, app.user != nil else { return }
    generation = UUID(); task?.cancel(); task = nil; isLoading = false
    let disabled = QFMealSurfaceDocument(scopeKey: binding(app), language: app.interfaceLanguage,
      updatedAt: Date(), status: .disabled, entries: [])
    persist(disabled); clearActivities()
    Task { await QFMealLivePushService.shared.synchronize(document: disabled) }
  }

  private func clearActivities(keepingScope: String? = nil) {
    activityObservers.values.forEach { $0.cancel() }; activityObservers.removeAll()
    guard #available(iOS 16.1, *) else { return }
    let captured = Activity<QFMealActivityAttributes>.activities.filter {
      #if DEBUG
      if QFMealDisplayProbe.owns($0.attributes) { return false }
      #endif
      return $0.attributes.scopeKey != keepingScope
    }
    Task { for activity in captured { await activity.end(using: nil, dismissalPolicy: .immediate) } }
  }

  private func updateActivities(_ next: QFMealSurfaceDocument, app: QFAppSession, request: UUID) async {
    guard #available(iOS 16.1, *) else { return }
    guard app.userSettings?.planReminders != false, ActivityAuthorizationInfo().areActivitiesEnabled, next.status == .ready,
      let meal = QFMealSurfaceSelector.currentEntry(in: next, now: Date()),
      meal.scheduledAt.timeIntervalSinceNow <= 4 * 3600 else { clearActivities(); return }
    let activities = Activity<QFMealActivityAttributes>.activities
    let matching = activities.first { $0.attributes.scopeKey == next.scopeKey && $0.attributes.entryID == meal.id }
    for old in activities where old.id != matching?.id {
      #if DEBUG
      if QFMealDisplayProbe.owns(old.attributes) { continue }
      #endif
      await old.end(using: nil, dismissalPolicy: .immediate)
    }
    guard current(app, next.scopeKey, request) else { return }
    if let matching {
      QFMealLivePushService.shared.observe(activity: matching)
      if #available(iOS 16.2, *) { await matching.update(ActivityContent(state: meal, staleDate: meal.expiresAt)) }
      else { await matching.update(using: meal) }
      return
    }
    // A dismissed activity is not re-created for the same meal on every foreground refresh.
    guard !QFMealActivityStartHistory.contains(scope: next.scopeKey, entryID: meal.id) else { return }
    do {
      let attributes = QFMealActivityAttributes(scopeKey: next.scopeKey, entryID: meal.id)
      if #available(iOS 16.2, *) {
        let activity = try Activity.request(attributes: attributes, content: ActivityContent(state: meal, staleDate: meal.expiresAt), pushType: .token)
        QFMealLivePushService.shared.observe(activity: activity)
      } else {
        let activity = try Activity.request(attributes: attributes, contentState: meal, pushType: .token)
        QFMealLivePushService.shared.observe(activity: activity)
      }
      QFMealActivityStartHistory.record(scope: next.scopeKey, entryID: meal.id)
    } catch {
      // System denial, foreground restrictions or the activity budget do not erase the home/widget data.
    }
  }
}


/// Retain a validated cold-start route through onboarding/login; it never performs a business write.
@MainActor
final class QFMealSurfaceNavigation: ObservableObject {
  static let shared = QFMealSurfaceNavigation()
  @Published private(set) var pending: QFMealSurfaceRoute?
  func open(_ url: URL) {
    guard url.absoluteString.utf8.count <= 512, let route = QFMealSurfaceRoute(url: url) else { return }
    pending = route
  }
  func consume() { pending = nil }
}
