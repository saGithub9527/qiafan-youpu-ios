import Foundation

// MARK: - Households

struct QFHouseholdDraft: Encodable {
  let name: String
  let timezone: String
  let expectedRevision: Int?
}

struct QFHousehold: Decodable, Equatable {
  let id: String
  let name: String
  let timezone: String
  let status: String
  let role: String
  let memberCount: Int
  let revision: Int
  let createdAt: String
  let updatedAt: String
}

struct QFHouseholdMember: Decodable, Equatable {
  let publicUserId: String
  let nickname: String
  let avatarMediaId: String?
  let role: String
  let joinedAt: String
}

struct QFHouseholdMemberPage: Decodable {
  let items: [QFHouseholdMember]
  let total: Int
}

struct QFHouseholdInvitationDraft: Encodable {
  let role: String
  let expiresInHours: Int
  let maxUses: Int
}

struct QFHouseholdInvitation: Decodable, Equatable {
  let id: String
  let token: String?
  let role: String
  let expiresAt: String
  let maxUses: Int
  let usedCount: Int
  let status: String
}

struct QFHouseholdMemberRoleDraft: Encodable {
  let role: String
  let expectedRevision: Int
}

struct QFHouseholdOwnershipTransferDraft: Encodable {
  let publicUserId: String
  let expectedRevision: Int
}

// MARK: - Plans

struct QFPlannedMealDraft: Codable {
  var recipeId: String
  var date: String
  var meal: String
  var servings: Int
  var expectedRevision: Int? = nil
  var householdId: String? = nil
  var skipped: Bool? = nil
}

struct QFPlannedMeal: Codable, Equatable {
  let id: String
  let recipeId: String
  let title: String?
  let subtitle: String?
  let mediaId: String?
  let contentAvailable: Bool
  let date: String
  let meal: String
  let servings: Int
  let householdId: String?
  let revision: Int
  let completed: Bool
  let skipped: Bool

  private enum CodingKeys: String, CodingKey {
    case id, recipeId, title, subtitle, mediaId, contentAvailable, date, meal, servings
    case householdId, revision, completed, skipped
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    recipeId = try values.decode(String.self, forKey: .recipeId)
    title = try values.decodeIfPresent(String.self, forKey: .title)
    subtitle = try values.decodeIfPresent(String.self, forKey: .subtitle)
    mediaId = try values.decodeIfPresent(String.self, forKey: .mediaId)
    contentAvailable = try values.decodeIfPresent(Bool.self, forKey: .contentAvailable) ?? true
    date = try values.decode(String.self, forKey: .date)
    meal = try values.decode(String.self, forKey: .meal)
    servings = try values.decode(Int.self, forKey: .servings)
    householdId = try values.decodeIfPresent(String.self, forKey: .householdId)
    revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    completed = try values.decodeIfPresent(Bool.self, forKey: .completed) ?? false
    skipped = try values.decodeIfPresent(Bool.self, forKey: .skipped) ?? false
  }
}

struct QFPlanMealCount: Decodable, Equatable {
  let meal: String
  let total: Int
  let completed: Int
}

struct QFPlanCalendarDay: Decodable, Equatable {
  let date: String
  let total: Int
  let completed: Int
  let meals: [QFPlanMealCount]
}

struct QFPlanCalendar: Decodable, Equatable {
  let month: String
  let days: [QFPlanCalendarDay]
}

struct QFPlanSlot: Decodable, Equatable {
  let meal: String
  let revision: Int
  let items: [QFPlannedMeal]
}

struct QFPlanDay: Decodable, Equatable {
  let date: String
  let slots: [QFPlanSlot]
}

struct QFPlanMaterialAvailability: Decodable {
  let ingredientId: String?
  let name: String
  let status: String
  let requiredQuantity: String?
  let availableQuantity: String?
  let missingQuantity: String?
  let unitCode: String?
}

struct QFPlanAvailabilityItem: Decodable {
  let planId: String
  let planRevision: Int
  let status: String
  let materials: [QFPlanMaterialAvailability]
}

struct QFPlanAvailability: Decodable {
  let date: String
  let householdId: String?
  let items: [QFPlanAvailabilityItem]
}

struct QFPlanSlotItemDraft: Encodable {
  let id: String
  let recipeId: String
  let servings: Int
  let expectedRevision: Int?
}

struct QFPlanSlotReplaceDraft: Encodable {
  let householdId: String?
  let expectedSlotRevision: Int
  let items: [QFPlanSlotItemDraft]
}

struct QFPlanSlotReplaceResult: Decodable, Equatable {
  let date: String
  let meal: String
  let revision: Int
  let items: [QFPlannedMeal]
}

struct QFPreparationSourcePlan: Decodable, Equatable {
  let planId: String
  let planRevision: Int
  let recipeId: String
}

struct QFPreparationItem: Decodable, Equatable {
  let ingredientId: String?
  let name: String
  let quantityKind: String
  let quantityMin: String?
  let quantityMax: String?
  let unitCode: String?
  let quantityText: String?
  let requiresConfirmation: Bool
}

struct QFPreparationSummary: Decodable, Equatable {
  let startDate: String
  let endDate: String
  let householdId: String?
  let sourcePlans: [QFPreparationSourcePlan]
  let items: [QFPreparationItem]
  let warnings: [String]
}

// MARK: - Measurement and shopping

struct QFMeasurementUnit: Decodable, Equatable {
  let code: String
  let dimension: String
  let symbol: String
  let name: String
  let factorToBase: String
  let decimalAllowed: Bool
}

private struct QFCustomInventoryUnitDraft: Encodable {
  let label: String
  let householdId: String?
}

struct QFShoppingListGenerateDraft: Encodable {
  let startDate: String
  let endDate: String
  let householdId: String?
  let subtractInventory: Bool
}

struct QFShoppingItem: Decodable, Equatable {
  let id: String
  let ingredientId: String?
  let name: String
  let quantityKind: String
  let quantityMin: String?
  let quantityMax: String?
  let unitCode: String?
  let quantityText: String?
  let requiresConfirmation: Bool
  let checked: Bool
  let revision: Int
  var categoryCode: String? = nil; var iconKey: String? = nil
  var received: Bool? = nil
}

struct QFShoppingList: Decodable, Equatable {
  let id: String
  let householdId: String?
  let startDate: String
  let endDate: String
  let status: String
  let subtractInventory: Bool
  let language: String
  let revision: Int
  let items: [QFShoppingItem]
  let warnings: [String]
  let createdAt: String
  let updatedAt: String
}

struct QFShoppingItemPatch: Encodable {
  let checked: Bool?
  let quantityKind: String?
  let quantityMin: String?
  let quantityMax: String?
  let unitCode: String?
  let quantityText: String?
  let expectedRevision: Int
}

struct QFRevisionDraft: Encodable {
  let expectedRevision: Int
}

// MARK: - Inventory

struct QFInventoryLotDraft: Codable {
  let ingredientId: String
  let quantity: String
  let unitCode: String
  let expiresOn: String?
  let location: String
  let householdId: String?
  let expectedRevision: Int?
  let idempotencyKey: String
  var acquiredOn: String? = nil
  var acquiredTime: String? = nil
  var timeZone: String? = nil
  var currency: String? = nil
  var totalCost: String? = nil
  var packageUnit: String? = nil
  var packageSize: String? = nil
  var packageContentUnit: String? = nil
  var customIngredientName: String? = nil
}

struct QFInventoryLotBatchItem: Codable {
  let id: String
  let draft: QFInventoryLotDraft
}

struct QFInventoryLotBatch: Codable {
  let items: [QFInventoryLotBatchItem]
}

struct QFInventoryEditRequest: Codable, Equatable {
  let currentQuantity: String
  let unitCode: String
  let location: String
  let expectedRevision: Int
  let idempotencyKey: String
}

struct QFInventoryArchiveRequest: Codable, Equatable {
  let expectedRevision: Int
  let idempotencyKey: String
}

struct QFInventoryAdjustmentDraft: Encodable {
  let action: String
  let quantity: String
  let unitCode: String
  let note: String
  let expectedRevision: Int
  let idempotencyKey: String
}

struct QFInventoryConsumePlanDraft: Encodable {
  let cookingRecordId: String
  let idempotencyKey: String
}

struct QFInventoryLot: Codable, Equatable {
  let id: String
  let ingredientId: String
  let ingredientName: String?
  let mediaId: String?
  let contentAvailable: Bool
  let categoryCode: String?
  let unitCode: String
  let initialQuantity: String
  let currentQuantity: String
  let expiresOn: String?
  let location: String
  let householdId: String?
  let status: String
  let revision: Int
  var createdAt: String? = nil
  var acquiredOn: String? = nil
  var acquiredTime: String? = nil
  var timeZone: String? = nil
  var currency: String? = nil
  var totalCost: String? = nil
  var packageUnit: String? = nil
  var packageSize: String? = nil
  var packageContentUnit: String? = nil
  var hasMultipleCostSources: Bool? = nil
  var iconKey: String? = nil
  // Read-only summaries. currentQuantity and revision always belong to the real lot.
  var groupQuantity: String? = nil
  var groupLotCount: Int? = nil
  private var summedQuantity: String {
    guard (groupLotCount ?? 0) > 1, let total = groupQuantity,
      let sum = QFPurchaseNumber.decimal(total), let own = QFPurchaseNumber.decimal(currentQuantity), sum >= own else { return currentQuantity }
    return total
  }
  private var packageCount: Decimal? {
    guard hasMultipleCostSources != true, let packageUnit, ["bottle", "bag", "box", "pack"].contains(packageUnit),
      packageContentUnit == unitCode, let size = packageSize.flatMap(QFPurchaseNumber.decimal), size > 0,
      let amount = QFPurchaseNumber.decimal(summedQuantity) else { return nil }
    let count = amount / size
    return QFPurchaseNumber.decimal(QFPurchaseNumber.string(count)) == nil ? nil : count
  }
  var displayedQuantity: String { packageCount.map(QFPurchaseNumber.string) ?? summedQuantity }
  var displayedUnitCode: String { packageCount != nil ? packageUnit ?? unitCode : unitCode }
}

struct QFInventoryLedgerEntry: Codable, Equatable {
  let id: String
  let lotId: String
  let ingredientId: String
  let action: String
  let quantityDelta: String
  let unitCode: String
  let sourceType: String
  let sourceId: String
  let note: String
  let createdAt: String
}

struct QFInventoryDeductionJob: Decodable, Equatable {
  let id: String
  let plannedMealId: String
  let cookingRecordId: String
  let action: String
  let status: String
  let attempts: Int
  let lastError: String?
  let createdAt: String
  let updatedAt: String
}

// MARK: - Reminders and devices

struct QFMealReminderDraft: Encodable {
  let meal: String
  let enabled: Bool
  let localTime: String
  let advanceMinutes: Int
}

struct QFReminderSettingsDraft: Encodable {
  let householdId: String?
  let timezone: String
  let enabled: Bool
  let expectedRevision: Int?
  let meals: [QFMealReminderDraft]
}

struct QFMealReminder: Decodable, Equatable {
  let meal: String
  let enabled: Bool
  let localTime: String
  let advanceMinutes: Int
  static let defaults: [QFMealReminder] = [
    .init(meal: "BREAKFAST", enabled: true, localTime: "08:00", advanceMinutes: 0),
    .init(meal: "LUNCH", enabled: true, localTime: "12:00", advanceMinutes: 0),
    .init(meal: "DINNER", enabled: true, localTime: "18:00", advanceMinutes: 0),
    .init(meal: "SNACK", enabled: false, localTime: "15:00", advanceMinutes: 0),
  ]
}

struct QFReminderSettings: Decodable, Equatable {
  let id: String?
  let householdId: String?
  let timezone: String?
  let enabled: Bool
  let revision: Int?
  let meals: [QFMealReminder]
}

struct QFPushDeviceDraft: Encodable {
  let provider: String
  let cid: String
  let platform: String
  let language: String
  let expectedRevision: Int?
}

struct QFPushDevice: Decodable, Equatable {
  let deviceId: String
  let provider: String
  let platform: String
  let language: String
  let status: String
  let revision: Int
}

// MARK: - AI weekly plan proposals

struct QFWeeklyPlanProposalDraft: Encodable {
  let weekStart: String
  let householdId: String?
  let meals: [String]
  let servings: Int
  let budget: String?
  let currency: String?
  let maxMinutesPerDay: Int?
  let excludedIngredientIds: [String]
  let mustUseInventory: Bool
  let preference: String
  let idempotencyKey: String
}

struct QFWeeklyPlanProposalItem: Decodable, Equatable {
  let date: String
  let meal: String
  let recipeId: String
  let title: String?
  let contentAvailable: Bool
  let servings: Int
  let expectedSlotRevision: Int
}

struct QFWeeklyPlanProposal: Decodable, Equatable {
  let id: String
  let weekStart: String
  let householdId: String?
  let language: String
  let status: String
  let sourceModel: String?
  let lastError: String?
  let revision: Int
  let items: [QFWeeklyPlanProposalItem]
  let createdAt: String
  let updatedAt: String
  let acceptedAt: String?
}

struct QFAssistantPreviewRequest: Encodable {
  let text: String
  let allowCloud: Bool
}

struct QFAssistantMemory: Decodable, Equatable {
  let id: String
  let scope: String
  let language: String
  let memoryType: String
  let content: String
  let source: String
  let createdAt: String
  let updatedAt: String
}

struct QFAssistantMemoryPage: Decodable, Equatable {
  let items: [QFAssistantMemory]
  let page: Int
  let pageSize: Int
  let total: Int
}

struct QFAssistantMemoryDraft: Encodable {
  let content: String
  let memoryType: String
  let remember: Bool
}

struct QFAssistantCreditSnapshot: Decodable, Equatable {
  let billingEnabled: Bool
  let balanceUnits: Int
  let requestCostUnits: Int
}

struct QFAssistantNotificationSettings: Decodable, Equatable {
  let enabled: Bool
  let dailyEnabled: Bool
  let inactiveEnabled: Bool
  let timezone: String
  let quietStart: String
  let quietEnd: String
  let maxPerDay: Int
  let revision: Int
}

struct QFAssistantNotificationSettingsDraft: Encodable {
  let enabled: Bool
  let dailyEnabled: Bool
  let inactiveEnabled: Bool
  let timezone: String
  let quietStart: String
  let quietEnd: String
  let maxPerDay: Int
  let expectedRevision: Int
}

struct QFAssistantIngredient: Decodable, Equatable {
  let name: String
  let quantity: String
  let unit: String
}

struct QFAssistantAction: Decodable, Equatable {
  let type: String
  let enabled: Bool
  let reasonCode: String?

  init(type: String, enabled: Bool = true, reasonCode: String? = nil) {
    self.type = type
    self.enabled = enabled
    self.reasonCode = reasonCode
  }
}

struct QFAssistantPreview: Decodable, Equatable {
  let kind: String
  let answer: String
  let title: String
  let body: String
  let ingredients: [QFAssistantIngredient]
  let steps: [String]
  let requiresReview: Bool
  /// Older local preview fixtures predate action metadata; derive a safe
  /// fallback in the editor screen rather than rejecting the whole preview.
  let actions: [QFAssistantAction]

  private enum CodingKeys: String, CodingKey {
    case kind, answer, title, body, ingredients, steps, requiresReview, actions
  }

  init(
    kind: String, answer: String, title: String, body: String,
    ingredients: [QFAssistantIngredient], steps: [String], requiresReview: Bool,
    actions: [QFAssistantAction] = []
  ) {
    self.kind = kind
    self.answer = answer
    self.title = title
    self.body = body
    self.ingredients = ingredients
    self.steps = steps
    self.requiresReview = requiresReview
    self.actions = actions
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    kind = try values.decode(String.self, forKey: .kind)
    answer = try values.decode(String.self, forKey: .answer)
    title = try values.decode(String.self, forKey: .title)
    body = try values.decode(String.self, forKey: .body)
    ingredients = try values.decode([QFAssistantIngredient].self, forKey: .ingredients)
    steps = try values.decode([String].self, forKey: .steps)
    requiresReview = try values.decode(Bool.self, forKey: .requiresReview)
    actions = try values.decodeIfPresent([QFAssistantAction].self, forKey: .actions) ?? []
  }
}

// MARK: - Typed API surface

@MainActor
extension QFAppSession {
  func assistantPreview(text: String) async throws -> QFAssistantPreview {
    try await contentRequest(path: "me/assistant/preview", method: "POST",
      body: try planningBody(QFAssistantPreviewRequest(text: text, allowCloud: true)))
  }
  func assistantMemories(page: Int = 1) async throws -> QFAssistantMemoryPage {
    try await contentRequest(path: "me/assistant/memories", query: ["page": String(max(1, page))])
  }
  func saveAssistantMemory(_ draft: QFAssistantMemoryDraft) async throws -> QFAssistantMemory {
    try await contentRequest(path: "me/assistant/memories", method: "POST", body: try planningBody(draft))
  }
  func deleteAssistantMemory(_ id: String) async throws {
    try await contentMutation(path: "me/assistant/memories/\(id)", method: "DELETE")
  }
  func assistantCreditSnapshot() async throws -> QFAssistantCreditSnapshot {
    try await contentRequest(path: "me/assistant/credits")
  }

  func assistantNotificationSettings() async throws -> QFAssistantNotificationSettings {
    try await contentRequest(path: "me/assistant/notifications")
  }
  func saveAssistantNotificationSettings(_ draft: QFAssistantNotificationSettingsDraft) async throws -> QFAssistantNotificationSettings {
    try await contentRequest(path: "me/assistant/notifications", method: "PUT", body: try planningBody(draft))
  }
  func touchAssistantNotificationActivity(assistantInteraction: Bool) async throws {
    try await contentMutation(path: "me/assistant/notifications/activity", method: "POST",
      body: try planningBody(["assistantInteraction": assistantInteraction]))
  }
  func households() async throws -> [QFHousehold] {
    try await contentRequest(path: "me/households")
  }

  func household(_ id: String) async throws -> QFHousehold {
    try await contentRequest(path: "me/households/\(id)")
  }

  func saveHousehold(_ id: String, draft: QFHouseholdDraft) async throws -> QFHousehold {
    try await contentRequest(
      path: "me/households/\(id)", method: "PUT", body: try planningBody(draft))
  }

  func dissolveHousehold(_ id: String, expectedRevision: Int) async throws {
    try await contentMutation(
      path: "me/households/\(id)", method: "DELETE",
      query: ["expectedRevision": String(expectedRevision)])
  }

  func householdMembers(_ id: String, page: Int) async throws -> QFHouseholdMemberPage {
    try await contentRequest(
      path: "me/households/\(id)/members", query: ["page": String(page)])
  }

  func createHouseholdInvitation(
    _ id: String, draft: QFHouseholdInvitationDraft
  ) async throws -> QFHouseholdInvitation {
    try await contentRequest(
      path: "me/households/\(id)/invitations", method: "POST",
      body: try planningBody(draft))
  }

  func revokeHouseholdInvitation(_ householdID: String, invitationID: String) async throws {
    try await contentMutation(
      path: "me/households/\(householdID)/invitations/\(invitationID)", method: "DELETE")
  }

  func acceptHouseholdInvitation(_ token: String) async throws -> QFHousehold {
    try await contentRequest(path: "me/household-invitations/\(token)/accept", method: "POST")
  }

  func changeHouseholdMemberRole(
    householdID: String, publicUserID: String, draft: QFHouseholdMemberRoleDraft
  ) async throws -> QFHouseholdMember {
    try await contentRequest(
      path: "me/households/\(householdID)/members/\(publicUserID)", method: "PATCH",
      body: try planningBody(draft))
  }

  func removeHouseholdMember(householdID: String, publicUserID: String) async throws {
    try await contentMutation(
      path: "me/households/\(householdID)/members/\(publicUserID)", method: "DELETE")
  }

  func transferHouseholdOwnership(
    _ householdID: String, draft: QFHouseholdOwnershipTransferDraft
  ) async throws -> QFHousehold {
    try await contentRequest(
      path: "me/households/\(householdID)/ownership-transfer", method: "POST",
      body: try planningBody(draft))
  }

  func planCalendar(month: String, householdID: String? = nil) async throws -> QFPlanCalendar {
    try await contentRequest(
      path: "me/planned-meals/calendar",
      query: planningQuery(("month", month), ("householdId", householdID)))
  }

  func planDay(date: String, householdID: String? = nil) async throws -> QFPlanDay {
    try await contentRequest(
      path: "me/planned-meals/day",
      query: planningQuery(("date", date), ("householdId", householdID)))
  }

  func planAvailability(date: String, householdID: String? = nil) async throws -> QFPlanAvailability {
    try await contentRequest(
      path: "me/planned-meals/availability",
      query: planningQuery(("date", date), ("householdId", householdID)))
  }

  func plannedMeals(
    recipeID: String? = nil, startDate: String? = nil, endDate: String? = nil,
    meal: String? = nil, page: Int = 0, householdID: String? = nil
  ) async throws -> QFContentPage<QFPlannedMeal> {
    try await contentRequest(
      path: "me/planned-meals",
      query: planningQuery(
        ("recipeId", recipeID), ("startDate", startDate), ("endDate", endDate),
        ("meal", meal), ("page", String(page)), ("householdId", householdID)))
  }

  func plannedMeal(_ id: String) async throws -> QFPlannedMeal {
    try await contentRequest(path: "me/planned-meals/\(id)")
  }

  func savePlannedMeal(_ id: String, draft: QFPlannedMealDraft) async throws -> QFPlannedMeal {
    try await contentRequest(
      path: "me/planned-meals/\(id)", method: "PUT", body: try planningBody(draft))
  }

  func deletePlannedMeal(_ id: String, expectedRevision: Int? = nil) async throws {
    try await contentMutation(
      path: "me/planned-meals/\(id)", method: "DELETE",
      query: planningQuery(("expectedRevision", expectedRevision.map(String.init))))
  }

  func replacePlanSlot(
    date: String, meal: String, draft: QFPlanSlotReplaceDraft
  ) async throws -> QFPlanSlotReplaceResult {
    try await contentRequest(
      path: "me/planned-meal-slots/\(date)/\(meal)", method: "PUT",
      body: try planningBody(draft))
  }

  func clearPlanSlot(
    date: String, meal: String, householdID: String?, expectedSlotRevision: Int
  ) async throws -> QFPlanSlotReplaceResult {
    try await contentRequest(
      path: "me/planned-meal-slots/\(date)/\(meal)", method: "DELETE",
      query: planningQuery(
        ("householdId", householdID),
        ("expectedSlotRevision", String(expectedSlotRevision))))
  }

  func planPreparation(
    startDate: String, endDate: String, householdID: String? = nil
  ) async throws -> QFPreparationSummary {
    try await contentRequest(
      path: "me/planned-meals/preparation",
      query: planningQuery(
        ("startDate", startDate), ("endDate", endDate), ("householdId", householdID)))
  }

  func measurementUnits() async throws -> [QFMeasurementUnit] {
    try await contentRequest(path: "measurement-units")
  }

  func inventoryMeasurementUnits(householdID: String?) async throws -> [QFMeasurementUnit] {
    try await contentRequest(path: "me/inventory/units", query: planningQuery(("householdId", householdID)))
  }

  func createInventoryUnit(label: String, householdID: String?) async throws -> QFMeasurementUnit {
    try await contentRequest(path: "me/inventory/units", method: "POST", body: try planningBody(QFCustomInventoryUnitDraft(label: label, householdId: householdID)))
  }

  func shoppingLists(
    householdID: String? = nil, page: Int = 0
  ) async throws -> QFContentPage<QFShoppingList> {
    try await contentRequest(
      path: "me/shopping-lists",
      query: planningQuery(("householdId", householdID), ("page", String(page))))
  }

  func shoppingList(_ id: String) async throws -> QFShoppingList {
    try await contentRequest(path: "me/shopping-lists/\(id)")
  }

  func generateShoppingList(
    _ draft: QFShoppingListGenerateDraft
  ) async throws -> QFShoppingList {
    try await contentRequest(
      path: "me/shopping-lists/generate", method: "POST", body: try planningBody(draft))
  }

  func regenerateShoppingList(_ id: String) async throws -> QFShoppingList {
    try await contentRequest(path: "me/shopping-lists/\(id)/regenerate", method: "POST")
  }

  func updateShoppingItem(
    listID: String, itemID: String, patch: QFShoppingItemPatch
  ) async throws -> QFShoppingItem {
    try await contentRequest(
      path: "me/shopping-lists/\(listID)/items/\(itemID)", method: "PATCH",
      body: try planningBody(patch))
  }

  func confirmShoppingList(_ id: String, expectedRevision: Int) async throws -> QFShoppingList {
    try await contentRequest(
      path: "me/shopping-lists/\(id)/confirm", method: "POST",
      body: try planningBody(QFRevisionDraft(expectedRevision: expectedRevision)))
  }

  func deleteShoppingList(_ id: String) async throws {
    try await contentMutation(path: "me/shopping-lists/\(id)", method: "DELETE")
  }

  func inventoryLots(
    householdID: String? = nil, category: String? = nil, query: String = "", page: Int = 0, expiry: String? = nil,
    groupByProduct: Bool = false, ingredientID: String? = nil
  ) async throws -> QFContentPage<QFInventoryLot> {
    try await contentRequest(
      path: "me/inventory",
      query: planningQuery(
        ("householdId", householdID), ("category", category), ("q", query),
        ("page", String(page)), ("expiry", expiry), ("timeZone", TimeZone.current.identifier),
        ("groupByProduct", groupByProduct ? "true" : nil), ("ingredientId", ingredientID)))
  }

  func inventoryLedger(
    householdID: String? = nil, ingredientID: String? = nil, page: Int = 0
  ) async throws -> QFContentPage<QFInventoryLedgerEntry> {
    try await contentRequest(
      path: "me/inventory/ledger",
      query: planningQuery(
        ("householdId", householdID), ("ingredientId", ingredientID),
        ("page", String(page))))
  }

  func saveInventoryLot(_ id: String, draft: QFInventoryLotDraft) async throws -> QFInventoryLot {
    try await contentRequest(
      path: "me/inventory/lots/\(id)", method: "PUT", body: try planningBody(draft))
  }

  func saveInventoryLots(_ batch: QFInventoryLotBatch) async throws -> [QFInventoryLot] {
    try await contentRequest(path: "me/inventory/lots/batch", method: "POST", body: try planningBody(batch))
  }

  func editInventoryLot(_ id: String, draft: QFInventoryEditRequest) async throws -> QFInventoryLot {
    try await contentRequest(path: "me/inventory/lots/\(id)", method: "PATCH", body: try planningBody(draft))
  }

  func archiveInventoryLot(_ id: String, draft: QFInventoryArchiveRequest) async throws -> QFInventoryLot {
    try await contentRequest(path: "me/inventory/lots/\(id)", method: "DELETE", body: try planningBody(draft))
  }

  func adjustInventoryLot(
    _ id: String, draft: QFInventoryAdjustmentDraft
  ) async throws -> QFInventoryLot {
    try await contentRequest(
      path: "me/inventory/lots/\(id)/adjustments", method: "POST",
      body: try planningBody(draft))
  }

  func consumeInventory(
    plannedMealID: String, draft: QFInventoryConsumePlanDraft
  ) async throws -> QFInventoryDeductionJob {
    try await contentRequest(
      path: "me/inventory/consume-plan/\(plannedMealID)", method: "POST",
      body: try planningBody(draft))
  }

  func inventoryDeductionJob(_ id: String) async throws -> QFInventoryDeductionJob {
    try await contentRequest(path: "me/inventory/deduction-jobs/\(id)")
  }

  func retryInventoryDeductionJob(_ id: String) async throws -> QFInventoryDeductionJob {
    try await contentRequest(path: "me/inventory/deduction-jobs/\(id)/retry", method: "POST")
  }

  func cancelInventoryDeductionJob(_ id: String) async throws {
    try await contentMutation(path: "me/inventory/deduction-jobs/\(id)", method: "DELETE")
  }

  func reminderSettings(householdID: String? = nil) async throws -> QFReminderSettings {
    try await contentRequest(
      path: "me/plan-reminder", query: planningQuery(("householdId", householdID)))
  }

  func saveReminderSettings(_ draft: QFReminderSettingsDraft) async throws -> QFReminderSettings {
    let binding = QFAssistantAgent.scope(self)
    let saved: QFReminderSettings = try await contentRequest(
      path: "me/plan-reminder", method: "PUT", body: try planningBody(draft))
    guard binding == QFAssistantAgent.scope(self) else { throw CancellationError() }
    if saved.enabled {
      // A successful enabled profile guarantees the server master is on. Keep
      // this confirmed change even if the following read is temporarily offline.
      let local = QFLocalSettingsStore.current(scope: contentScope)
      if !local.planReminders {
        QFLocalSettingsStore.save(.init(theme: local.theme, interfaceLanguage: interfaceLanguage,
          planReminders: true, workAndContributionUpdates: local.workAndContributionUpdates), scope: contentScope)
      }
    }
    // The server master is enabled if any reminder profile is enabled. Read it
    // rather than equating one household profile with the account-wide switch.
    if let master = try? await QFContentLoadingContext.$forceRefresh.withValue(true, operation: { try await self.loadUserSettings() }),
      binding == QFAssistantAgent.scope(self) {
      QFLocalSettingsStore.save(.init(theme: master.theme, interfaceLanguage: interfaceLanguage,
        planReminders: master.planReminders, workAndContributionUpdates: master.workAndContributionUpdates), scope: contentScope)
    }
    return saved
  }

  func savePushDevice(_ deviceID: String, draft: QFPushDeviceDraft) async throws -> QFPushDevice {
    try await contentRequest(
      path: "me/push-devices/\(deviceID)", method: "PUT", body: try planningBody(draft))
  }

  func deletePushDevice(_ deviceID: String) async throws {
    try await contentMutation(path: "me/push-devices/\(deviceID)", method: "DELETE")
  }

  func createWeeklyPlanProposal(
    _ draft: QFWeeklyPlanProposalDraft
  ) async throws -> QFWeeklyPlanProposal {
    try await contentRequest(
      path: "me/weekly-plan-proposals", method: "POST", body: try planningBody(draft))
  }

  func weeklyPlanProposals(
    householdID: String? = nil, page: Int = 0
  ) async throws -> QFContentPage<QFWeeklyPlanProposal> {
    try await contentRequest(
      path: "me/weekly-plan-proposals",
      query: planningQuery(("householdId", householdID), ("page", String(page))))
  }

  func weeklyPlanProposal(_ id: String) async throws -> QFWeeklyPlanProposal {
    try await contentRequest(path: "me/weekly-plan-proposals/\(id)")
  }

  func acceptWeeklyPlanProposal(
    _ id: String, expectedRevision: Int
  ) async throws -> QFWeeklyPlanProposal {
    try await contentRequest(
      path: "me/weekly-plan-proposals/\(id)/accept", method: "POST",
      body: try planningBody(QFRevisionDraft(expectedRevision: expectedRevision)))
  }

  func cancelWeeklyPlanProposal(_ id: String, expectedRevision: Int) async throws {
    try await contentMutation(
      path: "me/weekly-plan-proposals/\(id)", method: "DELETE",
      query: ["expectedRevision": String(expectedRevision)])
  }

  private func planningBody<Value: Encodable>(_ value: Value) throws -> Data {
    try JSONEncoder().encode(value)
  }

  private func planningQuery(_ values: (String, String?)...) -> [String: String] {
    Dictionary(uniqueKeysWithValues: values.compactMap { pair -> (String, String)? in
      let (key, value) = pair
      guard let value, !value.isEmpty else { return nil }
      return (key, value)
    })
  }
}
