import SnapKit
import UIKit

struct QFInventoryReceiveDraft: Codable {
  var lotID = UUID().uuidString.lowercased()
  var quantity = ""
  var unitCode = "g"
  var location = ""
  var acquiredOn: String?
  var expiresOn: String?
  var currency = "CNY"
  var totalCost = ""
  var packageSize: String?
  var packageContentUnit: String?
  var pending: QFInventoryLotDraft?
  var language: String?
}

/// A compact, searchable unit picker. The old UIAlertController action sheet
/// expanded with every server unit and became unusably tall on smaller phones.
/// Keep the picker on the navigation stack so edge-back and accessibility stay
/// consistent with the surrounding inventory editor.
@MainActor
final class QFMeasurementUnitSearchViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
  private let app: QFAppSession
  private let units: [QFMeasurementUnit]
  private let onSelect: (QFMeasurementUnit) -> Void
  private let onCustom: () -> Void
  private let tableView = UITableView(frame: .zero, style: .insetGrouped)
  private let searchBar = UISearchBar()
  private let customButton = UIButton(type: .system)
  private var filtered: [QFMeasurementUnit]

  init(app: QFAppSession, units: [QFMeasurementUnit], onSelect: @escaping (QFMeasurementUnit) -> Void, onCustom: @escaping () -> Void) {
    self.app = app
    self.units = units
    self.filtered = units
    self.onSelect = onSelect
    self.onCustom = onCustom
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.accessibilityIdentifier = "inventory.unitPicker"
    let header = QFSettingsPageUI.header(app.text("选择单位", "Choose unit"), backLabel: app.text("返回", "Back")) { [weak self] in self?.qfClose() }
    QFSettingsPageUI.installHeader(header, in: view)

    searchBar.searchBarStyle = .minimal
    searchBar.placeholder = app.text("搜索单位名称或符号", "Search unit name or symbol")
    searchBar.delegate = self
    searchBar.returnKeyType = .done
    view.addSubview(searchBar)
    searchBar.snp.makeConstraints {
      $0.top.equalTo(header.snp.bottom).offset(4)
      $0.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(14)
    }

    tableView.backgroundColor = .clear
    tableView.separatorStyle = .singleLine
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 56
    tableView.keyboardDismissMode = .onDrag
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "unit")
    view.addSubview(tableView)

    customButton.setTitle(app.text("自定义单位…", "Custom unit…"), for: .normal)
    customButton.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 16, weight: .semibold))
    customButton.titleLabel?.adjustsFontForContentSizeCategory = true
    customButton.setTitleColor(QFUI.orange, for: .normal)
    customButton.backgroundColor = QFUI.surface
    customButton.layer.cornerRadius = 16
    customButton.accessibilityIdentifier = "inventory.unitPicker.custom"
    customButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      let action = self.onCustom
      self.qfClose { action() }
    }, for: .touchUpInside)
    view.addSubview(customButton)
    customButton.snp.makeConstraints {
      $0.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20)
      $0.bottom.equalTo(view.keyboardLayoutGuide.snp.top).offset(-12)
      $0.height.greaterThanOrEqualTo(50)
    }
    tableView.snp.makeConstraints {
      $0.top.equalTo(searchBar.snp.bottom)
      $0.leading.trailing.equalTo(view.safeAreaLayoutGuide)
      $0.bottom.equalTo(customButton.snp.top).offset(-8)
    }
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { filtered.count }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "unit", for: indexPath)
    let unit = filtered[indexPath.row]
    var content = cell.defaultContentConfiguration()
    content.text = unit.name
    content.secondaryText = unit.symbol
    content.textProperties.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 16, weight: .medium))
    content.secondaryTextProperties.color = QFUI.secondary
    cell.contentConfiguration = content
    cell.accessibilityIdentifier = "inventory.unitPicker.unit.\(unit.code)"
    cell.accessibilityLabel = unit.name + " " + unit.symbol
    cell.accessoryType = .disclosureIndicator
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    onSelect(filtered[indexPath.row])
    qfClose()
  }

  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    filtered = query.isEmpty ? units : units.filter { unit in
      unit.name.lowercased().contains(query) || unit.symbol.lowercased().contains(query) || unit.code.lowercased().contains(query)
    }
    tableView.reloadData()
  }
}

@MainActor
final class QFInventoryLotEditorViewController: QFProfileContentController {
  private let ingredient: QFCatalogItem
  private let customIngredientName: String?
  private let householdID: String?
  private let onSaved: (QFInventoryLot) -> Void
  private let draftKey: String
  private var draft: QFInventoryReceiveDraft
  private var units: [QFMeasurementUnit] = []
  private var unitButton: UIButton?
  private var saveButton: UIButton!
  private var saved = false
  private var submitting = false
  private var locale: Locale { Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier) }
  override var reloadsOnAppearance: Bool { false }
  override var hasUnsavedChanges: Bool { !saved && (!draft.quantity.isEmpty || draft.pending != nil) }
  init(app: QFAppSession, ingredient: QFCatalogItem, householdID: String?, customIngredientName: String? = nil, onSaved: @escaping (QFInventoryLot) -> Void) {
    self.ingredient = ingredient; self.customIngredientName = customIngredientName; self.householdID = householdID; self.onSaved = onSaved
    draftKey = "inventory-receive." + (householdID ?? "personal") + "." + ingredient.id
    draft = QFContentDraftStore.load(QFInventoryReceiveDraft.self, app: app, kind: draftKey) ?? .init()
    super.init(app: app, title: app.text("添加食材", "Add ingredient"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); view.accessibilityIdentifier = "inventory.receive"
    setReloadAction(allowsPullToRefresh: false) { [weak self] in self?.loadUnits() }
    saveButton = addFooter(app.text("保存食材", "Save ingredient")) { [weak self] in self?.save() }
    saveButton.accessibilityIdentifier = "inventory.receive.save"; render(); loadUnits()
  }
  @discardableResult private func persist() -> Bool {
    let success = QFContentDraftStore.save(draft, app: app, kind: draftKey)
    if !success { message(app.text("草稿保存失败，请重试。", "Could not save the draft. Please retry."), error: true) }
    return success
  }
  private func loadUnits() {
    execute(reloadOnFailure: true, showsInitialReadProgress: false) { [self] in units = try await app.inventoryMeasurementUnits(householdID: householdID); unitButton?.setTitle(unitTitle(), for: .normal) }
  }
  private func unitTitle() -> String { units.first { $0.code == draft.unitCode }?.name ?? draft.unitCode }
  private func render() {
    QFTabUI.clear(bodyStack)
    bodyStack.addArrangedSubview(QFTabUI.card(QFTabUI.label(ingredient.title, size: 21, weight: .semibold, lines: 0), padding: 18, background: QFUI.paleGreen))
    let quantity = field(app.text("数量", "Quantity"), value: draft.quantity, keyboard: .decimalPad) { [weak self] in guard let self else { return }; self.draft.quantity = QFPurchaseNumber.normalize($0, locale: self.locale); self.persist() }
    quantity.accessibilityIdentifier = "inventory.receive.quantity"
    let unit = QFTabUI.button(unitTitle(), color: QFUI.text, background: QFUI.surface) { [weak self] in self?.chooseUnit() }; unitButton = unit
    let amount = QFTabUI.stack([labeled(app.text("数量", "Quantity"), quantity), labeled(app.text("单位", "Unit"), unit)], axis: .horizontal, spacing: 12); amount.distribution = .fillEqually
    bodyStack.addArrangedSubview(amount)
    bodyStack.addArrangedSubview(labeled(app.text("存放位置", "Storage location"), field(app.text("例如：冰箱冷藏", "For example: refrigerator"), value: draft.location) { [weak self] in self?.draft.location = $0; self?.persist() }))
    bodyStack.addArrangedSubview(dateField(acquired: true))
    if QFStockSpecification.isPackage(draft.unitCode) {
      bodyStack.addArrangedSubview(QFTabUI.button(app.text("规格与有效期", "Specification and expiry") + "  ›", color: QFUI.orange) { [weak self] in
        guard let self else { return }
        self.open(QFStockSpecificationViewController(app: self.app, unitCode: self.draft.unitCode, value: .init(packageSize: self.draft.packageSize, packageContentUnit: self.draft.packageContentUnit, expiresOn: self.draft.expiresOn), units: self.units) { [weak self] value in
          self?.draft.packageSize = value.packageSize; self?.draft.packageContentUnit = value.packageContentUnit; self?.draft.expiresOn = value.expiresOn; self?.persist(); self?.render()
        })
      })
    } else { bodyStack.addArrangedSubview(dateField(acquired: false)) }
    bodyStack.addArrangedSubview(labeled(app.text("这批库存总成本", "Total cost of this stock lot"), field(app.text("价格待补全", "Price needed"), value: draft.totalCost, keyboard: .decimalPad) { [weak self] in guard let self else { return }; self.draft.totalCost = QFPurchaseNumber.normalize($0, locale: self.locale); self.persist() }))
    bodyStack.addArrangedSubview(labeled(app.text("币种", "Currency"), field(app.text("币种", "Currency"), value: draft.currency, keyboard: .asciiCapable) { [weak self] in self?.draft.currency = $0.uppercased(); self?.persist() }))
    bodyStack.isUserInteractionEnabled = draft.pending == nil && !submitting
    saveButton.isEnabled = !submitting
    saveButton.setTitle(draft.pending == nil ? app.text("保存食材", "Save ingredient") : app.text("重试", "Retry"), for: .normal)
  }
  private func field(_ title: String, value: String, keyboard: UIKeyboardType = .default, changed: @escaping (String) -> Void) -> UITextField {
    QFContentUI.field(title, text: value, keyboard: keyboard, limit: keyboard == .default ? 100 : 24, changed: changed)
  }
  private func labeled(_ title: String, _ view: UIView) -> UIView { QFTabUI.stack([QFTabUI.label(title, size: 13, color: QFUI.secondary, lines: 0), view], spacing: 8) }
  private func dateField(acquired: Bool) -> UIView {
    let value = acquired ? draft.acquiredOn : draft.expiresOn
    let title = acquired ? app.text("已知取得日期", "Acquisition date is known") : app.text("标注到期日期", "Add expiry date")
    let toggle = UISwitch(); toggle.isOn = value != nil
    let picker = UIDatePicker(); picker.datePickerMode = .date; picker.preferredDatePickerStyle = .compact
    picker.locale = locale; picker.calendar = QFManualPlanDraft.calendar; picker.timeZone = QFManualPlanDraft.calendar.timeZone
    picker.date = value.flatMap(QFManualPlanDraft.date) ?? Date(); picker.isHidden = value == nil
    if acquired { picker.maximumDate = QFManualPlanDraft.date(QFContentDate.day(Date())) }
    toggle.addAction(UIAction { [weak self, weak toggle, weak picker] _ in
      guard let self, let toggle, let picker else { return }
      let selected = toggle.isOn ? QFManualPlanDraft.string(picker.date) : nil
      if acquired { self.draft.acquiredOn = selected } else { self.draft.expiresOn = selected }; picker.isHidden = !toggle.isOn; self.persist()
    }, for: .valueChanged)
    picker.addAction(UIAction { [weak self, weak picker] _ in
      guard let self, let picker else { return }; if acquired { self.draft.acquiredOn = QFManualPlanDraft.string(picker.date) } else { self.draft.expiresOn = QFManualPlanDraft.string(picker.date) }; self.persist()
    }, for: .valueChanged)
    return QFTabUI.card(QFTabUI.stack([QFTabUI.stack([QFTabUI.label(title, size: 15, lines: 0), UIView(), toggle], axis: .horizontal, spacing: 12), picker], spacing: 12), padding: 14, border: true)
  }
  private func chooseUnit() {
    view.endEditing(true)
    guard !units.isEmpty else { loadUnits(); return }
    qfPush(QFMeasurementUnitSearchViewController(app: app, units: units, onSelect: { [weak self] unit in
      guard let self else { return }
      self.draft.unitCode = unit.code; self.draft.packageSize = nil; self.draft.packageContentUnit = nil; self.persist(); self.render()
    }, onCustom: { [weak self] in self?.promptCustomUnit() }))
  }
  private func promptCustomUnit() {
    let alert = UIAlertController(title: app.text("自定义单位", "Custom unit"), message: app.text("自定义单位只按原单位计数，不会自动换算成克或毫升。", "Custom units are counted as entered and are not converted to grams or millilitres."), preferredStyle: .alert)
    alert.addTextField { $0.placeholder = self.app.text("例如：把、条、罐", "For example: bunch, strip, can") }
    alert.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: app.text("保存单位", "Save unit"), style: .default) { [weak self, weak alert] _ in
      guard let self, let label = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty, label.count <= 16 else { return }
      self.execute(label: self.app.text("正在保存", "Saving")) { [self] in
        let unit = try await self.app.createInventoryUnit(label: label, householdID: self.householdID)
        if !self.units.contains(where: { $0.code == unit.code }) { self.units.append(unit) }
        self.draft.unitCode = unit.code; self.draft.packageSize = nil; self.draft.packageContentUnit = nil
        _ = self.persist(); self.render()
      }
    })
    present(alert, animated: true)
  }
  private func save() {
    view.endEditing(true); guard !submitting else { return }
    if draft.pending == nil {
      guard (QFPurchaseNumber.decimal(draft.quantity) ?? 0) > 0, !draft.unitCode.isEmpty else { message(app.text("请输入大于 0 的数量。", "Enter a quantity greater than 0."), error: true); return }
      guard draft.currency.isEmpty || NSLocale.commonISOCurrencyCodes.contains(draft.currency) else { message(app.text("请确认原始数量、购买日期、币种和金额。", "Confirm the original quantity, purchase date, currency and amount."), error: true); return }
      if !draft.totalCost.isEmpty {
        guard draft.acquiredOn != nil, (QFPurchaseNumber.decimal(draft.totalCost) ?? -1) >= 0, NSLocale.commonISOCurrencyCodes.contains(draft.currency) else { message(app.text("请确认原始数量、购买日期、币种和金额。", "Confirm the original quantity, purchase date, currency and amount."), error: true); return }
      }
      draft.pending = .init(ingredientId: ingredient.id, quantity: draft.quantity, unitCode: draft.unitCode,
        expiresOn: draft.expiresOn, location: draft.location, householdId: householdID, expectedRevision: nil,
        idempotencyKey: UUID().uuidString.lowercased(), acquiredOn: draft.acquiredOn, acquiredTime: nil,
        timeZone: draft.acquiredOn == nil ? nil : TimeZone.current.identifier,
        currency: draft.currency.isEmpty ? nil : draft.currency, totalCost: draft.totalCost.isEmpty ? nil : draft.totalCost,
        packageUnit: QFStockSpecification.isPackage(draft.unitCode) ? draft.unitCode : nil, packageSize: draft.packageSize, packageContentUnit: draft.packageContentUnit,
        customIngredientName: customIngredientName)
      draft.language = app.interfaceLanguage
      guard persist() else { draft.pending = nil; return }
    }
    guard let pending = draft.pending else { return }; submitting = true; render()
    execute(label: app.text("正在保存", "Saving")) { [self] in
      defer { submitting = false; render() }
      do {
        let response = try await QFContentLoadingContext.$language.withValue(draft.language ?? app.interfaceLanguage) { try await app.saveInventoryLot(draft.lotID, draft: pending) }
        saved = true; QFContentDraftStore.remove(app: app, kind: draftKey); onSaved(response); onChanged?(); closeWithSuccess(app.text("库存已更新", "Inventory updated"))
      } catch {
        if let failure = error as? QFAPIError, failure.code == 40000 || failure.code == 42207 { draft.pending = nil; persist() }
        throw error
      }
    }
  }
}
