import Foundation

/// Civil-date selection only. A meal is one node containing every unfinished dish.
enum QFNextMealReminderSelection {
  struct Rule {
    let meal: String
    let enabled: Bool
    let localTime: String
    let advanceMinutes: Int
  }
  struct Plan {
    let id: String
    let recipeID: String
    let title: String?
    let servings: Int
    let revision: Int
    let contentAvailable: Bool
    let completed: Bool
    let skipped: Bool
  }
  struct Slot { let meal: String; let plans: [Plan] }
  struct Day { let date: String; let slots: [Slot] }
  struct Node {
    let date: String
    let meal: String
    let scheduledAt: Date
    let reminderAt: Date
    let plans: [Plan]
  }

  static func dates(now: Date, timezone: String) -> [String]? {
    guard let calendar = calendar(timezone: timezone),
      let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
    let formatter = formatter(calendar: calendar)
    return [formatter.string(from: now), formatter.string(from: tomorrow)]
  }

  static func select(now: Date, timezone: String, rules: [Rule], days: [Day]) -> Node? {
    guard let calendar = calendar(timezone: timezone),
      let allowedDates = dates(now: now, timezone: timezone) else { return nil }
    let formatter = formatter(calendar: calendar)
    let meals = ["BREAKFAST", "LUNCH", "DINNER", "SNACK"]
    var nodes: [Node] = []
    // A malformed/duplicated rule set cannot safely determine the next node.
    guard Set(rules.map(\.meal)).count == rules.count else { return nil }
    for day in days where allowedDates.contains(day.date) {
      guard let date = formatter.date(from: day.date), formatter.string(from: date) == day.date else { continue }
      for rule in rules where rule.enabled && meals.contains(rule.meal) {
        let parts = rule.localTime.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
          let hour = Int(parts[0]), let minute = Int(parts[1]),
          (0...23).contains(hour), (0...59).contains(minute),
          (0...1440).contains(rule.advanceMinutes),
          let scheduled = calendar.date(bySettingHour: hour, minute: minute, second: 0,
            of: date, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
          formatter.string(from: scheduled) == day.date, scheduled >= now else { continue }
        let plans = day.slots.filter { $0.meal == rule.meal }.flatMap(\.plans)
          .filter { !$0.completed && !$0.skipped }
        guard !plans.isEmpty, Set(plans.map(\.id)).count == plans.count else { continue }
        nodes.append(Node(date: day.date, meal: rule.meal, scheduledAt: scheduled,
          reminderAt: scheduled.addingTimeInterval(-Double(rule.advanceMinutes) * 60), plans: plans))
      }
    }
    return nodes.min {
      if $0.scheduledAt != $1.scheduledAt { return $0.scheduledAt < $1.scheduledAt }
      return (meals.firstIndex(of: $0.meal) ?? 4) < (meals.firstIndex(of: $1.meal) ?? 4)
    }
  }

  private static func calendar(timezone: String) -> Calendar? {
    guard let zone = TimeZone(identifier: timezone) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
  }
  private static func formatter(calendar: Calendar) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    return formatter
  }
}
