import Foundation

struct QFBackfillCookingItem: Codable {
  var record: QFCookingRecord
  var recipeId: String?
}
struct QFCookingBatchItem: Codable {
  let id: String
  let recipeId: String?
  let title: String
  let meal: String
  let currency: String
  let materials: [QFWorkMaterial]
  let note: String
}
struct QFCookingBatchRequest: Codable {
  let requestId: String
  let date: String
  let householdId: String?
  let items: [QFCookingBatchItem]
}
struct QFCookingBatchResponse: Decodable {
  let requestId: String
  let items: [QFCookingRecord]
  let total: Int
}
struct QFBackfillCookingDraft: Codable {
  var date: String
  let householdId: String?
  var items: [QFBackfillCookingItem] = []
  var language: String
  var meal = "LUNCH"
  var pending: QFCookingBatchRequest?
  var ready: Bool {
    (1...30).contains(items.count) && QFManualPlanDraft.date(date).map { QFManualPlanDraft.string($0) == date } == true
      && Set(items.map { $0.record.id.lowercased() }).count == items.count && date <= QFContentDate.day(Date()) && items.allSatisfy {
      var record = $0.record; record.date = date; record.cost = nil
      return record.validation == nil && record.materials.allSatisfy { $0.ingredientId.flatMap(UUID.init(uuidString:)) != nil }
    }
  }
  mutating func prepare() -> Bool {
    if pending != nil { return true }
    guard ready else { return false }
    pending = QFCookingBatchRequest(requestId: UUID().uuidString.lowercased(), date: date, householdId: householdId,
      items: items.map { QFCookingBatchItem(id: $0.record.id, recipeId: $0.recipeId, title: $0.record.title,
        meal: $0.record.meal, currency: $0.record.currency, materials: $0.record.materials, note: $0.record.note) })
    return true
  }
}
