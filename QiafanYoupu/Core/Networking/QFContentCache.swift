import Foundation

enum QFContentLoadingContext {
  @TaskLocal static var forceRefresh = false
  @TaskLocal static var language: String?
}

/// Small account-scoped response cache. Mutations invalidate only related read models.
@MainActor
final class QFContentCache {
  private final class Entry: NSObject {
    let value: Any
    let expiry: Date
    let byteCount: Int
    init(_ value: Any, ttl: TimeInterval) {
      self.value = value
      expiry = Date().addingTimeInterval(ttl)
      if let encodable = value as? any Encodable {
        byteCount = (try? JSONEncoder().encode(encodable).count) ?? 0
      } else { byteCount = 0 }
    }
  }
  private let values = NSCache<NSString, Entry>()
  private var keys = Set<String>()
  private final class Flight {
    let task: Task<Any, Error>
    var readers = 0
    var stored = false
    init(task: Task<Any, Error>) { self.task = task }
  }
  private var pending: [String: Flight] = [:]
  init() { values.countLimit = 160 }

  private func cacheKey(scope: String, path: String, query: [String: String]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let suffix = query.isEmpty ? "" : ((try? encoder.encode(query).base64EncodedString()) ?? "")
    return scope + "|" + path + "|" + suffix
  }
  func read<Value>(
    scope: String, path: String, query: [String: String], fetch: @escaping () async throws -> Value
  ) async throws -> Value {
    let key = cacheKey(scope: scope, path: path, query: query)
    if !QFContentLoadingContext.forceRefresh, let entry = values.object(forKey: key as NSString),
      entry.expiry > Date(), let value = entry.value as? Value
    {
      return value
    }
    let flight: Flight
    if let existing = pending[key] {
      flight = existing
    } else {
      flight = Flight(task: Task<Any, Error> { try await fetch() })
      pending[key] = flight
    }
    // Keep the flight reachable until every waiter has consumed its result. A write can
    // still invalidate it after the first waiter returns but before another resumes.
    flight.readers += 1
    defer {
      flight.readers -= 1
      if flight.readers == 0 && pending[key] === flight { pending[key] = nil }
    }
    let value = try await flight.task.value
    guard !flight.task.isCancelled else { throw CancellationError() }
    guard let typed = value as? Value else { throw URLError(.cannotParseResponse) }
    if !flight.stored {
      store(typed, scope: scope, path: path, query: query)
      flight.stored = true
    }
    return typed
  }
  func peek<Value>(_ type: Value.Type, scope: String, path: String) -> Value? {
    if let value = values.object(forKey: (scope + "|" + path + "|") as NSString)?.value as? Value {
      return value
    }
    guard ["me/public-profile", "me/interests", "me/content-summary"].contains(path),
      let data = UserDefaults.standard.data(forKey: "qf.content.snapshot." + scope + "|" + path)
    else { return nil }
    switch type {
    case is QFPublicProfile.Type:
      return (try? JSONDecoder().decode(QFPublicProfile.self, from: data)) as? Value
    case is QFInterests.Type:
      return (try? JSONDecoder().decode(QFInterests.self, from: data)) as? Value
    case is QFContentSummary.Type:
      return (try? JSONDecoder().decode(QFContentSummary.self, from: data)) as? Value
    default: return nil
    }
  }
  func store<Value>(_ value: Value, scope: String, path: String, query: [String: String] = [:]) {
    // Provider outcomes are transient. Keep in-flight coalescing, but an outage
    // or a disabled trial must not become a cached "no product" result.
    if path.hasPrefix("me/product-barcodes/") { return }
    let key = cacheKey(scope: scope, path: path, query: query)
    let ttl: TimeInterval
    if path == "profile/options" || path == "home/recipe-options" {
      ttl = 86_400
    } else if path.hasPrefix("catalog") || path.hasPrefix("home/recipes") {
      ttl = 600
    } else {
      ttl = 120
    }
    values.setObject(Entry(value, ttl: ttl), forKey: key as NSString)
    keys.insert(key)
    if keys.count > 256 { keys = Set(keys.filter { values.object(forKey: $0 as NSString) != nil }) }
    let data: Data?
    if let profile = value as? QFPublicProfile {
      data = try? JSONEncoder().encode(profile)
    } else if let interests = value as? QFInterests {
      data = try? JSONEncoder().encode(interests)
    } else if let summary = value as? QFContentSummary {
      data = try? JSONEncoder().encode(summary)
    } else {
      data = nil
    }
    if let data, query.isEmpty {
      UserDefaults.standard.set(data, forKey: "qf.content.snapshot." + scope + "|" + path)
    }
  }

  /// Persists a small, query-scoped read snapshot for screens that need to render
  /// the previous first page while the network revalidates it. The caller owns
  /// the payload format and expiry; keeping the key here makes account cleanup
  /// remove these snapshots with the rest of the content cache.
  func querySnapshotData(scope: String, path: String, query: [String: String]) -> Data? {
    UserDefaults.standard.data(forKey: querySnapshotKey(scope: scope, path: path, query: query))
  }

  func storeQuerySnapshotData(
    _ data: Data, scope: String, path: String, query: [String: String]
  ) {
    UserDefaults.standard.set(
      data, forKey: querySnapshotKey(scope: scope, path: path, query: query))
  }

  private func querySnapshotKey(scope: String, path: String, query: [String: String]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let suffix = query.isEmpty ? "" : ((try? encoder.encode(query).base64EncodedString()) ?? "")
    return "qf.content.snapshot.query." + scope + "|" + path + "|" + suffix
  }
  func didWrite<Value>(_ value: Value, scope: String, path: String) {
    if path == "me/public-profile", let profile = value as? QFPublicProfile,
      let previous = peek(QFPublicProfile.self, scope: scope, path: path),
      previous.countryCode != profile.countryCode || previous.regionCode != profile.regionCode
    {
      invalidateCatalogRecommendations(scope: scope)
    }
    var prefixes: [String]
    if path == "me/public-profile" {
      prefixes = [
        "me/public-profile", "works/", "me/works", "me/favorites", "me/content-summary",
        "home/recipes", "home/recipe-options",
      ]
    } else if path == "me/interests" {
      prefixes = ["me/interests"]
    } else if path.hasPrefix("me/works/") {
      prefixes = [
        "me/works", "works/", "me/favorites", "me/content-summary", "catalog/RECIPE/",
        "home/recipes",
      ]
    } else if path.hasPrefix("me/favorites/") {
      prefixes = ["me/favorites", "me/content-summary", "home/recipes", "catalog"]
    } else if path.hasPrefix("me/recipe-ratings/") {
      prefixes = ["home/recipes"]
    } else if path.hasPrefix("me/contributions/") {
      prefixes = ["me/contributions", "me/content-summary", "catalog", "home/recipes"]
    } else if path.hasPrefix("me/cooking-records/") {
      prefixes = [
        "me/cooking-records", "me/content-summary", "me/planned-meals", "me/inventory", "catalog",
        "me/shopping-lists", "me/cooking-costs", "me/preparation-expenses",
      ]
    } else if path.hasPrefix("me/purchase-receipts/") {
      prefixes = ["me/purchase-receipts", "me/preparation-expenses", "me/cooking-costs", "me/cooking-records", "me/inventory", "me/shopping-lists"]
    } else if path.hasPrefix("me/purchases/") {
      prefixes = ["me/purchases", "me/purchase-receipts", "me/preparation-expenses"]
    } else if path.hasPrefix("me/rights-claims/") {
      prefixes = ["me/rights-claims"]
    } else if path.hasPrefix("me/households") || path.hasPrefix("me/household-invitations/") {
      prefixes = [
        "me/households", "me/planned-meals", "me/planned-meal-slots",
        "me/shopping-lists", "me/inventory", "me/plan-reminder", "me/weekly-plan-proposals",
      ]
    } else if path.hasPrefix("me/planned-meals/") || path.hasPrefix("me/planned-meal-slots/") {
      prefixes = [
        "me/planned-meals", "me/planned-meal-slots", "me/shopping-lists",
        "me/weekly-plan-proposals", "catalog",
      ]
    } else if path.hasPrefix("me/shopping-lists/") {
      prefixes = ["me/shopping-lists"]
    } else if path.hasPrefix("me/inventory/") {
      prefixes = ["me/inventory", "me/shopping-lists", "me/weekly-plan-proposals", "me/cooking-costs", "me/cooking-records", "me/preparation-expenses", "me/purchase-receipts"]
    } else if path == "me/plan-reminder" {
      prefixes = ["me/plan-reminder", "me/settings"]
    } else if path.hasPrefix("me/push-devices/") {
      prefixes = ["me/push-devices"]
    } else if path.hasPrefix("me/weekly-plan-proposals/") {
      prefixes = path.hasSuffix("/accept")
        ? ["me/weekly-plan-proposals", "me/planned-meals", "me/planned-meal-slots"]
        : ["me/weekly-plan-proposals"]
    } else {
      prefixes = [path]
    }
    if path.hasPrefix("me/inventory/") || path.hasPrefix("me/purchase-receipts/") || path.hasPrefix("me/cooking-records/") || path.hasPrefix("me/planned-meals/") || path.hasPrefix("me/planned-meal-slots/") || path.hasPrefix("me/households") || path.hasPrefix("me/household-invitations/") || path.hasSuffix("/accept") {
      prefixes.append("me/ingredient-combinations")
      prefixes.append("me/cooking-statistics")
      prefixes.append("catalog")
    }
    func affected(_ key: String) -> Bool {
      prefixes.contains(where: { key.hasPrefix(scope + "|" + $0) })
        || (path == "me/public-profile" && key.hasPrefix(scope + "|catalog/RECIPE/")
          && key.contains("/works|"))
    }
    for key in keys where affected(key) { values.removeObject(forKey: key as NSString) }
    for (key, entry) in pending where affected(key) {
      entry.task.cancel()
      pending[key] = nil
    }
    if path == "me/public-profile", let profile = value as? QFPublicProfile {
      store(profile, scope: scope, path: path)
      if var summary = peek(QFContentSummary.self, scope: scope, path: "me/content-summary") {
        summary.avatarMediaId = profile.avatarMediaId
        store(summary, scope: scope, path: "me/content-summary")
      }
    } else if path == "me/settings", let settings = value as? QFUserSettings {
      store(settings, scope: scope, path: path)
    } else if path == "me/interests", let interests = value as? QFInterests {
      store(interests, scope: scope, path: path)
    } else if let work = value as? QFUserWork {
      store(work, scope: scope, path: "works/" + work.id)
    }
    if prefixes.contains(where: { ["me/planned-meals", "me/plan-reminder", "me/inventory", "me/settings"].contains($0) }) {
      NotificationCenter.default.post(name: Notification.Name("qf.planningReminderDataDidChange"), object: nil,
        userInfo: ["scope": scope])
    }
  }
  func clearMemory() {
    pending.values.forEach { $0.task.cancel() }
    pending.removeAll()
    values.removeAllObjects()
    keys.removeAll()
  }
  /// Payload sizes estimate response-cache use; Swift object overhead is intentionally not claimed as exact.
  var memoryPayloadBytes: Int {
    keys.reduce(0) { $0 + (values.object(forKey: $1 as NSString)?.byteCount ?? 0) }
  }
  var persistentPayloadBytes: Int {
    UserDefaults.standard.dictionaryRepresentation().reduce(0) { total, entry in
      total + (entry.key.hasPrefix("qf.content.snapshot.") ? (entry.value as? Data)?.count ?? 0 : 0)
    }
  }
  func clearDisposableResponses() {
    clearMemory()
    for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("qf.content.snapshot.") {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
  func clearAccount(scope: String) {
    clearMemory()
    let prefix = "qf.content.snapshot." + scope + "|"
    for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
      UserDefaults.standard.removeObject(forKey: key)
    }
    let queryPrefix = "qf.content.snapshot.query." + scope + "|"
    for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(queryPrefix) {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
  func invalidateCatalogRecommendations(scope: String) {
    let prefixes = [scope + "|catalog|", scope + "|home/recipes|", scope + "|home/recipe-options|"]
    for key in keys where prefixes.contains(where: key.hasPrefix) {
      values.removeObject(forKey: key as NSString)
    }
    for (key, flight) in pending where prefixes.contains(where: key.hasPrefix) {
      flight.task.cancel()
      pending[key] = nil
    }
    let snapshotPrefix = "qf.content.snapshot.query." + scope + "|home/recipes|"
    for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(snapshotPrefix) {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  func invalidatePlanningData(scope: String) {
    let paths = [
      "me/planned-meals", "me/planned-meal-slots", "me/shopping-lists", "me/inventory",
      "me/plan-reminder", "me/weekly-plan-proposals", "me/cooking-costs", "me/preparation-expenses", "me/purchase-receipts",
    ]
    func matches(_ key: String) -> Bool {
      paths.contains(where: { key.hasPrefix(scope + "|" + $0) })
    }
    for key in keys where matches(key) { values.removeObject(forKey: key as NSString) }
    for (key, flight) in pending where matches(key) {
      flight.task.cancel()
      pending[key] = nil
    }
  }
}
