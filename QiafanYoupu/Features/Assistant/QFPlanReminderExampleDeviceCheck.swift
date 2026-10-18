#if DEBUG
import Foundation
import UIKit

/// A one-item user-authorized acceptance action. The frozen batch receipt is
/// saved before transmission and reused after any uncertain interruption.
@MainActor
enum QFPlanReminderExampleDeviceCheck {
  private static var task: Task<Void, Never>?
  static func cancel() { task?.cancel() }
  static func start(app: QFAppSession, arguments: [String]) {
    task = Task { await run(app: app, arguments: arguments); task = nil }
  }
  private static func run(app: QFAppSession, arguments: [String]) async {
    let index = arguments.firstIndex(of: "-QFCheckRun")
    let runID = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "manual"
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let output = folder.appendingPathComponent("plan-reminder-example-check.json")
    var report: [String: Any] = ["runID": runID, "status": "IN_PROGRESS", "cloudModelCalls": 0,
      "businessWriteAuthorized": "one appended plan and enabling its existing reminder settings"]
    func save() {
      if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? bytes.write(to: output, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      }
    }
    save()
    let idle = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true
    defer { UIApplication.shared.isIdleTimerDisabled = idle }
    do {
      let signInDeadline = Date().addingTimeInterval(20)
      while app.user == nil, Date() < signInDeadline { try await Task.sleep(nanoseconds: 250_000_000) }
      report["signedIn"] = app.user != nil
      report["environmentHost"] = app.api.environment.baseURL?.host ?? ""
      guard app.user != nil, app.api.environment.baseURL?.host == "test-api.yzsalingo.com" else { throw Failure("SIGNED_IN_TEST_ACCOUNT_REQUIRED") }
      let binding = QFAssistantAgent.scope(app)
      func check() throws { try Task.checkCancellation(); guard binding == QFAssistantAgent.scope(app) else { throw CancellationError() } }
      let defaults = UserDefaults.standard
      let key = "qf.acceptance.plan-reminder.20261017." + binding.account + "." + (binding.household ?? "personal")
      report["networkPreferenceStored"] = defaults.object(forKey: QFLocalModelViewController.networkKey(app)) ?? NSNull()
      report["networkEffective"] = QFLocalModelViewController.networkEnabled(app)
      let original = try await app.reminderSettings(householdID: binding.household)
      try check()
      report["reminderProfileInitiallyExists"] = original.id != nil
      report["reminderRulesInitiallyCount"] = original.meals.count
      if arguments.contains("-QFReusePlanReminderExampleOnly"), defaults.data(forKey: key + ".pending") == nil {
        throw Failure("EXISTING_FROZEN_RECEIPT_REQUIRED")
      }
      var pending: QFManualPlanDraft.Pending
      if let data = defaults.data(forKey: key + ".pending") {
        pending = try JSONDecoder().decode(QFManualPlanDraft.Pending.self, from: data)
        guard pending.language == binding.language, pending.body.householdId == binding.household,
          pending.body.startDate == pending.body.endDate, pending.body.meals.count == 1,
          pending.body.meals[0].items.count == 1 else { throw Failure("FROZEN_RECEIPT_SCOPE_MISMATCH") }
      } else {
        let zone = original.timezone.flatMap(TimeZone.init(identifier:))?.identifier ?? TimeZone.current.identifier
        guard let dates = QFNextMealReminderSelection.dates(now: Date(), timezone: zone) else { throw Failure("INVALID_TIMEZONE") }
        let rules = (original.id == nil ? QFMealReminder.defaults : original.meals).filter { ["BREAKFAST", "LUNCH", "DINNER"].contains($0.meal) }.map {
          QFNextMealReminderSelection.Rule(meal: $0.meal, enabled: true, localTime: $0.localTime, advanceMinutes: $0.advanceMinutes)
        }
        let placeholder = QFNextMealReminderSelection.Plan(id: "selection", recipeID: "selection", title: nil,
          servings: 1, revision: 0, contentAvailable: true, completed: false, skipped: false)
        let days = dates.map { QFNextMealReminderSelection.Day(date: $0, slots: rules.map { .init(meal: $0.meal, plans: [placeholder]) }) }
        guard let next = QFNextMealReminderSelection.select(now: Date(), timezone: zone, rules: rules, days: days) else { throw Failure("NO_UPCOMING_MEAL") }
        let before = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.planDay(date: next.date, householdID: binding.household) }
        try check()
        let existing = Set(before.slots.first(where: { $0.meal == next.meal })?.items.map(\.recipeId) ?? [])
        let page: QFContentPage<QFRecipeHomeItem> = try await app.publicContentRequest(path: "home/recipes", query: ["q": "番茄炒蛋", "page": "0"])
        var candidate = page.items.first { !existing.contains($0.id) }
        if candidate == nil {
          let fallback: QFContentPage<QFRecipeHomeItem> = try await app.publicContentRequest(path: "home/recipes", query: ["page": "0"])
          candidate = fallback.items.first { !existing.contains($0.id) }
        }
        guard let candidate else { throw Failure("NO_NEW_PUBLISHED_RECIPE") }
        let detail: QFRecipeHomeDetail = try await app.publicContentRequest(path: "home/recipes/" + candidate.id)
        try check()
        guard detail.id == candidate.id, detail.contentAvailable == true, detail.contentLanguage == binding.language else { throw Failure("PUBLISHED_RECIPE_UNAVAILABLE") }
        pending = .init(body: .init(requestId: UUID(), householdId: binding.household,
          startDate: next.date, endDate: next.date, weekdays: [],
          meals: [.init(meal: next.meal, items: [.init(recipeId: detail.id, servings: 1)])]), language: binding.language)
        // Never replace this body after a timeout; one user request must not create a second batch.
        defaults.set(try JSONEncoder().encode(pending), forKey: key + ".pending")
        let beforeProfile: [String: Any] = ["enabled": original.enabled, "timezone": original.timezone.map { $0 as Any } ?? NSNull(),
          "revision": original.revision.map { $0 as Any } ?? NSNull(), "meals": original.meals.map { ["meal": $0.meal, "enabled": $0.enabled, "localTime": $0.localTime, "advanceMinutes": $0.advanceMinutes] as [String: Any] }]
        defaults.set(try JSONSerialization.data(withJSONObject: beforeProfile), forKey: key + ".reminder-before")
      }
      let date = pending.body.startDate, meal = pending.body.meals[0].meal, recipeID = pending.body.meals[0].items[0].recipeId
      let before = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.planDay(date: date, householdID: binding.household) }
      try check()
      let beforeIDs = Set(before.slots.flatMap(\.items).map(\.id))
      report["phase"] = "append-one-plan"; report["requestID"] = pending.body.requestId.uuidString.lowercased(); save()
      let result = try await app.appendPlanBatch(pending)
      try check()
      guard result.requestId == pending.body.requestId, result.addedCount == 1,
        result.days.count == 1, result.days[0].date == date else { throw Failure("ONE_PLAN_RECEIPT_NOT_CONFIRMED") }
      let after = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.planDay(date: date, householdID: binding.household) }
      let afterIDs = Set(after.slots.flatMap(\.items).map(\.id))
      guard beforeIDs.isSubset(of: afterIDs), afterIDs.subtracting(beforeIDs).count <= 1,
        let created = after.slots.first(where: { $0.meal == meal })?.items.first(where: { $0.recipeId == recipeID && !$0.completed && !$0.skipped }) else { throw Failure("CREATED_PLAN_READBACK_FAILED") }
      report["createdPlan"] = ["id": created.id, "date": created.date, "meal": created.meal,
        "recipeID": created.recipeId, "title": created.title ?? "", "servings": created.servings,
        "addedCountFromIdempotentReceipt": result.addedCount, "newIDsThisRun": afterIDs.subtracting(beforeIDs).count,
        "existingPlansRetained": true]
      report["phase"] = "enable-existing-reminder"; save()
      let current = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.reminderSettings(householdID: binding.household) }
      try check()
      let currentMeals = current.id == nil ? QFMealReminder.defaults : current.meals
      guard Set(currentMeals.map(\.meal)) == Set(["BREAKFAST", "LUNCH", "DINNER", "SNACK"]) else { throw Failure("INCOMPLETE_MEAL_RULES") }
      if !current.enabled || current.meals.first(where: { $0.meal == meal })?.enabled != true {
        _ = try await app.saveReminderSettings(.init(householdId: binding.household,
          timezone: current.timezone.flatMap(TimeZone.init(identifier:))?.identifier ?? TimeZone.current.identifier, enabled: true,
          expectedRevision: current.revision, meals: currentMeals.map {
            .init(meal: $0.meal, enabled: $0.meal == meal ? true : (current.id == nil ? false : $0.enabled), localTime: $0.localTime, advanceMinutes: $0.advanceMinutes)
          }))
      }
      let master = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.loadUserSettings() }
      try check()
      guard master.planReminders else { throw Failure("REMINDER_MASTER_NOT_ENABLED") }
      QFLocalSettingsStore.save(.init(theme: master.theme, interfaceLanguage: app.interfaceLanguage,
        planReminders: master.planReminders, workAndContributionUpdates: master.workAndContributionUpdates), scope: app.contentScope)
      let service = QFNextMealReminderService()
      guard let snapshot = await service.refresh(app: app), snapshot.plans.contains(where: { $0.id == created.id }) else { throw Failure("NEXT_MEAL_SNAPSHOT_NOT_CONFIRMED") }
      try check()
      report["phase"] = "verify-home-display"; save()
      let ui = try await QFPlanReminderPresentationCheck.verify(app: app, plannedMealID: created.id)
      try check()
      report["homePresentation"] = ui
      report["reminder"] = ["enabled": true, "date": snapshot.date, "meal": snapshot.meal,
        "timezone": snapshot.timezone, "scheduledAt": ISO8601DateFormatter().string(from: snapshot.scheduledAt),
        "availabilityStatus": snapshot.availabilityStatus, "materialCount": snapshot.materials.count,
        "unconfirmedMaterialCount": snapshot.materials.filter { $0.status == "UNCONFIRMED" }.count,
        "text": QFDigitalAssistantOverlay.mealReminderText(snapshot, app: app)]
      report["status"] = "PLAN_CREATED_AND_HOME_REMINDER_VERIFIED"
      report["phase"] = "complete"; save()
      defaults.set(created.id, forKey: key + ".created-plan-id")
    } catch {
      report["status"] = "FAILED"; report["failure"] = String(describing: error); save()
    }
  }
  private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
  }
}
#endif
