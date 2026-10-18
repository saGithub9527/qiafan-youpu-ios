import Foundation

struct QFPreparationExpenses: Codable {
  struct Point: Codable { let date: String; let totals: [QFCurrencyTotal] }
  let startDate: String
  let endDate: String
  let purchaseTotals: [QFCurrencyTotal]
  let consumptionTotals: [QFCurrencyTotal]
  let purchaseCount: Int
  let cookingCount: Int
  let pendingPurchaseCount: Int
  let pendingMaterialCount: Int
  let trend: [Point]
}
struct QFPurchaseReceiptPage: Decodable {
  let items: [QFPurchaseReceipt]
  let total: Int
  let totals: [QFCurrencyTotal]
  let pendingPriceCount: Int
}
struct QFCookingCost: Codable {
  struct Source: Codable {
    let lotId: String
    let sourceId: String
    let originalQuantity: String
    let unitCode: String
    let date: String?
    let currency: String?
    let totalCost: String?
    let revision: Int
    var time: String? = nil
    var timeZone: String? = nil
    var packageUnit: String? = nil
    var packageSize: String? = nil
    var packageContentUnit: String? = nil
    var receiptId: String? = nil
  }
  struct Material: Codable {
    let ingredientId: String?
    let name: String
    let quantity: String
    let unitCode: String
    let totals: [QFCurrencyTotal]
    let status: String
    let sources: [Source]
  }
  let recordId: String
  let date: String
  let title: String
  let meal: String
  let valuationRevision: Int
  let status: String
  let totals: [QFCurrencyTotal]
  let pendingMaterialCount: Int
  let materials: [Material]
}
struct QFCookingCostPage: Decodable {
  let items: [QFCookingCost]
  let total: Int
  let totals: [QFCurrencyTotal]
  let pendingMaterialCount: Int
}
struct QFInventoryCostRequest: Codable, Equatable {
  let requestId: UUID
  let expectedRevision: Int
  let sourceId: String
  let originalQuantity: String
  let unitCode: String
  let date: String
  let time: String?
  let timeZone: String
  let currency: String
  let totalCost: String
}
struct QFInventoryCostResult: Decodable {
  let lotId: String
  let revision: Int
  let sourceId: String
  let status: String
  let affectedCookingCount: Int
}
struct QFExpenseRange: Equatable {
  var startDate: String
  var endDate: String
  var days: [String] {
    guard let start = QFManualPlanDraft.date(startDate), let end = QFManualPlanDraft.date(endDate), start <= end else { return [] }
    let calendar = QFManualPlanDraft.calendar
    let count = min(367, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
    return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start).map(QFManualPlanDraft.string) }
  }
  var query: [String: String] { ["startDate": startDate, "endDate": endDate] }
  static func week(containing date: Date) -> Self {
    var calendar = Calendar(identifier: .gregorian); calendar.firstWeekday = 2
    let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    return .init(startDate: QFContentDate.day(start), endDate: QFContentDate.day(calendar.date(byAdding: .day, value: 6, to: start) ?? date))
  }
  static func month(containing date: Date) -> Self {
    let calendar = Calendar(identifier: .gregorian)
    let start = calendar.dateInterval(of: .month, for: date)?.start ?? date
    let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? date
    return .init(startDate: QFContentDate.day(start), endDate: QFContentDate.day(end))
  }
}
