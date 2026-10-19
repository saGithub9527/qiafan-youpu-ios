import Foundation

/// Local product import into a purchase draft. Legacy invoice hints stay readable.
struct QFReceiptImport {
  let date: String?
  let currency: String
  let sellerID: String?
  let invoiceTotal: String?
  let lines: [QFPurchaseReceiptLine]
}

struct QFPurchaseReceiptLine: Codable, Equatable {
  var id = UUID().uuidString.lowercased()
  var ingredientId: String?
  var name: String
  var quantity = ""
  var unitCode = "g"
  var lineAmount: String?
  var expiresOn: String?
  var location = ""
  var packageUnit: String?
  var packageSize: String?
  var packageContentUnit: String?
  var lotId: String?
  var netAmount: String?
  // Local review hints only; InputLine deliberately excludes them from the API.
  var scanBarcode: String? = nil
  var scanBarcodeSymbology: String? = nil
  var scanProductSource: String? = nil
  var scanPackageLabel: String? = nil
  var scanReferencePrice: String? = nil
  var scanPackageType: String? = nil
  var scanLookupState: String? = nil
  var matchedIngredientName: String? = nil
}
struct QFPurchaseReceipt: Codable, Equatable {
  let id: String
  let revision: Int
  let householdId: String?
  let date: String
  let time: String?
  let timeZone: String
  let merchant: String
  let currency: String
  let discount: String
  let knownSubtotal: String
  let paidAmount: String?
  let pendingPriceCount: Int
  let items: [QFPurchaseReceiptLine]
  let status: String
  let source: String
  var refundTotal: String? = nil
  var netPaidAmount: String? = nil
  var adjustments: [QFPurchaseAdjustment]? = nil
  var shoppingItemIds: [String]? = nil
}
struct QFPurchaseShoppingSource: Codable, Equatable {
  struct Item: Codable, Equatable { let itemId: String; let expectedRevision: Int }
  let listId: String; let expectedRevision: Int; var items: [Item]
}
struct QFPurchaseReceiptRequest: Codable, Equatable {
  let requestId: UUID
  let expectedRevision: Int?
  let householdId: String?
  let date: String
  let time: String?
  let timeZone: String
  let merchant: String
  let currency: String
  let discount: String
  let items: [QFPurchaseReceiptLine]
  var shoppingSource: QFPurchaseShoppingSource? = nil
  // Response-only stock identifiers and allocated costs must never become editable input.
  private struct InputLine: Encodable {
    let id: String; let ingredientId: String?; let name: String; let quantity: String; let unitCode: String
    let lineAmount: String?; let expiresOn: String?; let location: String
    let packageUnit: String?; let packageSize: String?; let packageContentUnit: String?
    init(_ line: QFPurchaseReceiptLine) {
      id = line.id; ingredientId = line.ingredientId; name = line.name; quantity = line.quantity
      unitCode = line.unitCode; lineAmount = line.lineAmount; expiresOn = line.expiresOn; location = line.location
      packageUnit = line.packageUnit; packageSize = line.packageSize; packageContentUnit = line.packageContentUnit
    }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(requestId, forKey: .requestId); try c.encodeIfPresent(expectedRevision, forKey: .expectedRevision)
    try c.encodeIfPresent(householdId, forKey: .householdId); try c.encode(date, forKey: .date)
    try c.encodeIfPresent(time, forKey: .time); try c.encode(timeZone, forKey: .timeZone)
    try c.encode(merchant, forKey: .merchant); try c.encode(currency, forKey: .currency); try c.encode(discount, forKey: .discount)
    try c.encode(items.map(InputLine.init), forKey: .items)
    try c.encodeIfPresent(shoppingSource, forKey: .shoppingSource)
  }
}
struct QFPurchaseReceiptDraft: Codable, Equatable {
  struct Pending: Codable, Equatable { let body: QFPurchaseReceiptRequest; let language: String }
  var id = UUID().uuidString.lowercased()
  var revision: Int?
  var householdId: String?
  var date: String
  var time: String?
  var timeZone = TimeZone.current.identifier
  var merchant = ""
  var currency = "CNY"
  var discount = "0"
  // Local review hints from a scanned invoice; never included in the purchase API request.
  var scanSellerID: String? = nil
  var scanTotal: String? = nil
  var items: [QFPurchaseReceiptLine] = []
  var pending: Pending?
  var shoppingSource: QFPurchaseShoppingSource? = nil
  init(date: String, householdId: String?) { self.date = date; self.householdId = householdId }
  init(shoppingList: QFShoppingList, date: String) {
    self.date = date; householdId = shoppingList.householdId
    let selected = shoppingList.items.filter { $0.checked && $0.received != true }
    shoppingSource = .init(listId: shoppingList.id, expectedRevision: shoppingList.revision,
      items: selected.map { .init(itemId: $0.id, expectedRevision: $0.revision) })
    items = selected.map { item in
      var line = QFPurchaseReceiptLine(ingredientId: item.ingredientId, name: item.name)
      line.id = item.id; line.quantity = item.quantityMax ?? item.quantityMin ?? ""
      line.unitCode = item.unitCode ?? "g"; return line
    }
  }
  init(_ receipt: QFPurchaseReceipt) {
    id = receipt.id; revision = receipt.revision; householdId = receipt.householdId
    date = receipt.date; time = receipt.time; timeZone = receipt.timeZone; merchant = receipt.merchant
    currency = receipt.currency; discount = receipt.discount; items = receipt.items
  }
  var knownSubtotal: Decimal { items.compactMap { $0.lineAmount.flatMap(QFPurchaseNumber.decimal) }.reduce(0, +) }
  var pendingCount: Int { items.filter { $0.lineAmount == nil || $0.lineAmount?.isEmpty == true }.count }
  var paidAmount: Decimal? { pendingCount == 0 ? knownSubtotal - (QFPurchaseNumber.decimal(discount) ?? 0) : nil }
  enum Validation: Error { case date, currency, items, amount, discount }
  func request() throws -> QFPurchaseReceiptRequest {
    guard QFManualPlanDraft.date(date) != nil, TimeZone(identifier: timeZone) != nil else { throw Validation.date }
    guard NSLocale.commonISOCurrencyCodes.contains(currency) else { throw Validation.currency }
    guard (1...40).contains(items.count), Set(items.map(\.id)).count == items.count,
      items.allSatisfy({ UUID(uuidString: $0.id) != nil && ($0.ingredientId == nil || UUID(uuidString: $0.ingredientId ?? "") != nil)
        && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count <= 100
        && (QFPurchaseNumber.decimal($0.quantity) ?? 0) > 0 && !$0.unitCode.isEmpty }) else { throw Validation.items }
    guard items.allSatisfy({ $0.lineAmount == nil || (QFPurchaseNumber.decimal($0.lineAmount ?? "") ?? -1) >= 0 }) else { throw Validation.amount }
    guard let reduction = QFPurchaseNumber.decimal(discount), reduction >= 0,
      reduction <= knownSubtotal, pendingCount == 0 || reduction == 0 else { throw Validation.discount }
    if let source = shoppingSource {
      let lineIDs = Set(items.map(\.id))
      guard !source.items.isEmpty, source.items.allSatisfy({ lineIDs.contains($0.itemId) }) else { throw Validation.items }
    }
    return .init(requestId: UUID(), expectedRevision: revision, householdId: householdId,
      date: date, time: time, timeZone: timeZone, merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
      currency: currency, discount: QFPurchaseNumber.string(reduction), items: items.map {
        var line = $0; line.name = line.name.trimmingCharacters(in: .whitespacesAndNewlines)
        line.lotId = nil; line.netAmount = nil; line.scanBarcode = nil; line.scanBarcodeSymbology = nil
        line.scanProductSource = nil; line.scanPackageLabel = nil; line.scanLookupState = nil
        line.scanReferencePrice = nil; line.scanPackageType = nil
        line.matchedIngredientName = nil; return line
      }, shoppingSource: shoppingSource)
  }
}
enum QFPurchaseNumber {
  // API decimals are canonical. Locale-aware input is normalized only at the UI boundary.
  static func decimal(_ value: String) -> Decimal? {
    guard value.range(of: "^[0-9]{1,12}(\\.[0-9]{1,6})?$", options: .regularExpression) != nil else { return nil }
    return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
  }
  static func normalize(_ input: String, locale: Locale) -> String {
    let separator = locale.decimalSeparator ?? "."
    return input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: separator, with: ".")
  }
  static func string(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
  static func money(_ value: String, currency: String, locale: Locale) -> String {
    let formatter = NumberFormatter(); formatter.numberStyle = .currency
    formatter.currencyCode = currency; formatter.locale = locale
    guard let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
      let result = formatter.string(from: NSDecimalNumber(decimal: decimal)) else { return currency + " " + value }
    return result
  }
}
extension QFAppSession {
  func savePurchaseReceipt(id: String, pending: QFPurchaseReceiptDraft.Pending) async throws -> QFPurchaseReceipt {
    try await QFContentLoadingContext.$language.withValue(pending.language) {
      try await contentRequest(path: "me/purchase-receipts/\(id)", method: "PUT",
        body: JSONEncoder().encode(pending.body), operationID: pending.body.requestId)
    }
  }
}

struct QFPurchaseAdjustmentItem: Codable, Equatable {
  let lineId: String
  var refundAmount: String
  var quantity: String?
  var unitCode: String?
}
struct QFPurchaseAdjustment: Codable, Equatable {
  let id: String; let date: String; let time: String?; let timeZone: String
  let type: String; let items: [QFPurchaseAdjustmentItem]; let totalAmount: String; let note: String
}
struct QFPurchaseAdjustmentRequest: Codable, Equatable {
  let requestId: UUID; let expectedRevision: Int; let date: String; let time: String?; let timeZone: String
  let type: String; let items: [QFPurchaseAdjustmentItem]; let note: String
}
