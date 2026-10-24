import Foundation
@main struct HistoryChecks {
 static func main() {
  let name = "qf-meal-history-check-" + UUID().uuidString
  let first = UserDefaults(suiteName: name)!
  defer { first.removePersistentDomain(forName: name) }
  let scope = String(repeating: "a", count: 64)
  let other = String(repeating: "b", count: 64)
  precondition(!QFMealActivityStartHistory.contains(scope: scope, entryID: "2026-10-24/DINNER", defaults: first))
  QFMealActivityStartHistory.record(scope: scope, entryID: "2026-10-24/DINNER", defaults: first)
  precondition(QFMealActivityStartHistory.contains(scope: scope, entryID: "2026-10-24/DINNER", defaults: UserDefaults(suiteName: name)!))
  precondition(!QFMealActivityStartHistory.contains(scope: other, entryID: "2026-10-24/DINNER", defaults: first))
  QFMealActivityStartHistory.record(scope: scope, entryID: "2026-10-25/BREAKFAST", defaults: first)
  precondition(QFMealActivityStartHistory.contains(scope: scope, entryID: "2026-10-24/DINNER", defaults: first))
  for i in 0..<100 { QFMealActivityStartHistory.record(scope: scope, entryID: "meal-\(i)", defaults: first) }
  precondition(!QFMealActivityStartHistory.contains(scope: scope, entryID: "meal-0", defaults: first))
  precondition(QFMealActivityStartHistory.contains(scope: scope, entryID: "meal-99", defaults: first))
  print("6 persisted activity history checks passed")
 }
}
