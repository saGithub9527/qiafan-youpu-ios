import Foundation

struct QFCookingCostPreviewRequest: Encodable, Equatable {
  struct Item: Encodable, Equatable {
    let id: String; let plannedMealId: String?; let expectedPlanRevision: Int?; let materials: [QFWorkMaterial]
    init(_ record: QFCookingRecord, measurableOnly: Bool = false) {
      id = record.id; plannedMealId = record.plannedMealId; expectedPlanRevision = record.expectedPlanRevision
      materials = measurableOnly ? record.materials.filter(\.hasNumericAmount).map { material in
        var numeric = material; numeric.usageStatus = nil; return numeric
      } : record.materials
    }
  }
  let date: String; let householdId: String?; let items: [Item]
  var valid: Bool {
    QFManualPlanDraft.date(date) != nil && (1...30).contains(items.count)
      && items.allSatisfy { UUID(uuidString: $0.id) != nil && (1...40).contains($0.materials.count)
        && $0.materials.allSatisfy { UUID(uuidString: $0.ingredientId ?? "") != nil && $0.validation == nil } }
  }
}
struct QFCookingCostPreview: Decodable {
  struct Material: Decodable { let ingredientId: String; let name: String; let quantity: String; let unitCode: String; let status: String; let totals: [QFCurrencyTotal] }
  struct Item: Decodable { let id: String; let status: String; let totals: [QFCurrencyTotal]; let pendingMaterialCount: Int; let materials: [Material] }
  let preview: Bool; let reservesInventory: Bool; let date: String; let householdId: String?
  let valuationRevision: Int; let status: String; let totals: [QFCurrencyTotal]; let pendingMaterialCount: Int; let items: [Item]
}

/// One debounced read-only quote for the whole local draft; never reserves stock or saves a record.
@MainActor final class QFCookingCostPreviewLoader {
  private let app: QFAppSession
  private var task: Task<Void, Never>?
  private var key: Data?
  private var owner = ""
  private var language = ""
  private var generation = UUID()
  var changed: (() -> Void)?
  private(set) var result: QFCookingCostPreview?
  private(set) var failure: String?
  private(set) var loading = false
  init(app: QFAppSession) { self.app = app }
  deinit { task?.cancel() }
  func update(_ request: QFCookingCostPreviewRequest?, force: Bool = false) {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let bytes = request.flatMap { $0.valid ? try? encoder.encode($0) : nil }
    let user = app.user?.userId ?? "", lang = app.interfaceLanguage
    guard force || bytes != key || owner != user || language != lang else { return }
    task?.cancel(); generation = UUID(); let current = generation
    key = bytes; owner = user; language = lang; result = nil; failure = nil; loading = bytes != nil && !user.isEmpty; changed?()
    guard let bytes, let request, !user.isEmpty else { loading = false; return }
    task = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 700_000_000)
        guard let self else { return }
        let response: QFCookingCostPreview = try await self.app.contentRequest(path: "me/cooking-cost-previews", method: "POST", body: bytes)
        try Task.checkCancellation()
        guard self.generation == current, self.app.user?.userId == user, self.app.interfaceLanguage == lang else { return }
        guard response.preview, !response.reservesInventory, response.date == request.date, response.householdId == request.householdId,
          Set(response.items.map(\.id)) == Set(request.items.map(\.id)) else { throw QFAPIError(code:50000,message:self.app.text("服务器返回的数据不完整。", "The server response is incomplete.")) }
        self.result = response; self.loading = false; self.changed?()
      } catch is CancellationError { }
      catch {
        guard let self, self.generation == current, self.app.user?.userId == user, self.app.interfaceLanguage == lang else { return }
        self.loading = false; self.failure = QFProfileContentController.errorText(error, app:self.app); self.changed?()
      }
    }
  }
  func summary(itemID: String) -> String {
    if loading { return app.text("正在加载", "Loading") }
    if let failure { return failure }
    guard let item = result?.items.first(where:{$0.id==itemID}) else { return "—" }
    let amount = money(item.totals)
    if item.pendingMaterialCount > 0 { return amount.isEmpty ? app.text("成本待补全", "Cost missing") : app.format("已知 %@ · %d 项待补全", "Known %@ · %d pending", amount, item.pendingMaterialCount) }
    return amount.isEmpty ? app.text("成本待补全", "Cost missing") : amount
  }
  func material(_ row: QFWorkMaterial, itemID: String, units: [QFMeasurementUnit], unitPrice: Bool) -> String {
    guard let part = result?.items.first(where:{$0.id==itemID})?.materials.first(where: { part in
        guard part.ingredientId == row.ingredientId else { return false }
        if part.unitCode == row.unit { return true }
        let from = units.first { $0.code == row.unit }, to = units.first { $0.code == part.unitCode }
        return from != nil && to != nil && from?.dimension == to?.dimension
      }),
      let totalQuantity = QFPurchaseNumber.decimal(part.quantity), totalQuantity > 0 else { return "—" }
    guard part.status == "COMPLETE" else { return app.text("待补全", "Missing") }
    let factor: Decimal
    if part.unitCode == row.unit { factor = 1 }
    else {
      guard let from = units.first(where:{$0.code==row.unit}), let to = units.first(where:{$0.code==part.unitCode}), from.dimension == to.dimension,
        let a = QFPurchaseNumber.decimal(from.factorToBase), let b = QFPurchaseNumber.decimal(to.factorToBase), b > 0 else { return "—" }
      factor = a / b
    }
    guard let quantity = unitPrice ? Decimal(1) : QFPurchaseNumber.decimal(row.amount) else { return "—" }
    let locale = Locale(identifier:QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    return part.totals.compactMap { total -> String? in
      guard let value = QFPurchaseNumber.decimal(total.total) else { return nil }
      let amount = value * quantity * factor / totalQuantity
      if unitPrice {
        let formatter = NumberFormatter(); formatter.locale = locale; formatter.numberStyle = .currency
        formatter.currencyCode = total.currency; formatter.maximumFractionDigits = 6
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? total.currency + " " + QFPurchaseNumber.string(amount)
      }
      return QFPurchaseNumber.money(QFPurchaseNumber.string(amount), currency:total.currency,locale:locale)
    }.joined(separator:"\n")
  }
  private func money(_ totals:[QFCurrencyTotal])->String {
    let locale=Locale(identifier:QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    return totals.map{QFPurchaseNumber.money($0.total,currency:$0.currency,locale:locale)}.joined(separator:" · ")
  }
}
