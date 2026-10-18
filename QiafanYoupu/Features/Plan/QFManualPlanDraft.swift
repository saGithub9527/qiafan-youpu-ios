import Foundation

struct QFPlanBatchDraft: Codable, Equatable {
  struct Item: Codable, Equatable { let recipeId: String; let servings: Int }
  struct Meal: Codable, Equatable { let meal: String; let items: [Item] }
  let requestId: UUID
  let householdId: String?
  let startDate: String
  let endDate: String
  let weekdays: [Int]
  let meals: [Meal]
}

struct QFPlanBatchResult: Decodable {
  let requestId: UUID
  let addedCount: Int
  let skippedCount: Int
  let days: [QFPlanDay]
}

/// A civil-date draft, independent of the device time zone. Nothing here writes to the server.
struct QFManualPlanDraft: Codable, Equatable {
  struct Recipe: Codable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let mediaId: String?
    let minutes: Int?
    let language: String
    var servings = 1
  }
  struct Pending: Codable, Equatable {
    let body: QFPlanBatchDraft
    let language: String
  }
  enum Validation: Error { case dateRange, weekdays, empty, capacity }
  static let meals = ["BREAKFAST", "LUNCH", "DINNER"]
  // Authentication/permission errors on a retry do not establish whether an earlier
  // attempt committed. Only batch-specific rejections can safely release the receipt.
  static func isDefinitiveRejection(_ code: Int) -> Bool { [42201, 42204].contains(code) }
  var startDate: String
  var endDate: String
  var usesRange = false
  var repeats = false
  var weekdays: [Int] = []
  var recipes: [String: [Recipe]] = [:]
  // Persist before transmission. An uncertain result must retry this exact body and language.
  var pending: Pending?

  init(date: String) { startDate = date; endDate = date }
  var recipeCount: Int { recipes.values.reduce(0) { $0 + $1.count } }
  var effectiveEnd: String { usesRange ? endDate : startDate }
  var effectiveWeekdays: [Int] { usesRange && repeats ? weekdays.sorted() : [] }
  static var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }
  static func date(_ value: String) -> Date? {
    let formatter = dateFormatter()
    guard let date = formatter.date(from: value), formatter.string(from: date) == value,
      value >= "1000-01-01", value <= "9999-12-31" else { return nil }
    return date
  }
  static func string(_ date: Date) -> String { dateFormatter().string(from: date) }
  private static func dateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    return formatter
  }
  func selectedDates() throws -> [String] {
    guard let start = Self.date(startDate), let end = Self.date(effectiveEnd),
      let distance = Self.calendar.dateComponents([.day], from: start, to: end).day,
      (0..<42).contains(distance) else { throw Validation.dateRange }
    if usesRange && repeats && (weekdays.isEmpty || Set(weekdays).count != weekdays.count
      || weekdays.contains(where: { !(1...7).contains($0) })) { throw Validation.weekdays }
    let dates = (0...distance).compactMap { offset -> String? in
      guard let day = Self.calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
      let isoWeekday = (Self.calendar.component(.weekday, from: day) + 5) % 7 + 1
      return effectiveWeekdays.isEmpty || effectiveWeekdays.contains(isoWeekday) ? Self.string(day) : nil
    }
    guard !dates.isEmpty else { throw Validation.weekdays }
    return dates
  }
  func request(householdID: String?, requestID: UUID = UUID()) throws -> QFPlanBatchDraft {
    _ = try selectedDates()
    let values = Self.meals.compactMap { meal -> QFPlanBatchDraft.Meal? in
      guard let items = recipes[meal], !items.isEmpty else { return nil }
      return .init(meal: meal, items: items.map { .init(recipeId: $0.id, servings: $0.servings) })
    }
    guard !values.isEmpty else { throw Validation.empty }
    guard values.allSatisfy({ $0.items.count <= 30
      && Set($0.items.map(\.recipeId)).count == $0.items.count
      && $0.items.allSatisfy { (1...100).contains($0.servings) } }) else { throw Validation.capacity }
    return .init(requestId: requestID, householdId: householdID, startDate: startDate,
      endDate: effectiveEnd, weekdays: effectiveWeekdays, meals: values)
  }
}

extension QFAppSession {
  func appendPlanBatch(_ pending: QFManualPlanDraft.Pending) async throws -> QFPlanBatchResult {
    try await QFContentLoadingContext.$language.withValue(pending.language) {
      try await contentRequest(path: "me/planned-meals/batch", method: "POST",
        body: JSONEncoder().encode(pending.body), operationID: pending.body.requestId)
    }
  }
}
