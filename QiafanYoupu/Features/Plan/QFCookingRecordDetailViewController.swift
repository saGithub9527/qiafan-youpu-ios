import SnapKit
import UIKit

struct QFCookingRecordEditDraft: Codable {
  var baseline: QFCookingRecord
  var record: QFCookingRecord
  var language: String
  var pending: QFCookingDraft?
  init(record: QFCookingRecord, language: String) {
    baseline = record; self.record = record; self.language = language
  }
  @discardableResult mutating func addMaterial(name: String, ingredientID: String) -> Bool {
    guard pending == nil, record.materials.count < 40 else { return false }
    record.materials.append(QFWorkMaterial(name: name, amount: "", unit: "g", ingredientId: ingredientID))
    return true
  }
  @discardableResult mutating func replaceMaterial(at index: Int, expected: QFWorkMaterial, name: String, ingredientID: String) -> Bool {
    guard pending == nil, record.materials.indices.contains(index), record.materials[index] == expected else { return false }
    if expected.ingredientId == ingredientID { return true }
    // A different ingredient requires its own confirmed amount, not the previous ingredient's amount.
    record.materials[index] = QFWorkMaterial(name: name, amount: "", unit: "g", ingredientId: ingredientID)
    return true
  }
  @discardableResult mutating func removeMaterial(at index: Int, expected: QFWorkMaterial) -> Bool {
    guard pending == nil, record.materials.indices.contains(index), record.materials[index] == expected else { return false }
    record.materials.remove(at: index)
    return true
  }
  var hasChangedCostInputs: Bool { record.date != baseline.date || record.materials != baseline.materials }
  mutating func prepare() -> Bool {
    if pending != nil { return true }
    guard let revision = baseline.revision else { return false }
    let changedMaterials = record.materials != baseline.materials
    var body = QFCookingDraft(date: record.date, title: record.title, meal: record.meal,
      currency: record.currency, cost: changedMaterials ? nil : record.cost,
      materials: record.materials, note: record.note, plannedMealId: record.plannedMealId)
    body.expectedPlanRevision = nil; body.expectedRevision = revision
    body.requestId = UUID().uuidString.lowercased()
    pending = body
    return true
  }
}

// The cost endpoint groups ledger allocations by ingredient and base unit. Match that
// grouping without distributing a known amount across duplicate draft rows or guessing density.
enum QFCookingRecordCostMatch {
  static func key(ingredientID: String?, name: String, amount: String, unit: String,
                  units: [QFMeasurementUnit]) -> (String, Decimal)? {
    guard let quantity = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")), quantity > 0 else { return nil }
    let identity = ingredientID?.lowercased() ?? "name:" + name
    if let metadata = units.first(where: { $0.code == unit }),
       let factor = Decimal(string: metadata.factorToBase), factor > 0,
       ["MASS", "VOLUME"].contains(metadata.dimension) {
      return (identity + "|" + metadata.dimension, quantity * factor)
    }
    return (identity + "|" + unit, quantity)
  }
  static func matches(_ cost: QFCookingCost, record: QFCookingRecord, units: [QFMeasurementUnit]) -> Bool {
    guard cost.recordId == record.id, cost.date == record.date else { return false }
    var expected: [String: Decimal] = [:], actual: [String: Decimal] = [:]
    for item in record.materials {
      guard let (key, value) = Self.key(ingredientID: item.ingredientId, name: item.name, amount: item.amount, unit: item.unit, units: units) else { return false }
      expected[key, default: 0] += value
    }
    for item in cost.materials {
      guard let (key, value) = Self.key(ingredientID: item.ingredientId, name: item.name, amount: item.quantity, unit: item.unitCode, units: units) else { return false }
      actual[key, default: 0] += value
    }
    return expected == actual
  }
}

enum QFCookingRecordDetailLayout {
  static let pageInset: CGFloat = 24
  static let cardRadius: CGFloat = 18
  static let rowHeight: CGFloat = 46
  static let actionHeight: CGFloat = 52
}

@MainActor
final class QFCookingRecordDetailViewController: QFProfileContentController {
  private var state: QFCookingRecordEditDraft
  private let draftKey: String
  private let draftOwnerID: String?
  private var editingRecord = false
  private var submitting = false
  private var loading = true
  private var units: [QFMeasurementUnit] = []
  private let form = QFTabUI.stack([], spacing: 20)
  private var saveButton: UIButton!
  private var deleteButton: UIButton!
  private var editButton: UIButton!
  private weak var costValue: UILabel?
  private var materialCostLabels: [UILabel] = []
  private var savedCost: QFCookingCost?
  private var costLoading = false
  private var costFailed = false
  private var costTask: Task<Void, Never>?
  private var costRequestID = UUID()
  private var needsCostRefresh = false
  private var costAction: UIButton?
  override var reloadsOnAppearance: Bool { false }
  override var hasUnsavedChanges: Bool { state.pending != nil || state.record != state.baseline }

  init(app: QFAppSession, record: QFCookingRecord) {
    draftOwnerID = app.user?.userId
    draftKey = "cooking-edit.\(record.id)"
    state = QFContentDraftStore.load(QFCookingRecordEditDraft.self, app: app, kind: draftKey)
      ?? QFCookingRecordEditDraft(record: record, language: app.interfaceLanguage)
    // A saved draft keeps its original revision; a newer list snapshot must not
    // silently authorize stale quantities to overwrite the newer record.
    super.init(app: app, title: app.text("做菜记录", "Cooking history"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "cooking.detail"
    editingRecord = hasUnsavedChanges
    bodyStack.addArrangedSubview(form)
    contentStack.snp.remakeConstraints {
      $0.top.equalToSuperview().offset(14); $0.bottom.equalToSuperview().inset(24)
      $0.centerX.equalToSuperview(); $0.width.equalToSuperview().offset(-48).priority(999)
      $0.width.lessThanOrEqualTo(QFAdaptiveLayout.contentMaxWidth - 48)
    }
    editButton = QFTabUI.button("", size: 13, color: QFUI.orange) { [weak self] in
      guard let self, !self.submitting, !self.loading, self.state.pending == nil else { return }
      self.view.endEditing(true); self.editingRecord.toggle(); self.render()
    }
    editButton.accessibilityIdentifier = "cooking.detail.edit"
    installHeaderAction(editButton)
    footer.axis = .vertical; footer.distribution = .fill
    footer.snp.updateConstraints { $0.width.equalToSuperview().offset(-48).priority(999) }
    saveButton = addFooter(app.text("保存修改", "Save changes")) { [weak self] in self?.save() }
    saveButton.accessibilityIdentifier = "cooking.detail.save"
    saveButton.snp.remakeConstraints { $0.height.greaterThanOrEqualTo(QFCookingRecordDetailLayout.actionHeight) }
    deleteButton = addFooter(app.text("撤销本次打卡", "Undo this completion"), primary: false) { [weak self] in self?.confirmDelete() }
    deleteButton.setTitleColor(QFUI.danger, for: .normal)
    deleteButton.accessibilityIdentifier = "cooking.detail.delete"
    let backdrop = UIView(); backdrop.backgroundColor = QFUI.surface
    view.insertSubview(backdrop, belowSubview: footer)
    backdrop.snp.makeConstraints { $0.leading.trailing.bottom.equalToSuperview(); $0.top.equalTo(footer.snp.top).offset(-16) }
    footer.backgroundColor = QFUI.surface
    render()
    execute(reloadOnFailure: true) { [self] in
      defer { loading = false; render() }
      units = try await app.measurementUnits()
      if state.baseline.revision == nil && !hasUnsavedChanges {
        let latest: QFCookingRecord = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
          try await app.contentRequest(path: "me/cooking-records/\(state.record.id)")
        }
        state = QFCookingRecordEditDraft(record: latest, language: app.interfaceLanguage)
      }
      try Task.checkCancellation()
      loadCost()
    }
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if needsCostRefresh { needsCostRefresh = false; loadCost(force: true) }
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isMovingFromParent || isBeingDismissed { costTask?.cancel() }
  }
  private func loadCost(force: Bool = false) {
    costTask?.cancel(); costRequestID = UUID()
    let requestID = costRequestID, baseline = state.baseline
    let owner = app.user?.userId, language = app.interfaceLanguage
    savedCost = nil; costLoading = true; costFailed = false; updateCost()
    costTask = Task { [weak self] in
      guard let self else { return }
      do {
        let response: QFCookingCost = try await QFContentLoadingContext.$forceRefresh.withValue(force) {
          try await self.app.contentRequest(path: "me/cooking-records/\(baseline.id)/cost")
        }
        try Task.checkCancellation()
        guard self.costRequestID == requestID, self.app.user?.userId == owner,
          self.app.interfaceLanguage == language, self.state.baseline == baseline else { return }
        self.savedCost = response; self.costLoading = false; self.updateCost()
      } catch {
        guard !Task.isCancelled, self.costRequestID == requestID, self.app.user?.userId == owner,
          self.app.interfaceLanguage == language, self.state.baseline == baseline else { return }
        self.costFailed = true; self.costLoading = false; self.updateCost()
      }
    }
  }
  @discardableResult private func persist() -> Bool {
    guard app.user?.userId == draftOwnerID else { return false }
    let result = QFContentDraftStore.save(state, app: app, kind: draftKey)
    if !result { message(app.text("草稿保存失败，请重试。", "Could not save the draft. Please retry."), error: true) }
    return result
  }
  private func render() {
    QFTabUI.clear(form); materialCostLabels = []; costAction = nil
    editButton.setTitle(editingRecord ? app.text("收起修改", "Close editing") : app.text("修改记录", "Edit record"), for: .normal)
    editButton.isEnabled = !submitting && !loading && state.pending == nil
    let name = QFContentUI.label(state.record.title, size: 21, bold: true)
    let subtitle = QFContentUI.label("\(state.record.date) · \(state.record.mealTitle(app: app))", size: 13, color: QFUI.secondary)
    let badgeLabel = QFContentUI.label(app.text("已打卡", "Completed"), size: 13, color: QFUI.green)
    badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
    badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    let badge = QFTabUI.card(badgeLabel, padding: 10, background: QFUI.paleGreen)
    let identity = QFTabUI.stack([QFTabUI.stack([name, subtitle], spacing: 10), badge], axis: .horizontal, spacing: 12)
    identity.alignment = .center
    form.addArrangedSubview(QFTabUI.card(identity, padding: 16))
    if editingRecord { form.addArrangedSubview(dateAndMeal()) }
    let heading = QFContentUI.label(app.text("实际用料", "Materials used"), size: 18, bold: true)
    let count = QFContentUI.label(app.format("%d 项食材", "%d ingredients", state.record.materials.count), size: 12, color: QFUI.secondary)
    count.textAlignment = .right
    form.addArrangedSubview(QFTabUI.stack([heading, count], axis: .horizontal, spacing: 10))
    let rows = QFTabUI.stack([], spacing: 8)
    let header = tableRow([
      QFContentUI.label(app.text("食材", "Ingredients"), size: 12, color: QFUI.secondary),
      QFContentUI.label(app.text("实际用量", "Amount used"), size: 12, color: QFUI.secondary),
      QFContentUI.label(app.text("单位", "Unit"), size: 12, color: QFUI.secondary),
      QFContentUI.label(app.text("成本", "Cost"), size: 12, color: QFUI.secondary)])
    rows.addArrangedSubview(header)
    for index in state.record.materials.indices {
      let item = state.record.materials[index]
      let amount: UIView
      if editingRecord {
        let field = QFContentUI.field(app.text("实际用量", "Amount used"), text: item.amount, keyboard: .decimalPad, limit: 11) { [weak self] value in
          guard let self, self.state.pending == nil, self.state.record.materials.indices.contains(index) else { return }
          self.state.record.materials[index].amount = value; self.persist(); self.updateCost()
        }
        field.accessibilityIdentifier = "cooking.detail.amount.\(index)"
        field.backgroundColor = QFUI.background; amount = field
      } else { amount = QFContentUI.label(item.amount, size: 15) }
      let unit = QFTabUI.button(unitTitle(item.unit), size: 13, background: editingRecord ? QFUI.background : .clear) {}
      unit.titleLabel?.numberOfLines = 0; unit.isEnabled = editingRecord
      unit.addAction(UIAction { [weak self, weak unit] _ in self?.chooseUnit(index, source: unit) }, for: .touchUpInside)
      let name: UIView
      if editingRecord {
        let button = QFTabUI.button(item.name, size: 15, color: QFUI.orange) {}
        button.titleLabel?.numberOfLines = 0; button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = "cooking.detail.material.\(index)"
        button.addAction(UIAction { [weak self, weak button] _ in self?.chooseMaterialAction(index, source: button) }, for: .touchUpInside)
        name = button
      } else { name = QFContentUI.label(item.name, size: 15) }
      let cost = QFContentUI.label("", size: 11, color: QFUI.secondary)
      cost.accessibilityIdentifier = "cooking.detail.material-cost.\(index)"
      materialCostLabels.append(cost)
      let row = tableRow([name, amount, unit, cost])
      row.snp.makeConstraints { $0.height.greaterThanOrEqualTo(QFCookingRecordDetailLayout.rowHeight) }
      rows.addArrangedSubview(row)
      if index < state.record.materials.count - 1 {
        let line = UIView(); line.backgroundColor = QFUI.border; line.snp.makeConstraints { $0.height.equalTo(0.5) }; rows.addArrangedSubview(line)
      }
    }
    if editingRecord {
      let add = QFTabUI.button(app.text("添加用料", "Add material"), size: 15, color: QFUI.orange) { [weak self] in self?.pickMaterial() }
      add.accessibilityIdentifier = "cooking.detail.add-material"
      add.isEnabled = state.record.materials.count < 40
      add.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
      rows.addArrangedSubview(add)
    }
    form.addArrangedSubview(QFTabUI.card(rows, padding: 16))
    let value = QFContentUI.label("", size: 18, color: QFUI.green)
    value.textAlignment = .right; value.accessibilityIdentifier = "cooking.detail.cost"; costValue = value
    form.addArrangedSubview(QFTabUI.stack([
      QFContentUI.label(app.text("本次消耗成本", "Cost of this cooking"), size: 17, bold: true),
      value
    ], axis: .horizontal, spacing: 12))
    let action = QFTabUI.button("", size: 14, color: QFUI.orange) { [weak self] in
      guard let self else { return }
      if self.costFailed { self.loadCost(force: true); return }
      guard let cost = self.savedCost, !self.state.hasChangedCostInputs,
        QFCookingRecordCostMatch.matches(cost, record: self.state.baseline, units: self.units) else { return }
      let editor = QFMissingCostViewController(app: self.app, record: cost)
      editor.onChanged = { [weak self] in self?.needsCostRefresh = true; self?.onChanged?() }
      self.open(editor)
    }
    costAction = action; action.accessibilityIdentifier = "cooking.detail.cost-action"
    form.addArrangedSubview(action); updateCost()
    form.isUserInteractionEnabled = state.pending == nil && !submitting && !loading
    saveButton.isHidden = !editingRecord && state.pending == nil
    saveButton.setTitle(state.pending == nil ? app.text("保存修改", "Save changes") : app.text("重试", "Retry"), for: .normal)
    saveButton.isEnabled = !submitting && !loading
    deleteButton.isEnabled = !submitting && !loading && state.pending == nil && state.baseline.revision != nil
  }
  private func updateCost() {
    materialCostLabels.forEach { $0.text = app.text("成本待补全", "Cost missing") }
    costAction?.isHidden = true
    if state.hasChangedCostInputs {
      costValue?.text = app.text("保存后更新成本", "Cost updates after saving")
      materialCostLabels.forEach { $0.text = "—" }
      return
    }
    if costLoading { costValue?.text = app.text("正在加载", "Loading"); return }
    if costFailed {
      costValue?.text = app.text("暂时无法加载", "Unable to load")
      costAction?.setTitle(app.text("重试", "Retry"), for: .normal); costAction?.isHidden = false
      return
    }
    guard let cost = savedCost, QFCookingRecordCostMatch.matches(cost, record: state.baseline, units: units) else {
      costValue?.text = app.text("历史库存依据待确认", "Historical inventory needs verification"); return
    }
    let locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    func money(_ totals: [QFCurrencyTotal]) -> String {
      totals.map { QFPurchaseNumber.money($0.total, currency: $0.currency, locale: locale) }.joined(separator: "\n")
    }
    let known = money(cost.totals)
    let pending = cost.status == "UNVERIFIED" ? app.text("历史库存依据待确认", "Historical inventory needs verification")
      : app.format("%d 项待补全", "%d pending", cost.pendingMaterialCount)
    costValue?.text = [known.isEmpty ? nil : known, cost.status == "COMPLETE" ? nil : pending].compactMap { $0 }.joined(separator: "\n")
    if costValue?.text?.isEmpty != false { costValue?.text = app.text("成本待补全", "Cost missing") }
    var seen = Set<String>()
    for (index, row) in state.record.materials.enumerated() where materialCostLabels.indices.contains(index) {
      guard let (key, _) = QFCookingRecordCostMatch.key(ingredientID: row.ingredientId, name: row.name, amount: row.amount, unit: row.unit, units: units) else { continue }
      guard seen.insert(key).inserted else { materialCostLabels[index].text = app.text("已计入合计", "Included in total"); continue }
      let matches = cost.materials.filter { QFCookingRecordCostMatch.key(ingredientID: $0.ingredientId, name: $0.name, amount: $0.quantity, unit: $0.unitCode, units: units)?.0 == key }
      // Duplicate ingredient lines share one allocation total. Show it once, without inventing a per-line split.
      let known = money(matches.flatMap(\.totals))
      let missing = matches.contains { $0.status != "COMPLETE" }
      materialCostLabels[index].text = [known.isEmpty ? nil : known, missing ? app.text("成本待补全", "Cost missing") : nil].compactMap { $0 }.joined(separator: "\n")
    }
    costAction?.setTitle(app.text("补全食材成本", "Complete ingredient costs"), for: .normal)
    costAction?.isHidden = cost.status == "COMPLETE"
  }
  private func tableRow(_ views: [UIView]) -> UIStackView {
    let row = QFTabUI.stack(views, axis: .horizontal, spacing: 6); row.alignment = .center
    for (index, width) in [(1, 59), (2, 60), (3, 35)] { views[index].snp.makeConstraints { $0.width.equalTo(width) } }
    return row
  }
  private func dateAndMeal() -> UIView {
    let date = UIDatePicker(); date.datePickerMode = .date; date.preferredDatePickerStyle = .compact
    date.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    date.calendar = QFManualPlanDraft.calendar; date.timeZone = QFManualPlanDraft.calendar.timeZone
    date.date = QFManualPlanDraft.date(state.record.date) ?? Date(); date.maximumDate = Date()
    date.addAction(UIAction { [weak self, weak date] _ in
      guard let self, let date, self.state.pending == nil else { return }
      self.state.record.date = QFContentDate.day(date.date); self.persist(); self.updateCost()
    }, for: .valueChanged)
    let meal = QFTabUI.button(state.record.mealTitle(app: app), size: 16, background: QFUI.surface) {}
    meal.snp.makeConstraints { $0.height.greaterThanOrEqualTo(46) }
    meal.addAction(UIAction { [weak self, weak meal] _ in
      guard let self, self.state.pending == nil else { return }
      let alert = UIAlertController(title: self.app.text("餐次", "Meal"), message: nil, preferredStyle: .actionSheet)
      for choice in QFCookingMeal.allCases {
        alert.addAction(UIAlertAction(title: choice.title(app: self.app), style: .default) { [weak self] _ in
          guard let self else { return }; self.state.record.meal = choice.rawValue; self.persist(); self.render()
        })
      }
      alert.addAction(UIAlertAction(title: self.app.text("取消", "Cancel"), style: .cancel))
      alert.popoverPresentationController?.sourceView = meal; alert.popoverPresentationController?.sourceRect = meal?.bounds ?? .zero
      self.open(alert)
    }, for: .touchUpInside)
    let row = QFTabUI.stack([
      QFTabUI.stack([QFContentUI.label(app.text("实际日期", "Actual date"), size: 13, color: QFUI.secondary), QFTabUI.card(date, padding: 8, border: true)], spacing: 8),
      QFTabUI.stack([QFContentUI.label(app.text("餐次", "Meal"), size: 13, color: QFUI.secondary), meal], spacing: 8)
    ], axis: .horizontal, spacing: 12)
    row.alignment = .top
    row.arrangedSubviews[0].snp.makeConstraints { $0.width.equalTo(row.snp.width).multipliedBy(0.62).offset(-6) }
    return row
  }
  private func unitTitle(_ code: String) -> String { units.first(where: { $0.code == code })?.name ?? code }
  private func chooseUnit(_ index: Int, source: UIView?) {
    guard state.pending == nil, editingRecord, state.record.materials.indices.contains(index), !units.isEmpty else { return }
    let expected = state.record.materials[index]
    let alert = UIAlertController(title: app.text("单位", "Unit"), message: nil, preferredStyle: .actionSheet)
    for unit in units {
      alert.addAction(UIAlertAction(title: unit.name, style: .default) { [weak self] _ in
        guard let self, self.state.pending == nil, self.state.record.materials.indices.contains(index), self.state.record.materials[index] == expected else { return }; self.state.record.materials[index].unit = unit.code; self.persist(); self.render()
      })
    }
    alert.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    alert.popoverPresentationController?.sourceView = source; alert.popoverPresentationController?.sourceRect = source?.bounds ?? .zero
    open(alert)
  }
  private func chooseMaterialAction(_ index: Int, source: UIView?) {
    guard editingRecord, state.pending == nil, state.record.materials.indices.contains(index) else { return }
    let expected = state.record.materials[index]
    view.endEditing(true)
    let alert = UIAlertController(title: expected.name, message: nil, preferredStyle: .actionSheet)
    alert.addAction(UIAlertAction(title: app.text("选择食材", "Choose ingredient"), style: .default) { [weak self] _ in self?.pickMaterial(replacing: index, expected: expected) })
    alert.addAction(UIAlertAction(title: app.text("移除", "Remove"), style: .destructive) { [weak self] _ in
      guard let self, self.app.user?.userId == self.draftOwnerID, self.state.removeMaterial(at: index, expected: expected) else { return }; self.persist(); self.render()
    })
    alert.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    alert.popoverPresentationController?.sourceView = source; alert.popoverPresentationController?.sourceRect = source?.bounds ?? .zero
    open(alert)
  }
  private func pickMaterial(replacing index: Int? = nil, expected: QFWorkMaterial? = nil) {
    guard editingRecord, !submitting, state.pending == nil else { return }
    let owner = app.user?.userId, language = app.interfaceLanguage
    view.endEditing(true)
    open(QFCatalogSearchViewController(app: app, type: "INGREDIENT") { [weak self] item in
      guard let self, self.app.user?.userId == owner, self.app.interfaceLanguage == language,
        self.editingRecord, !self.submitting, self.state.pending == nil else { return }
      let changed: Bool
      if let index, let expected { changed = self.state.replaceMaterial(at: index, expected: expected, name: item.title, ingredientID: item.id) }
      else { changed = self.state.addMaterial(name: item.title, ingredientID: item.id) }
      guard changed else { return }; self.persist(); self.render()
    })
  }
  private func save() {
    guard app.user?.userId == draftOwnerID, !submitting && !loading else { return }
    if !hasUnsavedChanges { editingRecord = false; render(); return }
    if state.pending == nil, let error = state.record.validation(app: app) { message(error, error: true); return }
    let wasPending = state.pending != nil
    guard state.prepare(), let body = state.pending else {
      message(app.text("记录需要重新载入后才能修改。", "Reload this record before editing."), error: true); return
    }
    guard persist() else { if !wasPending { state.pending = nil }; render(); return }
    submitting = true; render()
    execute { [self] in
      defer { submitting = false; render() }
      do {
        let record: QFCookingRecord = try await QFContentLoadingContext.$language.withValue(state.language) {
          try await app.contentRequest(path: "me/cooking-records/\(state.record.id)", method: "PUT", body: JSONEncoder().encode(body))
        }
        guard record.revision != nil else { throw QFAPIError(code: 50300, message: "", requestId: nil) }
        state = QFCookingRecordEditDraft(record: record, language: app.interfaceLanguage)
        QFContentDraftStore.remove(app: app, kind: draftKey); editingRecord = false
        // An idempotent retry replays its first success, which can predate a later edit.
        // A normal save already has the current snapshot and needs no extra request.
        if wasPending {
          let latest: QFCookingRecord? = try? await QFContentLoadingContext.$forceRefresh.withValue(true) {
            try await app.contentRequest(path: "me/cooking-records/\(record.id)")
          }
          if let latest { state = QFCookingRecordEditDraft(record: latest, language: app.interfaceLanguage) }
        }
        loadCost(force: true)
        onChanged?()
        message(app.text("修改已保存", "Changes saved"))
      } catch let error as QFAPIError where [42205, 42206, 42207, 40000].contains(error.code) {
        state.pending = nil; persist(); throw error
      } catch let error as QFAPIError where [40900, 40400].contains(error.code) {
        try await reconcile()
      }
    }
  }
  private func reconcile() async throws {
    do {
      let latest: QFCookingRecord = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.contentRequest(path: "me/cooking-records/\(state.record.id)")
      }
      let alert = UIAlertController(title: app.text("记录已变更", "Record changed"),
        message: app.text("重新载入最新记录？尚未保存的修改将被丢弃。", "Reload the latest record? Unsaved changes will be discarded."), preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
      alert.addAction(UIAlertAction(title: app.text("重新载入", "Reload"), style: .destructive) { [weak self] _ in
        guard let self else { return }
        self.state = QFCookingRecordEditDraft(record: latest, language: self.app.interfaceLanguage)
        QFContentDraftStore.remove(app: self.app, kind: self.draftKey); self.editingRecord = false; self.onChanged?(); self.render(); self.loadCost(force: true)
      })
      open(alert)
    } catch let error as QFAPIError where error.code == 40400 {
      let alert = UIAlertController(title: app.text("记录已不存在", "Record no longer exists"), message: nil, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: app.text("返回", "Back"), style: .default) { [weak self] _ in
        guard let self else { return }; QFContentDraftStore.remove(app: self.app, kind: self.draftKey); self.onChanged?(); self.qfClose()
      }); open(alert)
    }
  }
  private func confirmDelete() {
    guard !submitting, state.pending == nil, let revision = state.baseline.revision else { return }
    let dialog = QFCookingUndoConfirmationController(app: app, record: state.baseline) { [weak self] in
      guard let self else { return }; self.submitting = true; self.render()
      self.execute { [self] in
        defer { self.submitting = false; self.render() }
        do {
          try await self.app.contentMutation(path: "me/cooking-records/\(self.state.record.id)", method: "DELETE", query: ["expectedRevision": String(revision)])
          QFContentDraftStore.remove(app: self.app, kind: self.draftKey); self.onChanged?(); self.qfClose()
        } catch let error as QFAPIError where error.code == 40900 { try await self.reconcile() }
      }
    }
    view.endEditing(true)
    present(dialog, animated: true)
  }
  override func close() {
    guard !submitting else { return }
    if hasUnsavedChanges && !persist() { return }
    costTask?.cancel(); qfClose()
  }
}

@MainActor
final class QFCookingUndoConfirmationController: UIViewController {
  private let app: QFAppSession
  private let record: QFCookingRecord
  private let confirmed: () -> Void
  init(app: QFAppSession, record: QFCookingRecord, confirmed: @escaping () -> Void) {
    self.app = app; self.record = record; self.confirmed = confirmed
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); view.accessibilityViewIsModal = true
    view.backgroundColor = UIColor.black.withAlphaComponent(0.3)
    let title = QFContentUI.label(app.text("撤销本次打卡？", "Undo this completion?"), size: 20, bold: true)
    title.textAlignment = .center
    let detail = QFContentUI.label(record.title + "\n\n" + app.text("恢复这条记录仍占用的库存，并更新做菜统计。", "Restore the stock still used by this record and update cooking statistics."), size: 16, color: QFUI.secondary)
    let keep = QFTabUI.button(app.text("保留记录", "Keep record"), size: 17, weight: .semibold, background: QFUI.surface) { [weak self] in self?.dismiss(animated: true) }
    keep.layer.borderWidth = 1; keep.layer.borderColor = QFUI.border.cgColor
    keep.accessibilityIdentifier = "cooking.undo.cancel"
    let undo = QFTabUI.button(app.text("确认撤销", "Confirm undo"), size: 17, weight: .semibold, color: QFUI.onPrimary, background: QFUI.danger) { [weak self] in
      guard let self else { return }; self.dismiss(animated: true, completion: self.confirmed)
    }
    undo.accessibilityIdentifier = "cooking.undo.confirm"
    let actions = QFTabUI.stack([keep, undo], axis: .horizontal, spacing: 12)
    actions.distribution = .fillEqually; actions.snp.makeConstraints { $0.height.greaterThanOrEqualTo(48) }
    let body = QFTabUI.stack([title, detail, actions], spacing: 30)
    let card = QFTabUI.card(body, padding: 20); card.layer.cornerRadius = 22
    view.addSubview(card)
    card.snp.makeConstraints {
      $0.center.equalTo(view.safeAreaLayoutGuide); $0.width.equalToSuperview().offset(-48).priority(999)
      $0.width.lessThanOrEqualTo(420); $0.top.greaterThanOrEqualTo(view.safeAreaLayoutGuide).offset(12)
      $0.bottom.lessThanOrEqualTo(view.safeAreaLayoutGuide).inset(12)
    }
  }
}
