import Foundation

struct QFNextMealReminderSnapshot {
  struct Plan {
    let id: String
    let recipeID: String
    let title: String?
    let servings: Int
    let revision: Int
    let contentAvailable: Bool
  }
  struct Material {
    let planID: String
    let ingredientID: String?
    let name: String
    let status: String
    let requiredQuantity: String?
    let availableQuantity: String?
    let missingQuantity: String?
    let unitCode: String?
  }
  let date: String
  let meal: String
  let timezone: String
  let scheduledAt: Date
  let reminderAt: Date
  let plans: [Plan]
  /// Keep each dish's needs separate: repeated available quantities refer to the same stock.
  let materials: [Material]
  let availabilityStatus: String
  let scope: String
  let householdID: String?
  let language: String
}

/// Read-only adapter over the existing settings, plans and ingredient-availability APIs.
/// The host explicitly refreshes on appearance/data changes; this service owns no timer.
@MainActor
final class QFNextMealReminderService {
  private(set) var snapshot: QFNextMealReminderSnapshot?
  private var requestID = UUID()
  private var task: Task<QFNextMealReminderSnapshot?, Never>?

  deinit { task?.cancel() }

  func cancel() {
    requestID = UUID()
    task?.cancel()
    task = nil
    snapshot = nil
  }

  @discardableResult
  func refresh(app: QFAppSession, now: Date = Date()) async -> QFNextMealReminderSnapshot? {
    cancel()
    guard let context = Context(app: app) else { return nil }
    let id = requestID
    let pending = Task { @MainActor [weak self] in
      guard let self else { return nil as QFNextMealReminderSnapshot? }
      return await QFContentLoadingContext.$forceRefresh.withValue(true) {
        await self.load(app: app, now: now, context: context, id: id)
      }
    }
    task = pending
    let result = await withTaskCancellationHandler {
      await pending.value
    } onCancel: {
      pending.cancel()
    }
    guard current(app: app, context: context, id: id) else { return nil }
    task = nil
    snapshot = result
    return result
  }

  private func load(app: QFAppSession, now: Date, context: Context, id: UUID) async -> QFNextMealReminderSnapshot? {
    do {
      let master = try await app.loadUserSettings()
      guard current(app: app, context: context, id: id), master.planReminders else { return nil }
      let settings = try await app.reminderSettings(householdID: context.householdID)
      guard current(app: app, context: context, id: id), settings.enabled,
        settings.householdId == context.householdID, let timezone = settings.timezone,
        let dates = QFNextMealReminderSelection.dates(now: now, timezone: timezone) else { return nil }
      let rules = settings.meals.map {
        QFNextMealReminderSelection.Rule(meal: $0.meal, enabled: $0.enabled,
          localTime: $0.localTime, advanceMinutes: $0.advanceMinutes)
      }
      guard rules.contains(where: \.enabled) else { return nil }
      var days: [QFNextMealReminderSelection.Day] = []
      var selected: QFNextMealReminderSelection.Node?
      // Fetch tomorrow only if today's enabled future nodes have no unfinished plans.
      for date in dates {
        let day = try await app.planDay(date: date, householdID: context.householdID)
        guard current(app: app, context: context, id: id), valid(day: day, date: date, context: context) else { return nil }
        days.append(.init(date: day.date, slots: day.slots.map { slot in
          .init(meal: slot.meal, plans: slot.items.map {
            .init(id: $0.id, recipeID: $0.recipeId, title: $0.title, servings: $0.servings,
              revision: $0.revision, contentAvailable: $0.contentAvailable,
              completed: $0.completed, skipped: $0.skipped)
          })
        }))
        selected = QFNextMealReminderSelection.select(now: now, timezone: timezone, rules: rules, days: days)
        if selected != nil { break }
      }
      guard let node = selected, current(app: app, context: context, id: id) else { return nil }
      let plans = node.plans.map {
        QFNextMealReminderSnapshot.Plan(id: $0.id, recipeID: $0.recipeID, title: $0.title,
          servings: $0.servings, revision: $0.revision, contentAvailable: $0.contentAvailable)
      }
      var materials: [QFNextMealReminderSnapshot.Material] = []
      var availabilityStatus = "SUCCEEDED"
      do {
        let availability = try await app.planAvailability(date: node.date, householdID: context.householdID)
        guard current(app: app, context: context, id: id), availability.date == node.date,
          availability.householdId == context.householdID,
          Set(availability.items.map(\.planId)).count == availability.items.count else { return nil }
        for plan in plans {
          guard let item = availability.items.first(where: { $0.planId == plan.id }),
            item.planRevision == plan.revision,
            ["AVAILABLE", "SHORT", "UNCONFIRMED"].contains(item.status),
            item.materials.allSatisfy({ ["AVAILABLE", "SHORT", "UNCONFIRMED"].contains($0.status) }) else { return nil }
          materials.append(contentsOf: item.materials.map {
            .init(planID: plan.id, ingredientID: $0.ingredientId, name: $0.name, status: $0.status,
              requiredQuantity: $0.requiredQuantity, availableQuantity: $0.availableQuantity,
              missingQuantity: $0.missingQuantity, unitCode: $0.unitCode)
          })
        }
      } catch {
        guard current(app: app, context: context, id: id) else { return nil }
        // A verified current-scope plan still matters when inventory temporarily fails.
        // No previous inventory or fabricated zero quantities enter this snapshot.
        availabilityStatus = "UNAVAILABLE"
        materials = []
      }
      guard current(app: app, context: context, id: id) else { return nil }
      return .init(date: node.date, meal: node.meal, timezone: timezone,
        scheduledAt: node.scheduledAt, reminderAt: node.reminderAt, plans: plans,
        materials: materials, availabilityStatus: availabilityStatus,
        scope: context.scope, householdID: context.householdID, language: context.language)
    } catch { return nil }
  }

  private func valid(day: QFPlanDay, date: String, context: Context) -> Bool {
    day.date == date && Set(day.slots.map(\.meal)).count == day.slots.count && day.slots.allSatisfy { slot in
      slot.items.allSatisfy {
        $0.date == date && $0.meal == slot.meal && $0.householdId == context.householdID
      }
    }
  }
  private func current(app: QFAppSession, context: Context, id: UUID) -> Bool {
    !Task.isCancelled && requestID == id && Context(app: app) == context
  }
  private struct Context: Equatable {
    let scope: String
    let householdID: String?
    let language: String
    let userID: String
    @MainActor init?(app: QFAppSession) {
      guard let userID = app.user?.userId else { return nil }
      self.userID = userID
      scope = app.contentScope
      householdID = app.planningHouseholdID
      language = app.interfaceLanguage
    }
  }
}
