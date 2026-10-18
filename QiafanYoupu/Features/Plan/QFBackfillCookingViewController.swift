import Combine
import SnapKit
import UIKit

enum QFBackfillLayout {
  static let pageInset: CGFloat = 24
  static let cardRadius: CGFloat = 18
  static let materialRowHeight: CGFloat = 64
  static let actionHeight: CGFloat = 54
}
private struct QFBackfillBalances: Decodable { let items: [QFInventoryBalance] }

@MainActor
final class QFBackfillCookingViewController: QFProfileContentController {
  private var draft: QFBackfillCookingDraft
  private let draftKey: String
  private let legacyKey: String
  private var active = 0
  private var units: [QFMeasurementUnit] = []
  private var balances: [QFInventoryBalance] = []
  private var balanceTask: Task<Void, Never>?
  private var balanceID = UUID()
  private lazy var costPreview = QFCookingCostPreviewLoader(app: app)
  private var costLabel: UILabel?
  private var materialCostLabels: [Int: UILabel] = [:]
  private var form = QFTabUI.stack([], spacing: 20)
  private var saveButton: UIButton!
  private var submitting = false
  private var saved = false
  override var reloadsOnAppearance: Bool { false }
  override var hasUnsavedChanges: Bool { !saved && (!draft.items.isEmpty || draft.pending != nil) }

  init(app: QFAppSession, date: String, householdID: String? = nil) {
    draftKey = "backfill.\(householdID ?? "personal").\(date)"; legacyKey = "cooking-batch-" + date
    var value = QFContentDraftStore.load(QFBackfillCookingDraft.self, app: app, kind: draftKey)
      ?? QFBackfillCookingDraft(date: date, householdId: householdID, language: app.interfaceLanguage)
    if value.items.isEmpty && value.pending == nil && householdID == nil {
      // Old drafts remain intact until the new atomic save succeeds. Other dates are never removed.
      let legacy = QFContentDraftStore.load([QFCookingRecord].self, app: app, kind: legacyKey) ?? []
      value.items = legacy.filter { $0.date == date }.map { QFBackfillCookingItem(record: $0) }
    }
    draft = value
    super.init(app: app, title: app.text("补记做菜", "Add cooking record"))
  }
  required init?(coder: NSCoder) { nil }
  deinit { balanceTask?.cancel() }
  override func viewDidLoad() {
    super.viewDidLoad(); costPreview.changed = { [weak self] in self?.updatePreviewLabels() }; view.accessibilityIdentifier = "plan.backfill"
    bodyStack.addArrangedSubview(form)
    contentStack.snp.remakeConstraints {
      $0.top.equalToSuperview().offset(14); $0.bottom.equalToSuperview().inset(24); $0.centerX.equalToSuperview()
      $0.width.equalToSuperview().offset(-2 * QFBackfillLayout.pageInset).priority(999)
      $0.width.lessThanOrEqualTo(QFAdaptiveLayout.contentMaxWidth - 2 * QFBackfillLayout.pageInset)
    }
    saveButton = addFooter(app.text("保存补记", "Save cooking records")) { [weak self] in self?.submit() }
    saveButton.accessibilityIdentifier = "plan.backfill.save"
    saveButton.snp.remakeConstraints { $0.height.greaterThanOrEqualTo(QFBackfillLayout.actionHeight) }
    footer.snp.updateConstraints { $0.width.equalToSuperview().offset(-2 * QFBackfillLayout.pageInset).priority(999) }
    let local = QFTabUI.button(app.text("草稿", "Draft"), size: 14, color: QFUI.orange) { [weak self] in
      guard let self, self.persist() else { return }
      self.message(self.app.text("草稿已保存", "Draft saved"))
    }
    installHeaderAction(local)
    local.contentEdgeInsets.left = 2; local.contentEdgeInsets.right = 2
    local.titleLabel?.numberOfLines = 1; local.titleLabel?.adjustsFontSizeToFitWidth = true
    local.titleLabel?.minimumScaleFactor = 0.85
    let footerSurface = UIView(); footerSurface.backgroundColor = QFUI.surface
    view.insertSubview(footerSurface, belowSubview: footer)
    footerSurface.snp.makeConstraints { $0.leading.trailing.bottom.equalToSuperview(); $0.top.equalTo(footer.snp.top).offset(-20) }
    let separator = UIView(); separator.backgroundColor = QFUI.border; footerSurface.addSubview(separator)
    separator.snp.makeConstraints { $0.top.leading.trailing.equalToSuperview(); $0.height.equalTo(0.5) }
    footer.backgroundColor = QFUI.surface
    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.scheduleCostPreview(force: true)
    }.store(in: &cancellables)
    app.$user.map { $0?.userId }.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.costPreview.update(nil)
    }.store(in: &cancellables)
    setReloadAction(allowsPullToRefresh: false) { [weak self] in self?.loadUnits() }
    render(); loadUnits()
  }
  @discardableResult private func persist() -> Bool {
    let result = QFContentDraftStore.save(draft, app: app, kind: draftKey)
    if !result { message(app.text("草稿保存失败，请重试。", "Could not save the draft. Please retry."), error: true) }
    scheduleCostPreview()
    return result
  }
  private func loadUnits() {
    guard draft.pending == nil else { return }
    execute(reloadOnFailure: true, showsInitialReadProgress: false) { [self] in
      units = try await app.measurementUnits(); render(); loadBalances()
    }
  }
  private func updateSave() {
    saveButton.isEnabled = !submitting && (draft.pending != nil || draft.ready)
    saveButton.backgroundColor = saveButton.isEnabled ? QFUI.primary : QFUI.disabledBackground
    saveButton.setTitleColor(saveButton.isEnabled ? QFUI.onPrimary : QFUI.disabledText, for: .normal)
    saveButton.setTitle(draft.pending != nil ? app.text("重试", "Retry") : app.text("保存补记", "Save cooking records"), for: .normal)
  }
  private func render() {
    QFTabUI.clear(form); materialCostLabels = [:]
    active = min(active, max(0, draft.items.count - 1))
    let subtitle = draft.householdId == nil ? app.text("也可以记录计划外的菜", "You can also record dishes outside your plan") : app.text("使用家庭库存", "Use household inventory")
    form.addArrangedSubview(QFTabUI.card(QFTabUI.stack([
      QFContentUI.label(app.text("记录之前做过的一餐", "Record a meal you cooked"), size: 21, bold: true),
      QFContentUI.label(subtitle, size: 14, color: QFUI.secondary)
    ], spacing: 10)))
    let date = UIDatePicker(); date.datePickerMode = .date; date.preferredDatePickerStyle = .compact
    date.calendar = QFManualPlanDraft.calendar; date.timeZone = QFManualPlanDraft.calendar.timeZone
    date.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    date.maximumDate = QFManualPlanDraft.date(QFContentDate.day(Date())); date.date = QFManualPlanDraft.date(draft.date) ?? Date()
    date.accessibilityIdentifier = "plan.backfill.date"
    date.addAction(UIAction { [weak self, weak date] _ in
      guard let self, let date, self.draft.pending == nil else { return }
      self.draft.date = QFManualPlanDraft.string(date.date); self.persist(); self.updateSave()
    }, for: .valueChanged)
    let meal = QFTabUI.button(draft.items.isEmpty ? (QFCookingMeal(rawValue: draft.meal)?.title(app: app) ?? app.text("餐次", "Meal")) : draft.items[active].record.mealTitle(app: app), size: 16, background: QFUI.surface) {}
    meal.addAction(UIAction { [weak self, weak meal] _ in self?.chooseMeal(source: meal) }, for: .touchUpInside)
    decorateSelection(meal, symbol: "chevron.down"); meal.accessibilityIdentifier = "plan.backfill.meal"; meal.snp.makeConstraints { $0.height.greaterThanOrEqualTo(48) }
    let dates = QFTabUI.stack([
      QFTabUI.stack([QFContentUI.label(app.text("实际日期", "Actual date"), size: 13, color: QFUI.secondary), QFTabUI.card(date, padding: 8, border: true)], spacing: 8),
      QFTabUI.stack([QFContentUI.label(app.text("餐次", "Meal"), size: 13, color: QFUI.secondary), meal], spacing: 8)
    ], axis: .horizontal, spacing: 12)
    dates.arrangedSubviews[0].snp.makeConstraints { $0.width.equalTo(dates.snp.width).multipliedBy(0.62).offset(-6) }
    form.addArrangedSubview(dates)
    let dish = QFTabUI.button(draft.items.isEmpty ? app.text("选择菜品", "Choose a dish") : draft.items[active].record.title, size: 19, weight: .semibold, background: QFUI.surface) {}
    dish.addAction(UIAction { [weak self, weak dish] _ in self?.chooseDish(source: dish) }, for: .touchUpInside)
    decorateSelection(dish, symbol: "chevron.right"); dish.titleLabel?.numberOfLines = 0; dish.contentHorizontalAlignment = .leading; dish.accessibilityIdentifier = "plan.backfill.dish"
    dish.snp.makeConstraints { $0.height.greaterThanOrEqualTo(50) }
    form.addArrangedSubview(QFTabUI.stack([QFContentUI.label(app.text("做过的菜", "Dish you cooked"), size: 13, color: QFUI.secondary), dish], spacing: 8))
    if draft.items.count > 1 {
      let selected = QFTabUI.button(app.format("第 %d / %d 道菜", "Dish %d of %d", active + 1, draft.items.count), size: 14, color: QFUI.orange) {}
      selected.addAction(UIAction { [weak self, weak selected] _ in self?.chooseActive(source: selected) }, for: .touchUpInside)
      selected.accessibilityIdentifier = "plan.backfill.switchDish"; form.addArrangedSubview(selected)
    }
    form.addArrangedSubview(QFContentUI.label(app.text("核对实际用量", "Confirm actual quantities"), size: 18, bold: true))
    let rows = QFTabUI.stack([], spacing: 10)
    let titles = [app.text("食材", "Ingredients"), app.text("实际用量", "Amount used"), app.text("单位", "Unit"), app.text("库存单价", "Stock unit cost")]
    let header = QFTabUI.stack(titles.map { QFContentUI.label($0, size: 12, color: QFUI.secondary) }, axis: .horizontal, spacing: 6)
    for (i, width) in [(1, 64), (2, 56), (3, 64)] { header.arrangedSubviews[i].snp.makeConstraints { $0.width.equalTo(width) } }
    rows.addArrangedSubview(header)
    if !draft.items.isEmpty { for index in draft.items[active].record.materials.indices { rows.addArrangedSubview(materialRow(index)) } }
    form.addArrangedSubview(QFTabUI.card(rows, padding: 14))
    let addMaterial = QFTabUI.button(app.text("＋ 添加用料", "+ Add material"), size: 14, color: QFUI.orange) { [weak self] in self?.chooseIngredient(nil) }
    addMaterial.accessibilityIdentifier = "plan.backfill.addMaterial"; addMaterial.isEnabled = !draft.items.isEmpty; form.addArrangedSubview(addMaterial)
    let costText = QFContentUI.label("—", size: 15, color: QFUI.green)
    costText.accessibilityIdentifier = "plan.backfill.cost"; costText.textAlignment = .right; costLabel = costText
    let costCard = QFTabUI.card(QFTabUI.stack([
      QFContentUI.label(app.text("本次消耗成本", "Cost of this cooking"), size: 18, bold: true), costText
    ], axis: .horizontal, spacing: 12), background: QFUI.warningBackground)
    costCard.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(retryCostPreview)))
    form.addArrangedSubview(costCard)
    let add = QFTabUI.button(app.text("＋ 添加菜品", "+ Add dish"), size: 15, color: QFUI.orange) {}
    add.addAction(UIAction { [weak self, weak add] _ in self?.chooseNewDish(source: add) }, for: .touchUpInside)
    add.accessibilityIdentifier = "plan.backfill.addDish"; add.isEnabled = draft.items.count < 30; form.addArrangedSubview(add)
    form.isUserInteractionEnabled = draft.pending == nil && !submitting
    updateSave(); scheduleCostPreview(); updatePreviewLabels()
  }
  private func materialRow(_ index: Int) -> UIView {
    let item = draft.items[active].record.materials[index]
    let name = QFTabUI.button(item.name, size: 15, weight: .semibold) { [weak self] in self?.chooseIngredient(index) }
    name.titleLabel?.numberOfLines = 0; name.contentHorizontalAlignment = .leading
    name.contentEdgeInsets.left = 0; name.contentEdgeInsets.right = 0
    let matching = balances.filter { $0.ingredientId == item.ingredientId }
    let stock = matching.isEmpty ? app.text("库存待核对", "Check stock") : matching.map { app.format("库存 %@ %@", "Stock: %@ %@", $0.quantity, unitTitle($0.unitCode)) }.joined(separator: " · ")
    let amount = QFContentUI.field(app.text("实际用量", "Amount used"), text: item.amount, keyboard: .decimalPad, limit: 11) { [weak self] value in
      guard let self, self.draft.pending == nil else { return }
      self.draft.items[self.active].record.materials[index].amount = value; self.persist(); self.updateSave()
    }
    amount.backgroundColor = QFUI.background; amount.layer.borderWidth = 0.7; amount.layer.borderColor = QFUI.border.cgColor
    amount.accessibilityIdentifier = "plan.backfill.amount.\(index)"; amount.snp.makeConstraints { $0.width.equalTo(64); $0.height.greaterThanOrEqualTo(44) }
    let unit = QFTabUI.button(compactUnitTitle(item.unit), size: 13, background: QFUI.background) {}
    unit.addAction(UIAction { [weak self, weak unit] _ in self?.chooseUnit(index, source: unit) }, for: .touchUpInside)
    unit.contentEdgeInsets.left = 3; unit.contentEdgeInsets.right = 3
    unit.titleLabel?.numberOfLines = 1; unit.titleLabel?.adjustsFontSizeToFitWidth = true; unit.titleLabel?.minimumScaleFactor = 0.75
    unit.accessibilityIdentifier = "plan.backfill.unit.\(index)"; unit.accessibilityLabel = unitTitle(item.unit)
    unit.layer.borderWidth = 0.7; unit.layer.borderColor = QFUI.border.cgColor
    unit.snp.makeConstraints { $0.width.equalTo(56); $0.height.greaterThanOrEqualTo(44) }
    let cost = QFContentUI.label("—", size: 12, color: QFUI.warning); materialCostLabels[index] = cost; cost.textAlignment = .center
    cost.backgroundColor = QFUI.warningBackground; cost.layer.cornerRadius = 10; cost.clipsToBounds = true
    cost.snp.makeConstraints { $0.width.equalTo(64); $0.height.greaterThanOrEqualTo(44) }
    let row = QFTabUI.stack([QFTabUI.stack([name, QFContentUI.label(stock, size: 11, color: QFUI.secondary)], spacing: 3), amount, unit, cost], axis: .horizontal, spacing: 6)
    row.alignment = .center; row.snp.makeConstraints { $0.height.greaterThanOrEqualTo(QFBackfillLayout.materialRowHeight) }; return row
  }
  private func scheduleCostPreview(force: Bool = false) {
    let request = QFCookingCostPreviewRequest(date: draft.date, householdId: draft.householdId, items: draft.items.map { .init($0.record) })
    costPreview.update(draft.pending == nil && !submitting && draft.ready ? request : nil, force: force)
  }
  @objc private func retryCostPreview() { if costPreview.failure != nil { scheduleCostPreview(force: true) } }
  private func updatePreviewLabels() {
    guard draft.items.indices.contains(active) else { costLabel?.text = "—"; return }
    let record = draft.items[active].record
    costLabel?.text = costPreview.summary(itemID: record.id)
    for (index, label) in materialCostLabels where record.materials.indices.contains(index) {
      label.text = costPreview.material(record.materials[index], itemID: record.id, units: units, unitPrice: true)
    }
  }
  private func decorateSelection(_ button: UIButton, symbol: String) {
    button.layer.cornerRadius = QFBackfillLayout.cardRadius
    button.layer.borderWidth = 0.7; button.layer.borderColor = QFUI.border.cgColor
    let arrow = QFTabUI.symbol(symbol, size: 12, color: QFUI.secondary)
    button.addSubview(arrow); arrow.snp.makeConstraints { $0.centerY.equalToSuperview(); $0.trailing.equalToSuperview().inset(12) }
    button.contentEdgeInsets.right = 32
  }
  private func compactUnitTitle(_ code: String) -> String {
    guard let unit = units.first(where: { $0.code == code }) else { return code }
    return ["zh-Hans", "zh-Hant", "ja", "ko"].contains(app.interfaceLanguage) ? unit.name : unit.symbol
  }
  private func unitTitle(_ code: String) -> String { units.first { $0.code == code }?.name ?? code }
  private func chooseRecipe(adding: Bool) {
    guard draft.pending == nil, !adding || draft.items.count < 30 else { return }
    open(QFCatalogSearchViewController(app: app, type: "RECIPE") { [weak self] item in
      guard let self else { return }
      var record = QFCookingRecord(); record.date = self.draft.date; record.title = item.title
      record.meal = self.draft.items.isEmpty || adding ? self.draft.meal : self.draft.items[self.active].record.meal
      record.materials = item.materials.map { material in
        var value = material; value.amount = ""
        value.unit = self.units.first { $0.code == value.unit || $0.name == value.unit || $0.symbol == value.unit }?.code ?? value.unit
        return value
      }
      let value = QFBackfillCookingItem(record: record, recipeId: item.id)
      if adding || self.draft.items.isEmpty { self.draft.items.append(value); self.active = self.draft.items.count - 1 }
      else { self.draft.items[self.active] = value }
      self.persist(); self.render(); self.loadBalances()
    })
  }
  private func chooseDish(source: UIView?) {
    let sheet = UIAlertController(title: app.text("做过的菜", "Dish you cooked"), message: nil, preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: app.text("选择菜品", "Choose a dish"), style: .default) { [weak self] _ in self?.chooseRecipe(adding: false) })
    sheet.addAction(UIAlertAction(title: app.text("手动添加", "Add manually"), style: .default) { [weak self] _ in self?.manualDish() })
    if !draft.items.isEmpty { sheet.addAction(UIAlertAction(title: app.text("移除", "Remove"), style: .destructive) { [weak self] _ in
      guard let self else { return }; self.draft.items.remove(at: self.active); self.persist(); self.render(); self.loadBalances()
    }) }
    showChoice(sheet, source: source)
  }
  private func chooseNewDish(source: UIView?) {
    guard draft.items.count < 30, draft.pending == nil else { return }
    let sheet = UIAlertController(title: app.text("选择菜品", "Choose a dish"), message: nil, preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: app.text("选择菜品", "Choose a dish"), style: .default) { [weak self] _ in self?.chooseRecipe(adding: true) })
    sheet.addAction(UIAlertAction(title: app.text("手动添加", "Add manually"), style: .default) { [weak self] _ in self?.manualDish(adding: true) })
    showChoice(sheet, source: source)
  }
  private func manualDish(adding: Bool = false) {
    let alert = UIAlertController(title: app.text("实际做的菜品名称", "Dish you cooked"), message: nil, preferredStyle: .alert)
    alert.addTextField { [weak self] in $0.text = self.flatMap { adding || $0.draft.items.isEmpty ? nil : $0.draft.items[$0.active].record.title } }
    alert.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: app.text("保存", "Save"), style: .default) { [weak self, weak alert] _ in
      guard let self, let title = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title.count <= 80 else { return }
      if adding || self.draft.items.isEmpty {
        var record = QFCookingRecord(); record.meal = self.draft.meal
        self.draft.items.append(.init(record: record)); self.active = self.draft.items.count - 1
      }
      self.draft.items[self.active].record.title = title; self.draft.items[self.active].recipeId = nil
      self.persist(); self.render()
    }); open(alert)
  }
  private func chooseActive(source: UIView?) {
    let sheet = UIAlertController(title: app.text("选择菜品", "Choose a dish"), message: nil, preferredStyle: .actionSheet)
    for (index, item) in draft.items.enumerated() { sheet.addAction(UIAlertAction(title: item.record.mealTitle(app: app) + " · " + item.record.title, style: .default) { [weak self] _ in self?.active = index; self?.render(); self?.loadBalances() }) }
    showChoice(sheet, source: source)
  }
  private func chooseMeal(source: UIView?) {
    let sheet = UIAlertController(title: app.text("餐次", "Meal"), message: nil, preferredStyle: .actionSheet)
    for meal in QFCookingMeal.allCases { sheet.addAction(UIAlertAction(title: meal.title(app: app), style: .default) { [weak self] _ in
      guard let self else { return }; self.draft.meal = meal.rawValue
      if !self.draft.items.isEmpty { self.draft.items[self.active].record.meal = meal.rawValue }
      self.persist(); self.render()
    }) }; showChoice(sheet, source: source)
  }
  private func chooseIngredient(_ index: Int?) {
    guard !draft.items.isEmpty, draft.pending == nil, index != nil || draft.items[active].record.materials.count < 40 else { return }
    open(QFCatalogSearchViewController(app: app, type: "INGREDIENT") { [weak self] item in
      guard let self else { return }
      if let index { self.draft.items[self.active].record.materials[index].name = item.title; self.draft.items[self.active].record.materials[index].ingredientId = item.id }
      else { self.draft.items[self.active].record.materials.append(.init(name: item.title, amount: "", unit: "g", ingredientId: item.id)) }
      self.persist(); self.render(); self.loadBalances()
    })
  }
  private func chooseUnit(_ index: Int, source: UIView?) {
    let sheet = UIAlertController(title: app.text("选择单位", "Choose unit"), message: nil, preferredStyle: .actionSheet)
    for unit in units { sheet.addAction(UIAlertAction(title: unit.name, style: .default) { [weak self] _ in
      guard let self else { return }; self.draft.items[self.active].record.materials[index].unit = unit.code; self.persist(); self.render()
    }) }
    if units.isEmpty { sheet.addAction(UIAlertAction(title: app.text("重试", "Retry"), style: .default) { [weak self] _ in self?.loadUnits() }) }
    sheet.addAction(UIAlertAction(title: app.text("移除", "Remove"), style: .destructive) { [weak self] _ in
      guard let self else { return }; self.draft.items[self.active].record.materials.remove(at: index); self.persist(); self.render(); self.loadBalances()
    }); showChoice(sheet, source: source)
  }
  private func showChoice(_ sheet: UIAlertController, source: UIView?) {
    sheet.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    sheet.popoverPresentationController?.sourceView = source ?? view; sheet.popoverPresentationController?.sourceRect = source?.bounds ?? view.bounds
    open(sheet)
  }
  private func loadBalances() {
    balanceTask?.cancel(); balanceID = UUID(); balances = []
    guard !draft.items.isEmpty, draft.pending == nil else { return }
    let ids = Set(draft.items[active].record.materials.compactMap(\.ingredientId)).sorted()
    guard !ids.isEmpty else { return }
    let id = balanceID; var query = ["ingredientIds": ids.joined(separator: ",")]
    if let household = draft.householdId { query["householdId"] = household }
    balanceTask = Task { [weak self] in
      guard let self else { return }
      do {
        let response: QFBackfillBalances = try await self.app.contentRequest(path: "me/inventory/balances", query: query)
        try Task.checkCancellation(); guard self.balanceID == id else { return }
        self.balances = response.items
        if !self.hasFirstResponder(self.form) { self.render() }
      } catch { /* The atomic save is authoritative; unknown stock is not zero. */ }
    }
  }
  private func hasFirstResponder(_ view: UIView) -> Bool { view.isFirstResponder || view.subviews.contains { hasFirstResponder($0) } }
  private func submit() {
    guard !submitting else { return }; view.endEditing(true)
    let wasPending = draft.pending
    if wasPending == nil { draft.language = app.interfaceLanguage }
    guard draft.prepare(), let request = draft.pending else { return }
    guard persist() else { draft.pending = wasPending; updateSave(); return }
    submitting = true; render()
    execute { [self] in
      defer { submitting = false; DispatchQueue.main.async { [weak self] in self?.render() } }
      do {
        let response: QFCookingBatchResponse = try await QFContentLoadingContext.$language.withValue(draft.language) {
          try await app.contentRequest(path: "me/cooking-records/batch", method: "POST", body: JSONEncoder().encode(request))
        }
        guard response.requestId.lowercased() == request.requestId.lowercased(), response.total == request.items.count,
          Set(response.items.map(\.id)) == Set(request.items.map(\.id)), response.items.allSatisfy({ $0.inventoryMode == "ACTUAL_MATERIALS" }) else {
          throw QFAPIError(code: 50000, message: "Invalid batch receipt")
        }
        saved = true
        if draft.householdId == nil, let old = QFContentDraftStore.load([QFCookingRecord].self, app: app, kind: legacyKey) {
          let ids = Set(request.items.map(\.id)); let retained = old.filter { !ids.contains($0.id) }
          if retained.isEmpty { QFContentDraftStore.remove(app: app, kind: legacyKey) }
          else if !QFContentDraftStore.save(retained, app: app, kind: legacyKey) {
            // Keep the frozen receipt so reopening safely retries cleanup without creating another batch.
            saved = false
            throw QFAPIError(code: 50000, message: "Could not finish local draft cleanup")
          }
        }
        QFContentDraftStore.remove(app: app, kind: draftKey); onChanged?(); qfClose()
      } catch {
        if let api = error as? QFAPIError, [42201, 42205, 42206, 42207].contains(api.code) {
          draft.pending = nil; persist()
        }
        // A transport failure or identity/permission conflict retains the exact receipt for a safe retry.
        throw error
      }
    }
  }
  override func close() { guard !submitting, !hasUnsavedChanges || persist() else { return }; super.close() }
}
