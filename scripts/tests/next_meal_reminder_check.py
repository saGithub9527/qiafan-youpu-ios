#!/usr/bin/env python3
"""Bounded host checks of next-meal selection and stale-scope rejection.

Only the API boundary is stubbed; the shipping selector and service run unchanged.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
sources = [root / 'QiafanYoupu/Features/Assistant' / name for name in (
    'QFNextMealReminderSelection.swift', 'QFNextMealReminder.swift')]
assert all(path.exists() for path in sources), 'Next-meal selection/service is not implemented'
harness = r'''
import Foundation

struct QFUserProfile { let userId: String }
struct QFUserSettings { let planReminders: Bool }
struct QFMealReminder { let meal: String; let enabled: Bool; let localTime: String; let advanceMinutes: Int }
struct QFReminderSettings { let householdId: String?; let timezone: String?; let enabled: Bool; let meals: [QFMealReminder] }
struct QFPlannedMeal {
 let id: String; let recipeId: String; let title: String?; let contentAvailable: Bool
 let date: String; let meal: String; let servings: Int; let householdId: String?; let revision: Int
 let completed: Bool; let skipped: Bool
}
struct QFPlanSlot { let meal: String; let items: [QFPlannedMeal] }
struct QFPlanDay { let date: String; let slots: [QFPlanSlot] }
struct QFPlanMaterialAvailability {
 let ingredientId: String?; let name: String; let status: String; let requiredQuantity: String?
 let availableQuantity: String?; let missingQuantity: String?; let unitCode: String?
}
struct QFPlanAvailabilityItem { let planId: String; let planRevision: Int; let status: String; let materials: [QFPlanMaterialAvailability] }
struct QFPlanAvailability { let date: String; let householdId: String?; let items: [QFPlanAvailabilityItem] }
enum QFContentLoadingContext { @TaskLocal static var forceRefresh = false }
enum FakeFailure: Error { case unavailable }
@MainActor final class QFAppSession {
 var user: QFUserProfile? = .init(userId: "u1")
 var contentScope = "account1"
 var planningHouseholdID: String? = nil
 var interfaceLanguage = "zh-Hans"
 var master = true
 var profile = QFReminderSettings(householdId: nil, timezone: "Asia/Shanghai", enabled: true, meals: [
  .init(meal: "BREAKFAST", enabled: true, localTime: "08:00", advanceMinutes: 0),
  .init(meal: "LUNCH", enabled: true, localTime: "12:00", advanceMinutes: 0),
  .init(meal: "DINNER", enabled: true, localTime: "18:00", advanceMinutes: 30)])
 var days: [String:QFPlanDay] = [:]
 var available = QFPlanAvailability(date: "2026-10-17", householdId: nil, items: [])
 var availabilityFails = false
 var mutateOnAvailability: (() -> Void)?
 var availabilityDelay: UInt64 = 0
 var requests: [String] = []
 func loadUserSettings() async throws -> QFUserSettings { requests.append("settings"); return .init(planReminders: master) }
 func reminderSettings(householdID: String?) async throws -> QFReminderSettings { requests.append("reminders"); return profile }
 func planDay(date: String, householdID: String?) async throws -> QFPlanDay {
  requests.append(date); return days[date] ?? .init(date: date, slots: [])
 }
 func planAvailability(date: String, householdID: String?) async throws -> QFPlanAvailability {
  requests.append("availability"); if availabilityDelay > 0 { try? await Task.sleep(nanoseconds: availabilityDelay) }
  mutateOnAvailability?(); if availabilityFails { throw FakeFailure.unavailable }; return available
 }
}
func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
func plan(_ id: String, date: String = "2026-10-17", meal: String = "DINNER", completed: Bool = false, skipped: Bool = false) -> QFPlannedMeal {
 .init(id: id, recipeId: "recipe-"+id, title: "Dish "+id, contentAvailable: true, date: date, meal: meal, servings: 2,
       householdId: nil, revision: 3, completed: completed, skipped: skipped)
}
func availability(_ ids: [String], revision: Int = 3) -> QFPlanAvailability {
 .init(date: "2026-10-17", householdId: nil, items: ids.map { .init(planId: $0, planRevision: revision, status: "UNCONFIRMED", materials: [
  .init(ingredientId: nil, name: "Salt", status: "UNCONFIRMED", requiredQuantity: nil,
        availableQuantity: nil, missingQuantity: nil, unitCode: nil)]) })
}
@main struct Check {
 @MainActor static func main() async {
  let now = instant("2026-10-17T07:00:00Z") // Shanghai 15:00: dinner is next.
  let app = QFAppSession()
  app.days["2026-10-17"] = .init(date: "2026-10-17", slots: [.init(meal: "DINNER", items: [
   plan("a"),plan("b"),plan("done", completed: true),plan("skip", skipped: true)])])
  app.available = availability(["a","b"])
  let service = QFNextMealReminderService()
  let result = await service.refresh(app: app, now: now)
  precondition(result?.plans.map(\.id) == ["a","b"], "All unfinished dishes must remain in next meal")
  precondition(result?.scheduledAt == instant("2026-10-17T10:00:00Z"))
  precondition(result?.reminderAt == instant("2026-10-17T09:30:00Z"))
  precondition(result?.materials.count == 2 && result?.materials.first?.availableQuantity == nil,
               "Unknown stock must stay unknown; shared stock is not summed")
  precondition(app.requests == ["settings","reminders","2026-10-17","availability"], "No unnecessary tomorrow request")
  app.master = false; app.requests = []
  precondition(await service.refresh(app: app, now: now) == nil)
  precondition(app.requests == ["settings"] && service.snapshot == nil, "Disabled master stops business lookups")
  app.master = true; app.availabilityFails = true
  let partial = await service.refresh(app: app, now: now)
  precondition(partial?.plans.count == 2 && partial?.materials.isEmpty == true && partial?.availabilityStatus == "UNAVAILABLE")
  app.availabilityFails = false; app.available = availability(["a","b"], revision: 4)
  precondition(await service.refresh(app: app, now: now) == nil, "Mismatched plan revision must not display")
  app.available = availability(["a","b"]); app.mutateOnAvailability = { app.interfaceLanguage = "en" }
  precondition(await service.refresh(app: app, now: now) == nil && service.snapshot == nil, "Old-language result must not display")
  app.mutateOnAvailability = nil; app.interfaceLanguage = "zh-Hans"
  for mutation in [
   { app.contentScope = "account2" },
   { app.planningHouseholdID = "other-household" },
   { app.user = nil }
  ] {
   app.mutateOnAvailability = mutation
   precondition(await service.refresh(app: app, now: now) == nil && service.snapshot == nil,
                "Account, household and sign-out transitions invalidate pending data")
   app.contentScope = "account1"; app.planningHouseholdID = nil; app.user = .init(userId:"u1")
  }
  app.mutateOnAvailability = nil
  let savedProfile = app.profile
  app.profile = .init(householdId:nil, timezone:"Asia/Shanghai", enabled:false, meals:savedProfile.meals)
  app.requests = []
  precondition(await service.refresh(app: app, now:now) == nil)
  precondition(app.requests == ["settings","reminders"], "Disabled profile never fetches plan or inventory")
  app.profile = savedProfile
  app.availabilityDelay = 25_000_000
  let pending = Task { await service.refresh(app: app, now: now) }
  try? await Task.sleep(nanoseconds: 5_000_000)
  service.cancel()
  precondition(await pending.value == nil && service.snapshot == nil, "Cancelled request cannot republish")
  app.availabilityDelay = 0
  app.days["2026-10-18"] = .init(date: "2026-10-18", slots: [.init(meal: "BREAKFAST", items: [plan("next", date: "2026-10-18", meal: "BREAKFAST")])])
  app.available = .init(date: "2026-10-18", householdId: nil, items: [.init(planId:"next",planRevision:3,status:"UNCONFIRMED",materials:[])])
  let tomorrow = await service.refresh(app: app, now: instant("2026-10-17T16:30:00Z")) // 18th 00:30
  precondition(tomorrow?.date == "2026-10-18" && tomorrow?.meal == "BREAKFAST", "Civil date follows reminder timezone")
  typealias Rule = QFNextMealReminderSelection.Rule
  let dstRules = [Rule(meal: "BREAKFAST", enabled: true, localTime: "02:30", advanceMinutes: 0)]
  let dstPlan = QFNextMealReminderSelection.Plan(id:"dst",recipeID:"r",title:"DST",servings:1,revision:0,contentAvailable:true,completed:false,skipped:false)
  let dst = QFNextMealReminderSelection.select(now: instant("2026-03-08T06:00:00Z"), timezone:"America/New_York", rules:dstRules,
    days:[.init(date:"2026-03-08",slots:[.init(meal:"BREAKFAST",plans:[dstPlan])])])
  precondition(dst?.scheduledAt == instant("2026-03-08T07:00:00Z"), "Missing DST time advances to first valid time")
  let repeatNode = QFNextMealReminderSelection.select(now: instant("2026-11-01T04:00:00Z"), timezone:"America/New_York",
    rules:[Rule(meal:"BREAKFAST",enabled:true,localTime:"01:30",advanceMinutes:0)],
    days:[.init(date:"2026-11-01",slots:[.init(meal:"BREAKFAST",plans:[dstPlan])])])
  precondition(repeatNode?.scheduledAt == instant("2026-11-01T05:30:00Z"), "Repeated DST time uses first occurrence")
  let disabled = QFNextMealReminderSelection.select(now:instant("2026-03-08T06:00:00Z"),timezone:"America/New_York",
   rules:[Rule(meal:"BREAKFAST",enabled:false,localTime:"02:30",advanceMinutes:0)],
   days:[.init(date:"2026-03-08",slots:[.init(meal:"BREAKFAST",plans:[dstPlan])])])
  precondition(disabled == nil, "Disabled meal must not remind even when a plan exists")
  let past = QFNextMealReminderSelection.select(now:instant("2026-03-08T07:01:00Z"),timezone:"America/New_York",rules:dstRules,
   days:[.init(date:"2026-03-08",slots:[.init(meal:"BREAKFAST",plans:[dstPlan])])])
  precondition(past == nil, "Unfinished past node is not a future reminder")
  precondition(QFNextMealReminderSelection.select(now:now,timezone:"invalid",rules:dstRules,days:[]) == nil)
  print("PASS next-meal group, same-scope stock, disabled master, midnight, DST, cancellation and revisions")
 }
}
'''
# Swift's precondition autoclosure cannot await; pull async expressions out first.
counter = 0
lines = []
for line in harness.splitlines():
    if 'precondition(await ' in line:
        counter += 1
        start = line.index('precondition(await ') + len('precondition(')
        expression_end = line.index(' == nil', start)
        expression = line[start:expression_end]
        lines.append(f'  let asyncValue{counter} = {expression}')
        line = line[:start] + f'asyncValue{counter}' + line[expression_end:]
    lines.append(line)
harness = '\n'.join(lines)
with tempfile.TemporaryDirectory(prefix='next-meal-', dir=root / '.build') as folder:
    folder = Path(folder)
    fixture = folder / 'Check.swift'
    fixture.write_text(harness)
    binary = folder / 'check'
    subprocess.run(['xcrun', 'swiftc', '-j1', '-parse-as-library', *map(str,sources), str(fixture), '-o', str(binary)], check=True, timeout=45)
    subprocess.run([str(binary)], check=True, timeout=10)
