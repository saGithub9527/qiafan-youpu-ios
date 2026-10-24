import Foundation

@main struct Checks {
 static func main() throws {
  let now = ISO8601DateFormatter().date(from: "2026-10-24T08:00:00Z")!
  let id = "04ee54a8-37dc-482d-826c-fca24d64b89a"
  let plan = QFMealSurfaceProjection.Plan(id: id, date: "2026-10-24", meal: "DINNER", title: "番茄鸡蛋", completed: false, skipped: false, contentAvailable: true)
  let rules = [QFMealSurfaceProjection.Rule(meal: "DINNER", localTime: "18:00")]
  let entries = QFMealSurfaceProjection.entries(plans: [plan], rules: rules, timezone: "Asia/Shanghai", now: now)
  precondition(entries.count == 1 && entries[0].scheduledAt.timeIntervalSince1970 == now.timeIntervalSince1970 + 7200)
  precondition(entries[0].expiresAt.timeIntervalSince(entries[0].scheduledAt) == 7200)
  precondition(entries[0].stockKnown == false)
  precondition(QFMealSurfaceProjection.entries(plans: [plan, plan], rules: rules, timezone: "Asia/Shanghai", now: now).isEmpty)
  let completed = QFMealSurfaceProjection.Plan(id: id, date: plan.date, meal: plan.meal, title: plan.title, completed: true, skipped: false, contentAvailable: true)
  precondition(QFMealSurfaceProjection.entries(plans: [completed], rules: rules, timezone: "Asia/Shanghai", now: now).isEmpty)
  precondition(QFMealSurfaceProjection.entries(plans: [plan], rules: [.init(meal: "DINNER", localTime: "29:00")], timezone: "Asia/Shanghai", now: now).isEmpty)
  precondition(QFMealSurfaceProjection.entries(plans: [plan], rules: rules, timezone: "bad-zone", now: now).isEmpty)
  let past = QFMealSurfaceProjection.entries(plans: [plan], rules: rules, timezone: "Asia/Shanghai", now: now.addingTimeInterval(15000))
  precondition(past.isEmpty)
  precondition(QFMealSurfaceRoute(url: URL(string: "qiafanyoupu://meal-plan?date=2026-10-24&meal=DINNER&planID=\(id)")!)?.planID == id)
  precondition(QFMealSurfaceRoute(url: URL(string: "qiafanyoupu://meal-plan?planID=\(id)&planID=\(id)&date=2026-10-24&meal=DINNER")!) == nil)
  precondition(QFMealSurfaceRoute(url: URL(string: "https://meal-plan?date=2026-10-24&meal=DINNER&planID=\(id)")!) == nil)
  precondition(QFMealSurfaceRoute(url: URL(string: "qiafanyoupu://meal-plan?date=2026-02-30&meal=DINNER&planID=\(id)")!) == nil)
  print("12 projection and route checks passed")
 }
}
