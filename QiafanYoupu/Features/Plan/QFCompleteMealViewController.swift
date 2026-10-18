import Combine
import SnapKit
import UIKit

struct QFInventoryBalance: Decodable {
  let ingredientId: String
  let unitCode: String
  let quantity: String
}
private struct QFInventoryBalances: Decodable { let items: [QFInventoryBalance] }

struct QFMealCompletionDraft: Codable {
  var record: QFCookingRecord
  let plan: QFPlannedMeal
  var language: String
  var prepared = false
  var pending = false
  var minutes: Int?

  init(plan: QFPlannedMeal, language: String) {
    self.plan = plan; self.language = language
    var record = QFCookingRecord()
    record.date = plan.date; record.meal = plan.meal; record.title = plan.title ?? ""
    record.plannedMealId = plan.id; record.expectedPlanRevision = plan.revision
    record.cost = nil
    self.record = record
  }

  var confirmedMaterials: Bool {
    !record.materials.isEmpty && record.materials.count <= 40
      && record.materials.allSatisfy { $0.ingredientId.flatMap(UUID.init(uuidString:)) != nil && $0.cookingValidation == nil }
  }
}

enum QFMealCompletionLayout {
  static let pageInset: CGFloat = 24
  static let cardRadius: CGFloat = 18
  static let actionHeight: CGFloat = 54
  static let rowHeight: CGFloat = 64
}

@MainActor
final class QFCompleteMealViewController: QFProfileContentController {
  private var draft: QFMealCompletionDraft
  private let draftKey: String
  private let saved: () -> Void
  private var units: [QFMeasurementUnit] = []
  private var balances: [QFInventoryBalance] = []
  private var balanceTask: Task<Void, Never>?
  private var balanceRequestID = UUID()
  private var balancesLoaded = false
  private var saveButton: UIButton!
  private var savedSuccessfully = false
  private var submitting = false
  private var loadingTemplate = false
  private lazy var costPreview = QFCookingCostPreviewLoader(app: app)
  private var costLabel: UILabel?
  private var materialCostLabels: [Int: UILabel] = [:]
  private var materialStockLabels: [Int: UILabel] = [:]
  private let formStack = QFTabUI.stack([], spacing: 16)
  override var reloadsOnAppearance: Bool { false }
  override var hasUnsavedChanges: Bool { !savedSuccessfully && (draft.prepared || draft.pending) }

  init(app: QFAppSession, plan: QFPlannedMeal, saved: @escaping () -> Void) {
    draftKey = "complete-plan.\(plan.id)"; self.saved = saved
    draft = QFContentDraftStore.load(QFMealCompletionDraft.self, app: app, kind: draftKey)
      ?? QFMealCompletionDraft(plan: plan, language: app.interfaceLanguage)
    super.init(app: app, title: app.text("确认完成做菜", "Confirm cooking completion"))
  }
  required init?(coder: NSCoder) { nil }
  deinit { balanceTask?.cancel() }
  override func viewDidLoad() {
    super.viewDidLoad()
    costPreview.changed = { [weak self] in self?.updatePreviewLabels() }
    view.accessibilityIdentifier = "plan.complete.editor"
    bodyStack.addArrangedSubview(formStack)
    contentStack.snp.remakeConstraints {
      $0.top.equalToSuperview().offset(14); $0.bottom.equalToSuperview().inset(24)
      $0.centerX.equalToSuperview()
      $0.width.equalToSuperview().offset(-2 * QFMealCompletionLayout.pageInset).priority(999)
      $0.width.lessThanOrEqualTo(QFAdaptiveLayout.contentMaxWidth - 2 * QFMealCompletionLayout.pageInset)
    }
    saveButton = addFooter(app.text("完成打卡", "Mark as cooked")) { [weak self] in self?.submit() }
    saveButton.accessibilityIdentifier = "plan.complete.save"
    saveButton.snp.remakeConstraints { $0.height.greaterThanOrEqualTo(QFMealCompletionLayout.actionHeight) }
    footer.snp.updateConstraints { $0.width.equalToSuperview().offset(-2 * QFMealCompletionLayout.pageInset).priority(999) }
    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.scheduleCostPreview(force: true)
    }.store(in: &cancellables)
    app.$user.map { $0?.userId }.removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.costPreview.update(nil)
    }.store(in: &cancellables)
    setReloadAction(allowsPullToRefresh: false) { [weak self] in self?.loadTemplate() }
    render()
    loadTemplate()
  }
  private func persist() -> Bool {
    let success = QFContentDraftStore.save(draft, app: app, kind: draftKey)
    if !success { message(app.text("草稿保存失败，请重试。", "Could not save the draft. Please retry."), error: true) }
    scheduleCostPreview()
    return success
  }
  private func loadTemplate() {
    guard !loadingTemplate, !submitting else { return }
    loadingTemplate = true; render()
    execute(reloadOnFailure: true) { [self] in
      defer { loadingTemplate = false; DispatchQueue.main.async { [weak self] in self?.render() } }
      units = try await app.measurementUnits()
      if draft.prepared && !draft.pending {
        var upgraded = false
        for index in draft.record.materials.indices where draft.record.materials[index].usageStatus == nil {
          draft.record.materials[index].usageStatus = "USED"; upgraded = true
        }
        if upgraded { _ = persist() }
      }
      if draft.prepared && !draft.pending && draft.language != app.interfaceLanguage {
        // Quantities are local user input. Only display names are localized again.
        let recipe: QFRecipeHomeDetail = try await app.publicContentRequest(path: "home/recipes/\(draft.plan.recipeId)")
        guard recipe.contentAvailable != false else { throw QFAPIError(code: 40400, message: "", requestId: nil) }
        draft.record.title = recipe.title
        draft.minutes = recipe.minutes
        let original = draft.record.materials
        var translated = original
        for index in original.indices {
          guard let id = original[index].ingredientId else { continue }
          do {
            let item: QFCatalogItem = try await app.contentRequest(path: "catalog/INGREDIENT/\(id)")
            translated[index].name = item.title
          } catch let error as QFAPIError where error.code == 40400 {
            translated[index].name = app.text("当前语言内容不可用", "Content unavailable in this language")
            translated[index].ingredientId = nil
          }
        }
        try Task.checkCancellation()
        guard draft.record.materials == original else { return }
        draft.record.materials = translated
        draft.language = app.interfaceLanguage; _ = persist()
      }
      if !draft.prepared && !draft.pending {
        let recipe: QFRecipeHomeDetail = try await QFContentLoadingContext.$language.withValue(draft.language) {
          try await app.publicContentRequest(path: "home/recipes/\(draft.plan.recipeId)")
        }
        guard recipe.contentAvailable != false else {
          message(app.text("当前语言内容不可用", "Content unavailable in this language"), error: true); return
        }
        draft.record.title = recipe.title
        draft.minutes = recipe.minutes
        // Suggested amounts are only a starting point; the user confirms actual
        // quantities. The server never rescales this submitted material list.
        draft.record.materials = recipe.materials.map { material in
          var item = material
          if let amount = Decimal(string: item.amount), let base = recipe.servings, base > 0 {
            var value = amount * Decimal(draft.plan.servings) / Decimal(base)
            var rounded = Decimal(); NSDecimalRound(&rounded, &value, 3, .plain)
            item.amount = NSDecimalNumber(decimal: rounded).stringValue
          }
          if let unit = units.first(where: { $0.code == item.unit || $0.name == item.unit || $0.symbol == item.unit }) { item.unit = unit.code }
          item.usageStatus = "USED"
          return item
        }
        draft.prepared = true; _ = persist()
      }
      render(); loadBalances()
    }
  }
  private func render() {
    materialCostLabels = [:]
    materialStockLabels = [:]
    QFTabUI.clear(formStack)
    let name = QFContentUI.label(draft.record.title, size: 21, bold: true)
    let state = QFContentUI.label(app.text("待确认", "Awaiting confirmation"), size: 12, color: QFUI.secondary)
    let badge = QFTabUI.card(state, padding: 10, border: true)
    badge.layer.cornerRadius = 16
    badge.setContentHuggingPriority(.required, for: .horizontal)
    let recipeInfo = QFTabUI.stack([name], spacing: 8)
    if let minutes = draft.minutes {
      recipeInfo.addArrangedSubview(QFContentUI.label(app.format("预计 %d 分钟", "About %d min", minutes), size: 13, color: QFUI.secondary))
    }
    let heading = QFTabUI.stack([recipeInfo, badge], axis: .horizontal, spacing: 12); heading.alignment = .center
    name.numberOfLines = 0
    formStack.addArrangedSubview(QFTabUI.card(heading, padding: 16))
    let date = UIDatePicker()
    date.datePickerMode = .date; date.preferredDatePickerStyle = .compact
    date.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    date.calendar = QFManualPlanDraft.calendar; date.timeZone = QFManualPlanDraft.calendar.timeZone
    date.maximumDate = QFManualPlanDraft.date(QFContentDate.day(Date()))
    date.date = QFManualPlanDraft.date(draft.record.date) ?? Date()
    date.accessibilityIdentifier = "plan.complete.date"
    date.addAction(UIAction { [weak self, weak date] _ in
      guard let self, let date, !self.draft.pending else { return }
      let f = DateFormatter(); f.calendar = QFManualPlanDraft.calendar; f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = QFManualPlanDraft.calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
      self.draft.record.date = f.string(from: date.date); _ = self.persist()
    }, for: .valueChanged)
    let meal = QFTabUI.button(draft.record.mealTitle(app: app), size: 16, background: QFUI.surface) {}
    meal.addAction(UIAction { [weak self, weak meal] _ in self?.chooseMeal(source: meal) }, for: .touchUpInside)
    meal.accessibilityIdentifier = "plan.complete.meal"
    meal.snp.makeConstraints { $0.height.greaterThanOrEqualTo(48) }
    let dateCard = UIView()
    dateCard.backgroundColor = QFUI.surface
    dateCard.layer.cornerRadius = 18
    dateCard.layer.borderWidth = 0.7
    dateCard.layer.borderColor = QFUI.border.cgColor
    dateCard.addSubview(date)
    // Compact date pickers have a narrower intrinsic control than the card. Centering
    // the control keeps the date column visually balanced at the approved two-column
    // geometry instead of leaving a large blank area on its leading side.
    date.snp.makeConstraints { $0.center.equalToSuperview(); $0.leading.greaterThanOrEqualToSuperview().offset(8); $0.trailing.lessThanOrEqualToSuperview().inset(8) }
    dateCard.snp.makeConstraints { $0.height.greaterThanOrEqualTo(48) }
    let dates = QFTabUI.stack([
      QFTabUI.stack([QFContentUI.label(app.text("实际日期", "Actual date"), size: 13, color: QFUI.secondary), dateCard], spacing: 8),
      QFTabUI.stack([QFContentUI.label(app.text("餐次", "Meal"), size: 13, color: QFUI.secondary), meal], spacing: 8)
    ], axis: .horizontal, spacing: 12)
    dates.arrangedSubviews[0].snp.makeConstraints { $0.width.equalTo(dates.snp.width).multipliedBy(0.5).offset(-6) }
    formStack.addArrangedSubview(dates)
    let materialHeading = QFContentUI.label(app.text("核对实际用量", "Confirm actual quantities"), size: 18, bold: true)
    let count = QFContentUI.label(app.format("%d 项食材", "%d ingredients", draft.record.materials.count), size: 12, color: QFUI.secondary)
    count.textAlignment = .right; count.setContentCompressionResistancePriority(.required, for: .horizontal)
    let materialTitle = QFTabUI.stack([materialHeading, count], axis: .horizontal, spacing: 12)
    materialTitle.alignment = .center; formStack.addArrangedSubview(materialTitle)
    let rows = QFTabUI.stack([], spacing: 10)
    let columns = [app.text("食材", "Ingredients"), app.text("实际用量", "Amount used"), app.text("单位", "Unit"), app.text("成本", "Cost")]
    let headers = QFTabUI.stack(columns.map { QFContentUI.label($0, size: 12, color: QFUI.secondary) }, axis: .horizontal, spacing: 6)
    for (index, width) in [(1, 62), (2, 60), (3, 35)] {
      headers.arrangedSubviews[index].snp.makeConstraints { $0.width.equalTo(width) }
    }
    rows.addArrangedSubview(headers)
    for index in draft.record.materials.indices {
      rows.addArrangedSubview(materialRow(index))
      if index + 1 < draft.record.materials.count {
        let line = UIView(); line.backgroundColor = QFUI.border; line.snp.makeConstraints { $0.height.equalTo(0.5) }; rows.addArrangedSubview(line)
      }
    }
    formStack.addArrangedSubview(QFTabUI.card(rows, padding: 14))
    let add = QFTabUI.button(app.text("＋ 添加用料", "+ Add material"), size: 14, color: QFUI.orange) { [weak self] in self?.chooseIngredient(nil) }
    add.accessibilityIdentifier = "plan.complete.addMaterial"
    formStack.addArrangedSubview(add)
    let costText = QFContentUI.label("—", size: 15, color: QFUI.green)
    costText.accessibilityIdentifier = "plan.complete.cost"; costText.textAlignment = .right; costLabel = costText
    let cost = QFTabUI.stack([
      QFContentUI.label(app.text("本次消耗成本", "Cost of this cooking"), size: 18, bold: true),
      costText
    ], axis: .horizontal, spacing: 12)
    cost.alignment = .center
    let costCard = QFTabUI.card(cost, background: QFUI.paleGreen)
    costCard.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(retryCostPreview)))
    formStack.addArrangedSubview(costCard)
    formStack.isUserInteractionEnabled = !draft.pending && !submitting && !loadingTemplate
    bodyStack.isUserInteractionEnabled = formStack.isUserInteractionEnabled
    saveButton.setTitle(draft.pending ? app.text("重试", "Retry") : app.text("完成打卡", "Mark as cooked"), for: .normal)
    saveButton.isEnabled = !submitting && !loadingTemplate && (draft.prepared || draft.pending)
    scheduleCostPreview(); updatePreviewLabels()
  }
  private func materialRow(_ index: Int) -> UIView {
    let item = draft.record.materials[index]
    let name = QFTabUI.button(item.name, size: 15, weight: .semibold) { [weak self] in self?.chooseIngredient(index) }
    name.titleLabel?.numberOfLines = 0; name.contentHorizontalAlignment = .leading
    name.contentEdgeInsets = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
    name.accessibilityIdentifier = "plan.complete.material.\(index)"
    let stock = QFContentUI.label(stockText(item), size: 11, color: item.ingredientId == nil ? QFUI.orange : QFUI.secondary)
    stock.numberOfLines = 0
    stock.accessibilityIdentifier = "plan.complete.stock.\(index)"
    materialStockLabels[index] = stock
    let usage = UIButton(type: .system)
    usage.setTitle(item.usageStatus == "HAS_REMAINDER" ? app.text("有余量", "Has remainder") : app.text("已使用", "Used"), for: .normal)
    usage.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
    usage.setTitleColor(QFUI.orange, for: .normal)
    usage.contentHorizontalAlignment = .leading
    usage.accessibilityIdentifier = "plan.complete.usage.\(index)"
    usage.addAction(UIAction { [weak self, weak usage] _ in
      guard let self, let usage, !self.draft.pending, self.draft.record.materials.indices.contains(index) else { return }
      let remainder = self.draft.record.materials[index].usageStatus != "HAS_REMAINDER"
      self.draft.record.materials[index].usageStatus = remainder ? "HAS_REMAINDER" : "USED"
      usage.setTitle(remainder ? self.app.text("有余量", "Has remainder") : self.app.text("已使用", "Used"), for: .normal)
      _ = self.persist()
    }, for: .touchUpInside)
    let info = QFTabUI.stack([name, stock, usage], spacing: 3)
    let amount = QFContentUI.field(app.text("实际用量", "Amount used"), text: item.amount, keyboard: .decimalPad, limit: 11) { [weak self] value in
      guard let self, !self.draft.pending, self.draft.record.materials.indices.contains(index) else { return }
      self.draft.record.materials[index].amount = value; _ = self.persist(); self.updateStockLabels()
    }
    amount.accessibilityIdentifier = "plan.complete.amount.\(index)"
    amount.backgroundColor = QFUI.background
    amount.snp.makeConstraints { $0.width.equalTo(62) }
    let unit = QFTabUI.button(unitTitle(item.unit), size: 14, background: QFUI.background) {}
    unit.addAction(UIAction { [weak self, weak unit] _ in self?.chooseUnit(index, source: unit) }, for: .touchUpInside)
    unit.titleLabel?.numberOfLines = 0
    unit.accessibilityIdentifier = "plan.complete.unit.\(index)"
    unit.snp.makeConstraints { $0.width.equalTo(60); $0.height.greaterThanOrEqualTo(48) }
    let price = QFContentUI.label("—", size: 14, color: QFUI.secondary)
    price.textAlignment = .right; price.snp.makeConstraints { $0.width.equalTo(35) }
    price.accessibilityLabel = app.text("消耗成本", "Cooking cost")
    price.adjustsFontSizeToFitWidth = true; price.minimumScaleFactor = 0.7
    materialCostLabels[index] = price
    let row = QFTabUI.stack([info, amount, unit, price], axis: .horizontal, spacing: 6)
    row.alignment = .center; row.snp.makeConstraints { $0.height.greaterThanOrEqualTo(QFMealCompletionLayout.rowHeight) }
    return row
  }
  private func scheduleCostPreview(force: Bool = false) {
    let request = QFCookingCostPreviewRequest(date: draft.record.date, householdId: draft.plan.householdId, items: [.init(draft.record, measurableOnly: true)])
    costPreview.update(!draft.pending && !submitting && draft.prepared ? request : nil, force: force)
  }
  @objc private func retryCostPreview() { if costPreview.failure != nil { scheduleCostPreview(force: true) } }
  private func updatePreviewLabels() {
    costLabel?.text = costPreview.summary(itemID: draft.record.id)
    for (index, label) in materialCostLabels where draft.record.materials.indices.contains(index) {
      label.text = costPreview.material(draft.record.materials[index], itemID: draft.record.id, units: units, unitPrice: false)
    }
  }
  private func unitTitle(_ code: String) -> String { units.first { $0.code == code }?.name ?? code }
  private func stockText(_ material: QFWorkMaterial) -> String {
    guard let id = material.ingredientId else { return app.text("请选择对应食材", "Choose matching ingredient") }
    guard balancesLoaded else { return app.text("库存待核对", "Check stock") }
    let matching = balances.filter { $0.ingredientId == id }
    let display = matching.isEmpty ? app.text("暂无库存", "No stock")
      : matching.map { app.format("库存 %@ %@", "Stock: %@ %@", $0.quantity, unitTitle($0.unitCode)) }.joined(separator: " · ")
    guard let selected = units.first(where: { $0.code == material.unit || $0.name == material.unit }),
      let selectedFactor = Decimal(string: selected.factorToBase), selectedFactor > 0,
      let required = Decimal(string: material.amount), required > 0 else { return display }
    var available = Decimal.zero
    var incompatible = false
    for row in matching {
      guard let unit = units.first(where: { $0.code == row.unitCode }),
        unit.dimension == selected.dimension,
        let factor = Decimal(string: unit.factorToBase),
        let quantity = Decimal(string: row.quantity) else { incompatible = true; continue }
      available += quantity * factor / selectedFactor
    }
    // An ingredient-specific density conversion may exist on the server. Do not
    // claim a shortage locally if a stock unit cannot be converted here.
    guard !incompatible else { return display }
    let sameIngredient = draft.record.materials.filter { $0.ingredientId == id && $0.hasNumericAmount }
    guard sameIngredient.allSatisfy({ item in
      units.first(where: { $0.code == item.unit || $0.name == item.unit })?.dimension == selected.dimension
    }) else { return display }
    let totalRequired = sameIngredient.reduce(Decimal.zero) { sum, item in
      guard let unit = units.first(where: { $0.code == item.unit || $0.name == item.unit }),
        unit.dimension == selected.dimension,
        let factor = Decimal(string: unit.factorToBase),
        let quantity = Decimal(string: item.amount), quantity > 0 else { return sum }
      return sum + quantity * factor / selectedFactor
    }
    let missing = max(Decimal.zero, totalRequired - available)
    guard missing > 0 else { return display }
    var rounded = Decimal.zero
    var mutable = missing
    NSDecimalRound(&rounded, &mutable, 3, .up)
    return display + " · " + app.format("缺少 %@ %@", "Missing %@ %@",
      NSDecimalNumber(decimal: rounded).stringValue, unitTitle(selected.code))
  }

  private func updateStockLabels() {
    for (index, label) in materialStockLabels where draft.record.materials.indices.contains(index) {
      label.text = stockText(draft.record.materials[index])
    }
  }
  private func chooseMeal(source: UIView?) {
    guard !draft.pending else { return }
    let sheet = UIAlertController(title: app.text("餐次", "Meal"), message: nil, preferredStyle: .actionSheet)
    for meal in QFCookingMeal.allCases {
      sheet.addAction(UIAlertAction(title: meal.title(app: app), style: .default) { [weak self] _ in
        guard let self else { return }; self.draft.record.meal = meal.rawValue; _ = self.persist(); self.render()
      })
    }
    showChoice(sheet, source: source)
  }
  private func chooseIngredient(_ index: Int?) {
    guard !draft.pending, index != nil || draft.record.materials.count < 40 else { return }
    open(QFCatalogSearchViewController(app: app, type: "INGREDIENT") { [weak self] item in
      guard let self else { return }
      if let index, self.draft.record.materials.indices.contains(index) {
        self.draft.record.materials[index].name = item.title; self.draft.record.materials[index].ingredientId = item.id
      } else { self.draft.record.materials.append(QFWorkMaterial(name: item.title, amount: "", unit: "g", ingredientId: item.id)) }
      _ = self.persist(); self.render(); self.loadBalances()
    })
  }
  private func chooseUnit(_ index: Int, source: UIView?) {
    guard !draft.pending else { return }
    let sheet = UIAlertController(title: app.text("选择单位", "Choose unit"), message: nil, preferredStyle: .actionSheet)
    for unit in units {
      sheet.addAction(UIAlertAction(title: unit.name, style: .default) { [weak self] _ in
        guard let self, self.draft.record.materials.indices.contains(index) else { return }
        self.draft.record.materials[index].unit = unit.code; _ = self.persist(); self.render()
      })
    }
    sheet.addAction(UIAlertAction(title: app.text("移除", "Remove"), style: .destructive) { [weak self] _ in
      guard let self, self.draft.record.materials.indices.contains(index) else { return }
      self.draft.record.materials.remove(at: index); _ = self.persist(); self.render()
    })
    showChoice(sheet, source: source)
  }
  private func showChoice(_ sheet: UIAlertController, source: UIView?) {
    sheet.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    sheet.popoverPresentationController?.sourceView = source ?? view
    sheet.popoverPresentationController?.sourceRect = source?.bounds ?? view.bounds
    open(sheet)
  }
  private func loadBalances() {
    balanceTask?.cancel(); balanceRequestID = UUID(); balancesLoaded = false
    let id = balanceRequestID, ids = Set(draft.record.materials.compactMap(\.ingredientId)).sorted()
    guard !ids.isEmpty else { return }
    let household = draft.plan.householdId
    balanceTask = Task { [weak self] in
      guard let self else { return }
      do {
        var query = ["ingredientIds": ids.joined(separator: ",")]
        if let household { query["householdId"] = household }
        let response: QFInventoryBalances = try await self.app.contentRequest(path: "me/inventory/balances", query: query)
        try Task.checkCancellation(); guard self.balanceRequestID == id else { return }
        self.balances = response.items; self.balancesLoaded = true
        // Preserve any active amount field and keyboard while the read completes.
        if self.view.qfHasFirstResponder { self.updateStockLabels() }
        else { self.render() }
      } catch is CancellationError {
      } catch { /* Final save validates current stock atomically; no fabricated zero. */ }
    }
  }
  private func submit() {
    guard !submitting, !loadingTemplate else { return }
    view.endEditing(true)
    let wasPending = draft.pending
    if !draft.pending {
      guard draft.confirmedMaterials else {
        message(app.text("请核对食材、实际用量和单位。", "Confirm each ingredient, actual quantity and unit."), error: true); return
      }
      if let error = draft.record.validation(app: app) { message(error, error: true); return }
      draft.pending = true
    }
    guard persist() else { draft.pending = wasPending; render(); return }
    submitting = true; render()
    let record = draft.record, language = draft.language
    execute { [self] in
      defer {
        submitting = false
        DispatchQueue.main.async { [weak self] in self?.render() }
      }
      do {
        let result: QFCookingRecord = try await QFContentLoadingContext.$language.withValue(language) {
          try await app.contentRequest(path: "me/cooking-records/\(record.id)", method: "PUT", body: JSONEncoder().encode(record.requestBody))
        }
        guard result.inventoryMode == "ACTUAL_MATERIALS" else {
          message(app.text("服务暂时不可用，请稍后重试。", "The service is temporarily unavailable. Please try again later."), error: true)
          return
        }
        savedSuccessfully = true; QFContentDraftStore.remove(app: app, kind: draftKey)
        saved(); qfClose()
      } catch {
        if let error = error as? QFAPIError, [40900, 40400].contains(error.code) {
          try await resolveConflict(recordID: record.id)
          return
        }
        if let error = error as? QFAPIError, [42205, 42206, 42207].contains(error.code) { draft.pending = false; _ = persist(); render() }
        throw error
      }
    }
  }
  private func resolveConflict(recordID: String) async throws {
    do {
      let _: QFCookingRecord = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.contentRequest(path: "me/cooking-records/\(recordID)")
      }
      // An earlier commit exists. Never create a replacement ID to bypass its receipt.
      savedSuccessfully = true; QFContentDraftStore.remove(app: app, kind: draftKey)
      saved(); closeWithSuccess(app.text("做菜记录已保存", "Cooking record saved"))
    } catch let error as QFAPIError where error.code == 40400 {
      let alert = UIAlertController(title: app.text("计划已变更", "Plan changed"),
        message: app.text("返回计划并重新核对？此页尚未保存的用量将被丢弃。", "Return to the plan to review it? Unsaved quantities on this page will be discarded."), preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
      alert.addAction(UIAlertAction(title: app.text("返回计划", "Return to plan"), style: .destructive) { [weak self] _ in
        guard let self else { return }
        QFContentDraftStore.remove(app: self.app, kind: self.draftKey)
        self.savedSuccessfully = true; self.saved(); self.qfClose()
      })
      open(alert)
    }
  }
  override func close() {
    guard !submitting else { return }
    if hasUnsavedChanges {
      guard persist() else { return }
    }
    qfClose()
  }
}

private extension UIView {
  var qfHasFirstResponder: Bool { isFirstResponder || subviews.contains { $0.qfHasFirstResponder } }
}
