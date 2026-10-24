import Foundation

enum QFMealSurfaceConfiguration {
  static let appGroupID = "group.com.talka.qiafanyoupu"
  static let fileName = "meal-surface-v1.json"
  static let widgetKind = "QFNextMealWidget"
}

enum QFMealSurfaceStatus: String, Codable, Equatable, Sendable {
  case signedOut, disabled, empty, ready, unavailable
}

/// A public display snapshot. scopeKey must be opaque; credentials and health data do not belong here.
struct QFMealSurfaceDocument: Codable, Equatable, Sendable {
  var schemaVersion: Int = 1
  var scopeKey: String
  var language: String
  var updatedAt: Date
  var status: QFMealSurfaceStatus
  var entries: [QFMealSurfaceEntry]

  init(schemaVersion: Int = 1, scopeKey: String, language: String, updatedAt: Date,
       status: QFMealSurfaceStatus, entries: [QFMealSurfaceEntry]) {
    self.schemaVersion = schemaVersion
    self.scopeKey = scopeKey
    self.language = language
    self.updatedAt = updatedAt
    self.status = status
    self.entries = entries
  }
}

struct QFMealSurfaceEntry: Codable, Equatable, Hashable, Sendable {
  var id: String
  var planID: String
  var date: String
  var meal: String
  var scheduledAt: Date
  var expiresAt: Date
  var recipeTitles: [String]
  var requiredIngredients: [String]
  var inStockIngredients: [String]
  var missingIngredients: [String]
  var stockKnown: Bool
  var timezone: String

  init(id: String, planID: String, date: String, meal: String, scheduledAt: Date,
       expiresAt: Date, recipeTitles: [String], requiredIngredients: [String],
       inStockIngredients: [String], missingIngredients: [String], stockKnown: Bool, timezone: String = "UTC") {
    self.id = id
    self.planID = planID
    self.date = date
    self.meal = meal
    self.scheduledAt = scheduledAt
    self.expiresAt = expiresAt
    self.recipeTitles = recipeTitles
    self.requiredIngredients = requiredIngredients
    self.inStockIngredients = inStockIngredients
    self.missingIngredients = missingIngredients
    self.stockKnown = stockKnown
    self.timezone = timezone
  }

  private enum CodingKeys: String, CodingKey {
    case id, planID, date, meal, scheduledAt, expiresAt, recipeTitles
    case requiredIngredients, inStockIngredients, missingIngredients, stockKnown, timezone
  }

  /// ActivityKit decodes ContentState itself, independently of the app's JSON date strategy.
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    planID = try values.decode(String.self, forKey: .planID)
    date = try values.decode(String.self, forKey: .date)
    meal = try values.decode(String.self, forKey: .meal)
    scheduledAt = try Self.decodeDate(values, key: .scheduledAt)
    expiresAt = try Self.decodeDate(values, key: .expiresAt)
    recipeTitles = try values.decode([String].self, forKey: .recipeTitles)
    requiredIngredients = try values.decode([String].self, forKey: .requiredIngredients)
    inStockIngredients = try values.decode([String].self, forKey: .inStockIngredients)
    missingIngredients = try values.decode([String].self, forKey: .missingIngredients)
    stockKnown = try values.decode(Bool.self, forKey: .stockKnown)
    timezone = try values.decodeIfPresent(String.self, forKey: .timezone) ?? "UTC"
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(planID, forKey: .planID)
    try values.encode(date, forKey: .date)
    try values.encode(meal, forKey: .meal)
    let formatter = Self.dateFormatter(fractional: true)
    try values.encode(formatter.string(from: scheduledAt), forKey: .scheduledAt)
    try values.encode(formatter.string(from: expiresAt), forKey: .expiresAt)
    try values.encode(recipeTitles, forKey: .recipeTitles)
    try values.encode(requiredIngredients, forKey: .requiredIngredients)
    try values.encode(inStockIngredients, forKey: .inStockIngredients)
    try values.encode(missingIngredients, forKey: .missingIngredients)
    try values.encode(stockKnown, forKey: .stockKnown)
    try values.encode(timezone, forKey: .timezone)
  }

  private static func decodeDate(_ values: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Date {
    let raw = try values.decode(String.self, forKey: key)
    guard let value = dateFormatter(fractional: true).date(from: raw)
      ?? dateFormatter(fractional: false).date(from: raw) else {
      throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Expected an ISO8601 timestamp")
    }
    return value
  }

  private static func dateFormatter(fractional: Bool) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }
}

/// Deterministic Foundation-only selection, also usable by the app and host checks.
enum QFMealSurfaceSelector {
  static let supportedLanguages: Set<String> = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "ru", "es", "fr", "de", "pt-BR"]
  static let maximumSnapshotAge: TimeInterval = 24 * 60 * 60
  static let maximumClockSkew: TimeInterval = 5 * 60
  private static let meals: Set<String> = ["BREAKFAST", "LUNCH", "DINNER", "SNACK"]

  static func currentEntry(in document: QFMealSurfaceDocument, now: Date) -> QFMealSurfaceEntry? {
    guard document.schemaVersion == 1, document.status == .ready, isFresh(document, now: now),
          !document.scopeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          supportedLanguages.contains(document.language) else { return nil }
    return document.entries.filter { isValid($0) && $0.expiresAt > now }
      .sorted { left, right in
        left.scheduledAt == right.scheduledAt ? left.id < right.id : left.scheduledAt < right.scheduledAt
      }.first
  }

  static func effectiveStatus(in document: QFMealSurfaceDocument?, now: Date) -> QFMealSurfaceStatus {
    guard let document, document.schemaVersion == 1, isFresh(document, now: now),
          supportedLanguages.contains(document.language) else { return .unavailable }
    guard document.status == .ready else { return document.status }
    // An exhausted snapshot is stale, not evidence that the account has no other plans.
    return currentEntry(in: document, now: now) == nil ? .unavailable : .ready
  }

  static func isValid(_ entry: QFMealSurfaceEntry) -> Bool {
    if entry.id.hasPrefix("display-probe/") {
      #if DEBUG
      guard let run = UUID(uuidString: entry.planID),
        entry.id == "display-probe/" + run.uuidString.lowercased(),
        entry.expiresAt.timeIntervalSince(entry.scheduledAt) <= 180,
        entry.requiredIngredients.isEmpty, entry.inStockIngredients.isEmpty, entry.missingIngredients.isEmpty,
        entry.recipeTitles.count == 1,
        ["显示测试·未保存饮食计划", "显示检查已更新·未保存饮食计划"].contains(entry.recipeTitles[0]) else { return false }
      #else
      return false
      #endif
    }
    return !entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && UUID(uuidString: entry.planID) != nil && isValidDate(entry.date)
      && meals.contains(entry.meal)
      && TimeZone(identifier: entry.timezone) != nil
      && entry.scheduledAt.timeIntervalSince1970.isFinite
      && entry.expiresAt.timeIntervalSince1970.isFinite
      && entry.expiresAt > entry.scheduledAt
  }

  private static func isFresh(_ document: QFMealSurfaceDocument, now: Date) -> Bool {
    let age = now.timeIntervalSince(document.updatedAt)
    return now.timeIntervalSince1970.isFinite && age.isFinite
      && age >= -maximumClockSkew && age <= maximumSnapshotAge
  }

  static func deepLink(for entry: QFMealSurfaceEntry) -> URL? {
    guard !entry.id.hasPrefix("display-probe/"), isValid(entry) else { return nil }
    var components = URLComponents()
    components.scheme = "qiafanyoupu"
    components.host = "meal-plan"
    components.queryItems = [URLQueryItem(name: "date", value: entry.date),
                             URLQueryItem(name: "meal", value: entry.meal),
                             URLQueryItem(name: "planID", value: entry.planID)]
    return components.url
  }

  private static func isValidDate(_ value: String) -> Bool {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard value.utf8.count == 10, parts.count == 3,
          parts[0].utf8.count == 4, parts[1].utf8.count == 2, parts[2].utf8.count == 2,
          value.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) }),
          let year = Int(parts[0]), (1...9999).contains(year),
          let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let expected = DateComponents(year: year, month: month, day: day)
    guard let parsed = calendar.date(from: expected) else { return false }
    let actual = calendar.dateComponents([.year, .month, .day], from: parsed)
    return actual.year == year && actual.month == month && actual.day == day
  }
}

#if os(iOS) && canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
struct QFMealActivityAttributes: ActivityAttributes {
  typealias ContentState = QFMealSurfaceEntry
  var scopeKey: String
  var entryID: String
}
#endif

/// Pure read-model projection. Duplicate identities and invalid wall-clock rules fail closed.
enum QFMealSurfaceProjection {
  struct Plan {
    let id: String
    let date: String
    let meal: String
    let title: String?
    let completed: Bool
    let skipped: Bool
    let contentAvailable: Bool
  }
  struct Rule { let meal: String; let localTime: String }

  static func entries(plans: [Plan], rules: [Rule], timezone: String, now: Date) -> [QFMealSurfaceEntry] {
    guard let zone = TimeZone(identifier: timezone), Set(plans.map(\.id)).count == plans.count,
      Set(rules.map(\.meal)).count == rules.count else { return [] }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
    let grouped = Dictionary(grouping: plans.filter { !$0.completed && !$0.skipped }, by: { $0.date + "/" + $0.meal })
    return grouped.compactMap { key, group -> QFMealSurfaceEntry? in
      let sorted = group.sorted { $0.id < $1.id }
      guard let first = sorted.first, sorted.allSatisfy({ UUID(uuidString: $0.id) != nil }),
        let rule = rules.first(where: { $0.meal == first.meal }) else { return nil }
      let time = rule.localTime.split(separator: ":", omittingEmptySubsequences: false)
      let day = first.date.split(separator: "-", omittingEmptySubsequences: false)
      guard time.count == 2, time.allSatisfy({ $0.count == 2 }),
        let hour = Int(time[0]), (0...23).contains(hour), let minute = Int(time[1]), (0...59).contains(minute),
        day.count == 3, let year = Int(day[0]), let month = Int(day[1]), let date = Int(day[2]),
        let scheduled = calendar.date(from: DateComponents(year: year, month: month, day: date, hour: hour, minute: minute)) else { return nil }
      let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: scheduled)
      guard actual.year == year, actual.month == month, actual.day == date,
        actual.hour == hour, actual.minute == minute else { return nil }
      let expires = scheduled.addingTimeInterval(2 * 60 * 60)
      guard expires > now else { return nil }
      let titles = sorted.filter(\.contentAvailable).compactMap(\.title).map { compact($0, limit: 50) }.filter { !$0.isEmpty }
      let entry = QFMealSurfaceEntry(id: key, planID: first.id, date: first.date, meal: first.meal,
        scheduledAt: scheduled, expiresAt: expires, recipeTitles: Array(titles.prefix(2)),
        requiredIngredients: [], inStockIngredients: [], missingIngredients: [], stockKnown: false, timezone: timezone)
      return QFMealSurfaceSelector.isValid(entry) ? entry : nil
    }.sorted { $0.scheduledAt == $1.scheduledAt ? $0.id < $1.id : $0.scheduledAt < $1.scheduledAt }
  }

  static func compact(_ text: String, limit: Int = 24) -> String {
    let value = text.components(separatedBy: .controlCharacters).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.count > limit ? String(value.prefix(limit)) + "…" : value
  }
}

struct QFMealSurfaceRoute: Equatable {
  let planID: String?
  init?(url: URL) {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme == "qiafanyoupu", parts.host == "meal-plan", parts.user == nil, parts.password == nil,
      parts.port == nil, parts.path.isEmpty, parts.fragment == nil else { return nil }
    let items = parts.queryItems ?? []
    if items.isEmpty { planID = nil; return }
    guard items.count == 3, Set(items.map(\.name)) == Set(["date", "meal", "planID"]),
      let id = items.first(where: { $0.name == "planID" })?.value,
      let date = items.first(where: { $0.name == "date" })?.value,
      let meal = items.first(where: { $0.name == "meal" })?.value else { return nil }
    let probe = QFMealSurfaceEntry(id: id, planID: id, date: date, meal: meal, scheduledAt: Date(timeIntervalSince1970: 0),
      expiresAt: Date(timeIntervalSince1970: 1), recipeTitles: [], requiredIngredients: [], inStockIngredients: [], missingIngredients: [], stockKnown: false)
    guard QFMealSurfaceSelector.isValid(probe) else { return nil }
    planID = id
  }
}

/// Remembers any observed start, including a remote start, so reopening the app respects removal.
/// Only opaque scope hashes and bounded meal identities are retained, never recipe or token data.
enum QFMealActivityStartHistory {
  private static func key(_ scope: String) -> String { "qf.meal-activity.started." + scope }
  static func contains(scope: String, entryID: String, defaults: UserDefaults = .standard) -> Bool {
    values(scope: scope, defaults: defaults).contains(entryID)
  }
  static func record(scope: String, entryID: String, defaults: UserDefaults = .standard) {
    guard scope.utf8.count == 64, !entryID.isEmpty, entryID.utf8.count <= 128 else { return }
    var saved = values(scope: scope, defaults: defaults)
    guard !saved.contains(entryID) else { return }
    saved.append(entryID)
    defaults.set(Array(saved.suffix(64)), forKey: key(scope))
  }
  private static func values(scope: String, defaults: UserDefaults) -> [String] {
    if let array = defaults.stringArray(forKey: key(scope)) { return array }
    if let legacy = defaults.string(forKey: key(scope)) { return [legacy] }
    return []
  }
}
