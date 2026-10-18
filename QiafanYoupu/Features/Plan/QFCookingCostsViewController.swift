import SnapKit
import UIKit

@MainActor
final class QFCookingCostsViewController: QFProfileContentController {
  private var range: QFExpenseRange
  private let householdID: String?
  private var items: [QFCookingCost] = []
  private var total = 0
  private var totals: [QFCurrencyTotal] = []
  private var pending = 0
  private var nextPage = 0
  private var reachedEnd = false
  private var expanded: Set<String> = []
  private var loaded = false
  private var failure: String?
  private var needsReload = false
  private var period = 2
  private var locale: Locale { Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier) }
  override var reloadsOnAppearance: Bool { false }
  init(app: QFAppSession, range: QFExpenseRange, householdID: String?) {
    self.range = range; self.householdID = householdID
    super.init(app: app, title: app.text("食材消耗成本", "Ingredient consumption cost"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); view.accessibilityIdentifier = "plan.cooking-costs"
    setReloadAction { [weak self] in self?.load(force: true) }; render(); load()
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated); if needsReload { needsReload = false; load(force: true) }
  }
  private func load(append: Bool = false, force: Bool = false) {
    let context = range; let language = app.interfaceLanguage; let page = append ? nextPage : 0
    var query = range.query; query["householdId"] = householdID; query["page"] = String(page)
    execute(reloadOnFailure: true, loadingMore: append, showsInitialReadProgress: false) { [self] in
      do {
        let response: QFCookingCostPage = try await QFContentLoadingContext.$forceRefresh.withValue(force) { try await app.contentRequest(path: "me/cooking-costs", query: query) }
        try Task.checkCancellation(); guard context == range, language == app.interfaceLanguage else { throw CancellationError() }
        if append {
          let known = Set(items.map(\.recordId)); let extra = response.items.filter { !known.contains($0.recordId) }
          items.append(contentsOf: extra); reachedEnd = extra.isEmpty
        } else { items = response.items; reachedEnd = response.items.isEmpty }
        total = response.total; totals = response.totals; pending = response.pendingMaterialCount
        nextPage = page + 1; loaded = true; failure = nil
        if expanded.isEmpty, let first = items.first { expanded.insert(first.recordId) }; render()
      } catch is CancellationError { throw CancellationError() }
      catch { if append { throw error }; failure = Self.errorText(error, app: app); render() }
    }
  }
  private func select(_ index: Int) {
    let today = QFContentDate.day(Date())
    if index == 2 {
      open(QFExpenseDateRangeController(app: app, range: range) { [weak self] in self?.setRange($0, period: 2) }); return
    }
    setRange(index == 0 ? .init(startDate: today, endDate: today) : .month(containing: Date()), period: index)
  }
  private func setRange(_ value: QFExpenseRange, period: Int) {
    range = value; self.period = period; items = []; loaded = false; reachedEnd = false; nextPage = 0; failure = nil
    render(); load()
  }
  private func amount(_ values: [QFCurrencyTotal]) -> String {
    values.isEmpty ? "—" : values.map { QFPurchaseNumber.money($0.total, currency: $0.currency, locale: locale) }.joined(separator: " · ")
  }
  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row("range", version: "\(range)|\(period)|\(app.interfaceLanguage)") { [weak self] in
      guard let self else { return UIView() }
      return QFContentUI.segments([self.app.text("今天", "Today"), self.app.text("本月", "This month"), self.app.text("自定义", "Custom")], selected: self.period) { [weak self] in self?.select($0) }
    }
    if loaded {
      bodyStack.row("summary", version: "\(total)|\(pending)|\(totals)|\(range)") { [weak self] in
        guard let self else { return UIView() }
        return QFTabUI.card(QFTabUI.stack([
          QFTabUI.label(self.range.startDate + " – " + self.range.endDate, size: 13, color: QFUI.secondary),
          QFTabUI.label(self.app.format("已完成 %d 道菜", "%d dishes completed", self.total), size: 18, weight: .semibold),
          QFTabUI.label(self.app.text("已知成本", "Known cost") + " " + self.amount(self.totals), size: 28, weight: .bold, lines: 0),
          QFTabUI.label(self.app.format("%d 项材料成本待补全", "%d ingredient costs pending", self.pending), size: 13, color: QFUI.secondary, lines: 0),
        ], spacing: 10), padding: 18, background: QFUI.paleGreen)
      }
    }
    if items.isEmpty {
      bodyStack.row("state", version: "\(loaded)|\(failure ?? "")") { [weak self] in
        guard let self else { return UIView() }
        return QFTabUI.empty(self.failure != nil ? self.app.text("暂时无法加载", "Unable to load") : self.loaded ? self.app.text("暂无做菜记录", "No cooking records") : self.app.text("正在加载", "Loading"), detail: self.failure ?? "")
      }
    }
    for item in items {
      bodyStack.row(item.recordId, version: "\(item.valuationRevision)|\(item.status)|\(expanded.contains(item.recordId))|\(app.interfaceLanguage)") { [weak self] in self?.card(item) ?? UIView() }
    }
    bodyStack.endUpdates(); setLoadMoreAction(!reachedEnd && items.count < total ? { [weak self] in self?.load(append: true) } : nil)
  }
  private func card(_ item: QFCookingCost) -> UIView {
    let meal = QFCookingMeal(rawValue: item.meal)?.title(app: app) ?? item.meal
    let toggle = QFTabUI.button(item.title + "   " + amount(item.totals) + (expanded.contains(item.recordId) ? "  ⌃" : "  ⌄"), size: 18, weight: .semibold, color: QFUI.text) { [weak self] in
      guard let self else { return }; if self.expanded.contains(item.recordId) { self.expanded.remove(item.recordId) } else { self.expanded.insert(item.recordId) }; self.render()
    }
    toggle.titleLabel?.numberOfLines = 0; toggle.contentHorizontalAlignment = .leading
    let content = QFTabUI.stack([toggle, QFTabUI.label(item.date + " · " + meal, size: 12, color: QFUI.secondary)], spacing: 12)
    if item.status != "COMPLETE" {
      let title = item.status == "UNVERIFIED" ? app.text("历史库存依据待确认", "Historical inventory needs verification") : app.format("%d 项待补全", "%d pending", item.pendingMaterialCount)
      content.addArrangedSubview(QFTabUI.label(title, size: 13, color: QFUI.warning, lines: 0))
    }
    if expanded.contains(item.recordId) {
      for material in item.materials {
        let text = material.name + " · " + material.quantity + " " + material.unitCode + "   " + amount(material.totals)
        let row = QFTabUI.button(text + (material.status == "COMPLETE" ? "" : "  ›"), size: 14, color: material.status == "COMPLETE" ? QFUI.text : QFUI.orange) { [weak self] in
          guard let self, material.status != "COMPLETE" else { return }
          let editor = QFMissingCostViewController(app: self.app, record: item)
          editor.onChanged = { [weak self] in self?.needsReload = true; self?.onChanged?() }; self.open(editor)
        }
        row.titleLabel?.numberOfLines = 0; row.contentHorizontalAlignment = .leading; row.isEnabled = material.status != "COMPLETE"
        content.addArrangedSubview(row)
      }
    }
    return QFTabUI.card(content, padding: 16, border: true)
  }
}

@MainActor
final class QFMissingCostViewController: QFProfileContentController {
  private var record: QFCookingCost
  override var reloadsOnAppearance: Bool { false }
  init(app: QFAppSession, record: QFCookingCost) { self.record = record; super.init(app: app, title: app.text("补全食材成本", "Complete ingredient costs")) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); view.accessibilityIdentifier = "plan.missing-cost"
    setReloadAction(allowsPullToRefresh: false) { [weak self] in self?.load() }; render()
  }
  private func load() {
    execute(reloadOnFailure: true, showsInitialReadProgress: false) { [self] in
      record = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.contentRequest(path: "me/cooking-records/\(record.recordId)/cost") }; render()
    }
  }
  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row("summary", version: "\(record.valuationRevision)|\(record.pendingMaterialCount)") { [weak self] in
      guard let self else { return UIView() }
      let locale = Locale(identifier: QFInterfaceLanguage.normalized(self.app.interfaceLanguage).localeIdentifier)
      let amount = self.record.totals.map { QFPurchaseNumber.money($0.total, currency: $0.currency, locale: locale) }.joined(separator: " · ")
      return QFTabUI.card(QFTabUI.stack([
        QFTabUI.label(self.record.title, size: 22, weight: .semibold),
        QFTabUI.label(self.record.date, size: 13, color: QFUI.secondary),
        QFTabUI.label(self.app.text("已知成本", "Known cost") + " " + (amount.isEmpty ? "—" : amount), size: 24, weight: .bold, lines: 0),
        QFTabUI.label(self.app.format("%d 项待补全", "%d pending", self.record.pendingMaterialCount), size: 13, color: QFUI.warning),
      ], spacing: 10), padding: 18, background: QFUI.warningBackground)
    }
    var seen: Set<String> = []
    for material in record.materials where material.status != "COMPLETE" {
      for source in material.sources where source.date == nil || source.totalCost == nil || source.currency == nil {
        guard seen.insert(source.sourceId).inserted else { continue }
        bodyStack.row(source.sourceId, version: "\(source.revision)|\(source.date ?? "")|\(source.totalCost ?? "")") { [weak self] in
          guard let self else { return UIView() }
          let editor = QFCostSourceForm(app: self.app, material: material, source: source, openReceipt: { [weak self] id in self?.openCostReceipt(id) { [weak self] in self?.onChanged?(); self?.load() } }) { [weak self] in self?.onChanged?(); self?.load() }
          return editor
        }
      }
    }
    if seen.isEmpty && record.status != "COMPLETE" {
      bodyStack.row("unverified", version: record.status) { [app] in QFTabUI.empty(app.text("历史库存依据待确认", "Historical inventory needs verification"), detail: app.text("这条记录缺少可关联的库存来源，请先核对实际用料。", "This record has no linked stock source. Review the actual ingredients first.")) }
    }
    for material in record.materials where material.status == "COMPLETE" {
      bodyStack.row("known-" + (material.ingredientId ?? material.name) + "-" + material.unitCode, value: material) { [app, material] in
        let locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
        return QFTabUI.card(QFTabUI.stack([QFTabUI.label(material.name, size: 16, weight: .semibold), UIView(), QFTabUI.label(material.totals.map { QFPurchaseNumber.money($0.total, currency: $0.currency, locale: locale) }.joined(separator: " · "), size: 16, weight: .semibold, lines: 0)], axis: .horizontal, spacing: 12), padding: 16, border: true)
      }
    }
    bodyStack.endUpdates()
  }
}

private struct QFCostSourceDraft: Codable {
  var quantity: String; var date: String?; var currency: String; var cost: String
  var pending: QFInventoryCostRequest?
  var language: String?
}
@MainActor
private final class QFCostSourceForm: UIView {
  private let app: QFAppSession
  private let material: QFCookingCost.Material
  private var source: QFCookingCost.Source
  private let onSaved: () -> Void
  private let openReceipt: (String) -> Void
  private var draft: QFCostSourceDraft
  private let draftKey: String
  private var task: Task<Void, Never>?
  private var conflicted = false
  private let hud = QFOperationHUD()
  private let stack = QFTabUI.stack([], spacing: 12)
  private let saveButton = QFTabUI.button("", color: QFUI.onPrimary, background: QFUI.primary) {}
  init(app: QFAppSession, material: QFCookingCost.Material, source: QFCookingCost.Source, openReceipt: @escaping (String) -> Void, onSaved: @escaping () -> Void) {
    self.app = app; self.material = material; self.source = source; self.onSaved = onSaved; self.openReceipt = openReceipt
    draftKey = "source-cost." + source.sourceId
    draft = QFContentDraftStore.load(QFCostSourceDraft.self, app: app, kind: draftKey) ?? .init(quantity: source.originalQuantity, date: source.date, currency: source.currency ?? "CNY", cost: source.totalCost ?? "")
    super.init(frame: .zero)
    backgroundColor = QFUI.surface; layer.cornerRadius = 18; layer.borderWidth = 1; layer.borderColor = QFUI.warning.cgColor
    addSubview(stack); stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(16) }; render()
  }
  required init?(coder: NSCoder) { nil }
  deinit { task?.cancel() }
  private func persist() -> Bool { QFContentDraftStore.save(draft, app: app, kind: draftKey) }
  private func render() {
    QFTabUI.clear(stack)
    stack.addArrangedSubview(QFTabUI.label(material.name, size: 18, weight: .semibold))
    if let receiptID = source.receiptId {
      let amount = source.totalCost.flatMap { value in source.currency.map { currency in QFPurchaseNumber.money(value, currency: currency, locale: Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)) } } ?? app.text("价格待补全", "Price needed")
      stack.addArrangedSubview(QFTabUI.label([source.date, source.originalQuantity + " " + source.unitCode, amount].compactMap { $0 }.joined(separator: " · "), size: 14, color: QFUI.secondary, lines: 0))
      stack.addArrangedSubview(QFTabUI.button(app.text("采购账单", "Purchase receipt") + "  ›", color: QFUI.orange) { [weak self] in self?.openReceipt(receiptID) })
      return
    }

    stack.addArrangedSubview(QFTabUI.label(app.text("这批库存原始数量", "Original quantity of this stock lot"), size: 13, color: QFUI.secondary, lines: 0))
    let locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    let quantity = QFContentUI.field(app.text("数量", "Quantity"), text: draft.quantity, keyboard: .decimalPad) { [weak self] in self?.draft.quantity = QFPurchaseNumber.normalize($0, locale: locale); _ = self?.persist() }
    stack.addArrangedSubview(QFTabUI.stack([quantity, QFTabUI.label(source.unitCode, size: 16)], axis: .horizontal, spacing: 12))
    let date = UIDatePicker(); date.datePickerMode = .date; date.preferredDatePickerStyle = .compact
    date.calendar = QFManualPlanDraft.calendar; date.timeZone = QFManualPlanDraft.calendar.timeZone; date.locale = locale
    date.date = draft.date.flatMap(QFManualPlanDraft.date) ?? Date(); date.maximumDate = QFManualPlanDraft.date(QFContentDate.day(Date()))
    date.addAction(UIAction { [weak self, weak date] _ in guard let self, let date else { return }; self.draft.date = QFManualPlanDraft.string(date.date); _ = self.persist() }, for: .valueChanged)
    stack.addArrangedSubview(QFTabUI.label(app.text("购买日期", "Purchase date"), size: 13, color: QFUI.secondary))
    stack.addArrangedSubview(date)
    if draft.date == nil {
      let confirm = QFTabUI.button(app.text("确认所选购买日期", "Confirm selected purchase date"), size: 13, color: QFUI.orange) { [weak self, weak date] in
        guard let self, let date else { return }; self.draft.date = QFManualPlanDraft.string(date.date); _ = self.persist(); self.render()
      }
      stack.addArrangedSubview(confirm)
    }
    stack.addArrangedSubview(QFTabUI.label(app.text("这批库存总成本", "Total cost of this stock lot"), size: 13, color: QFUI.secondary, lines: 0))
    stack.addArrangedSubview(QFContentUI.field(app.text("输入金额", "Enter amount"), text: draft.cost, keyboard: .decimalPad) { [weak self] in self?.draft.cost = QFPurchaseNumber.normalize($0, locale: locale); _ = self?.persist() })
    stack.addArrangedSubview(QFContentUI.field(app.text("币种", "Currency"), text: draft.currency, keyboard: .asciiCapable, limit: 3) { [weak self] in self?.draft.currency = $0.uppercased(); _ = self?.persist() })
    stack.arrangedSubviews.forEach { $0.isUserInteractionEnabled = draft.pending == nil }
    saveButton.setTitle(conflicted ? app.text("重新加载", "Reload") : draft.pending == nil ? app.text("保存成本", "Save cost") : app.text("重试", "Retry"), for: .normal)
    saveButton.removeTarget(nil, action: nil, for: .touchUpInside)
    saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
    stack.addArrangedSubview(saveButton); saveButton.isEnabled = task == nil
  }
  @objc private func save() {
    endEditing(true); guard task == nil else { return }
    if conflicted {
      task = Task { [weak self] in
        guard let self else { return }; defer { self.task = nil; self.render() }
        do {
          let fresh: QFInventoryCostSources = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await self.app.contentRequest(path: "me/inventory/lots/\(self.source.lotId)/cost-sources") }
          guard let source = fresh.sources.first(where: { $0.sourceId == self.source.sourceId }) else { self.onSaved(); return }
          self.source = source; self.draft.pending = nil; self.conflicted = false; _ = self.persist()
        } catch { QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self) }
      }
      render(); return
    }
    if draft.pending == nil {
      guard let date = draft.date, QFManualPlanDraft.date(date) != nil,
        (QFPurchaseNumber.decimal(draft.quantity) ?? 0) > 0, (QFPurchaseNumber.decimal(draft.cost) ?? -1) >= 0,
        NSLocale.commonISOCurrencyCodes.contains(draft.currency) else {
        QFOperationHUD.toast(app.text("请确认原始数量、购买日期、币种和金额。", "Confirm the original quantity, purchase date, currency and amount."), in: self); return
      }
      draft.pending = .init(requestId: UUID(), expectedRevision: source.revision, sourceId: source.sourceId,
        originalQuantity: draft.quantity, unitCode: source.unitCode, date: date, time: source.time,
        timeZone: source.timeZone ?? TimeZone.current.identifier, currency: draft.currency, totalCost: draft.cost)
      draft.language = app.interfaceLanguage
      guard persist() else { draft.pending = nil; QFOperationHUD.toast(app.text("草稿保存失败，请重试。", "Could not save the draft. Please retry."), in: self); return }
    }
    guard let pending = draft.pending else { return }
    task = Task { [weak self] in
      guard let self else { return }; self.hud.show(in: self, text: self.app.text("正在保存", "Saving")); defer { self.task = nil; self.hud.hide(); self.render() }
      do {
        let _: QFInventoryCostResult = try await QFContentLoadingContext.$language.withValue(self.draft.language ?? self.app.interfaceLanguage) {
          try await self.app.contentRequest(path: "me/inventory/lots/\(self.source.lotId)/cost", method: "PATCH", body: JSONEncoder().encode(pending), operationID: pending.requestId)
        }
        QFContentDraftStore.remove(app: self.app, kind: self.draftKey); self.onSaved()
      } catch {
        if let apiError = error as? QFAPIError {
          if apiError.code == 40900 { self.conflicted = true }
          if apiError.code == 40000 || (42200...42299).contains(apiError.code) { self.draft.pending = nil; _ = self.persist() }
        }
        QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self)
      }
    }
    render()
  }
}

private struct QFInventoryCostSources: Decodable {
  let lotId: String
  let revision: Int
  let sources: [QFCookingCost.Source]
}
@MainActor
final class QFInventoryCostSourcesViewController: QFProfileContentController {
  private let lot: QFInventoryLot
  override var reloadsOnAppearance: Bool { false }
  init(app: QFAppSession, lot: QFInventoryLot) { self.lot = lot; super.init(app: app, title: app.text("补全食材成本", "Complete ingredient costs")) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); setReloadAction(allowsPullToRefresh: false) { [weak self] in self?.load() }; load()
  }
  private func load() {
    execute(reloadOnFailure: true, showsInitialReadProgress: true) { [self] in
      let value: QFInventoryCostSources = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.contentRequest(path: "me/inventory/lots/\(lot.id)/cost-sources") }
      bodyStack.beginUpdates()
      for source in value.sources {
        bodyStack.row(source.sourceId, value: source) { [weak self] in
          guard let self else { return UIView() }
          let material = QFCookingCost.Material(ingredientId: self.lot.ingredientId, name: self.lot.ingredientName ?? self.app.text("食材", "Ingredients"), quantity: source.originalQuantity, unitCode: source.unitCode, totals: [], status: source.totalCost == nil ? "PENDING" : "COMPLETE", sources: [source])
          return QFCostSourceForm(app: self.app, material: material, source: source, openReceipt: { [weak self] id in self?.openCostReceipt(id) { [weak self] in self?.onChanged?(); self?.load() } }) { [weak self] in self?.onChanged?(); self?.load() }
        }
      }
      if value.sources.isEmpty { bodyStack.row("empty") { [app] in QFTabUI.empty(app.text("历史库存依据待确认", "Historical inventory needs verification"), detail: app.text("这条记录缺少可关联的库存来源，请先核对实际用料。", "This record has no linked stock source. Review the actual ingredients first.")) } }
      bodyStack.endUpdates()
    }
  }
}

@MainActor
private extension QFProfileContentController {
  func openCostReceipt(_ id: String, changed: @escaping () -> Void) {
    execute(label: app.text("正在加载", "Loading")) { [self] in
      let receipt: QFPurchaseReceipt = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.contentRequest(path: "me/purchase-receipts/\(id)") }
      guard viewIfLoaded?.window != nil else { return }
      let editor = QFPurchaseReceiptViewController(app: app, receipt: receipt); editor.onChanged = changed; open(editor)
    }
  }
}
