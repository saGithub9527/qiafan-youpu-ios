import Foundation
let now = Date(timeIntervalSince1970: 1_792_800_000)
let scope = String(repeating: "a", count: 64)
let entry = QFMealSurfaceEntry(id: "meal", planID: "ac0115b9-059a-4a52-85d1-8c293dc49386", date: "2026-10-24", meal: "DINNER", scheduledAt: now.addingTimeInterval(3600), expiresAt: now.addingTimeInterval(7200), recipeTitles: ["番茄炒蛋"], requiredIngredients: ["番茄"], inStockIngredients: [], missingIngredients: [], stockKnown: false)
var doc = QFMealSurfaceDocument(scopeKey: scope, language: "zh-Hans", updatedAt: now, status: .ready, entries: [entry])
var failures: [String] = []
func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { failures.append(message) } }
check(QFMealSurfaceSelector.currentEntry(in: doc, now: now)?.id == entry.id, "fresh current meal selected")
doc.updatedAt = now.addingTimeInterval(-86401)
check(QFMealSurfaceSelector.currentEntry(in: doc, now: now) == nil, "expired snapshot must not appear current")
check(QFMealSurfaceSelector.effectiveStatus(in: doc, now: now) == .unavailable, "expired snapshot must be unavailable")
doc.updatedAt = now.addingTimeInterval(3600)
check(QFMealSurfaceSelector.currentEntry(in: doc, now: now) == nil, "future timestamp must not bypass freshness")
doc.updatedAt = now;doc.status = .signedOut
check(QFMealSurfaceSelector.currentEntry(in: doc, now: now) == nil, "signed-out cache cannot display meals")
doc.status = .ready;doc.schemaVersion = 100
check(QFMealSurfaceSelector.currentEntry(in: doc, now: now) == nil, "unknown schema rejected")
let decoder = JSONDecoder()
let data = try JSONEncoder().encode(entry)
let decoded = try decoder.decode(QFMealSurfaceEntry.self, from: data)
check(decoded == entry, "ActivityKit default JSON roundtrip uses ISO8601")
check(String(data: data, encoding: .utf8)!.contains("T"), "wire dates are strings")
check(QFMealSurfaceSelector.deepLink(for: entry)?.host == "meal-plan", "deep link scoped to meal route")
print("Checks: 9; failures: \(failures.count)")
failures.forEach { print("FAIL: \($0)") }
if !failures.isEmpty { exit(1) }
