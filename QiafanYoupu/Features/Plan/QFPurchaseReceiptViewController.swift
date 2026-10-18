import SnapKit
import SafariServices
import UIKit

enum QFPurchaseLayout {
  static let pageInset: CGFloat = 20
  static let cardRadius: CGFloat = 18
  static let actionHeight: CGFloat = 48
  static let chartHeight: CGFloat = 150
}

/// Design12/14: read and edit the same bill in place. Draft changes never call the server.
@MainActor
final class QFPurchaseReceiptViewController: QFProfileContentController {
  private var receipt: QFPurchaseReceipt?
  private var draft: QFPurchaseReceiptDraft
  private let draftKey: String
  private let hasInitialImport: Bool
  private var editingBill: Bool
  private var units: [QFMeasurementUnit] = []
  private var saved = false
  private var submitting = false
  private var conflicted = false
  private var sourceUnavailable = false
  private let form = QFTabUI.stack([], spacing: 14)
  private let totalLabel = QFTabUI.label("", size: 22, weight: .bold, lines: 0)
  private var action: UIButton!
  private var headerAction: UIButton!
  private var scannedFeedback: String?
  private struct BarcodeRow {
    weak var name: UITextField?
    weak var status: UILabel?
    weak var package: UILabel?
    weak var referencePrice: UILabel?
    weak var contents: UILabel?
    weak var source: UIButton?
    weak var retry: UIButton?
  }
  private var barcodeRows: [String: BarcodeRow] = [:]
  private var unitButtons: [(UIButton, String)] = []
  private var productLookup: Task<Void, Never>?
  private var lookupOperation: UUID?
  private var lookupLineID: String?
  private var locale: Locale { Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier) }
  override var reloadsOnAppearance: Bool { false }
  override var hasUnsavedChanges: Bool { editingBill && !saved && (!draft.items.isEmpty || draft.pending != nil) }

  init(app: QFAppSession, receipt: QFPurchaseReceipt? = nil, date: String = QFContentDate.day(Date()), householdID: String? = nil, shoppingList: QFShoppingList? = nil, imported: QFReceiptImport? = nil) {
    self.receipt = receipt; editingBill = receipt == nil
    hasInitialImport = imported != nil
    draftKey = "receipt." + (receipt?.id ?? shoppingList.map { "shopping." + $0.id } ?? (householdID ?? "personal") + ".new")
    if let imported {
      var value = QFPurchaseReceiptDraft(date: imported.date ?? date, householdId: householdID)
      value.currency = imported.currency; value.items = imported.lines
      value.scanSellerID = imported.sellerID; value.scanTotal = imported.invoiceTotal
      draft = value
    } else {
      draft = QFContentDraftStore.load(QFPurchaseReceiptDraft.self, app: app, kind: draftKey)
        ?? receipt.map(QFPurchaseReceiptDraft.init) ?? shoppingList.map { QFPurchaseReceiptDraft(shoppingList: $0, date: date) } ?? QFPurchaseReceiptDraft(date: date, householdId: householdID)
    }
    if draft.pending != nil { editingBill = true }
    super.init(app: app, title: app.text("采购账单", "Purchase receipt"))
  }
  required init?(coder: NSCoder) { nil }
  deinit { productLookup?.cancel() }
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    lookupOperation = nil; productLookup?.cancel(); productLookup = nil; lookupLineID = nil
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    for line in draft.items { updateBarcodeRow(line) }
    if let feedback = scannedFeedback { scannedFeedback = nil; message(feedback) }
  }
  func appendScannedProduct(_ line: QFPurchaseReceiptLine) {
    guard receipt == nil, !submitting else { return }
    switch draft.addScannedProduct(line) {
    case .added: _ = persist()
    case .duplicate: scannedFeedback = app.text("这个条码已在草稿中，请直接修改原商品的数量。", "This barcode is already in the draft. Edit the existing item's quantity.")
    case .locked: scannedFeedback = app.text("请先处理上次保存结果，再添加商品。", "Resolve the previous save before adding items.")
    case .full: scannedFeedback = app.text("每张采购账单最多添加40项。", "A purchase receipt can contain up to 40 items.")
    }
    if isViewLoaded { render() }
  }
  override func viewDidLoad() {
    super.viewDidLoad(); view.accessibilityIdentifier = "purchase.receipt"
    if hasInitialImport { _ = persist() }
    bodyStack.addArrangedSubview(form)
    headerAction = QFTabUI.button("", size: 14, color: QFUI.orange) { [weak self] in self?.toggleEditing() }
    headerAction.accessibilityIdentifier = "purchase.receipt.edit"; installHeaderAction(headerAction)
    action = addFooter("") { [weak self] in self?.primaryAction() }
    action.accessibilityIdentifier = "purchase.receipt.save"
    setReloadAction(allowsPullToRefresh: false) { [weak self] in self?.loadMetadata() }
    render(); loadMetadata()
  }
  private func loadMetadata() {
    execute(reloadOnFailure: true, showsInitialReadProgress: false) { [self] in
      units = try await app.measurementUnits()
      if !editingBill { render() }
      else {
        for (button, code) in unitButtons { button.setTitle(unitName(code) + "  ⌄", for: .normal) }
        for line in draft.items { updateBarcodeRow(line) }
      }
    }
  }
  @discardableResult private func persist() -> Bool {
    guard QFContentDraftStore.save(draft, app: app, kind: draftKey) else {
      message(app.text("草稿保存失败，请重试。", "Could not save the draft. Please retry."), error: true); return false
    }
    return true
  }
  private func toggleEditing() {
    view.endEditing(true)
    guard !submitting else { return }
    if editingBill {
      // Unknown commits remain frozen and recoverable; cancelling never submits a new request.
      if draft.pending != nil { close(); return }
      if let receipt { draft = .init(receipt); editingBill = false; QFContentDraftStore.remove(app: app, kind: draftKey); render() }
      else { _ = persist(); close() }
    } else { editingBill = true; saved = false; render() }
  }
  private func render() {
    QFTabUI.clear(form)
    headerAction.setTitle(editingBill ? app.text("取消", "Cancel") : app.text("编辑", "Edit"), for: .normal)
    if editingBill { renderEditor() } else if let receipt { renderReceipt(receipt) }
    updateTotal(); updateAction()
  }
  private func renderReceipt(_ receipt: QFPurchaseReceipt) {
    form.addArrangedSubview(QFTabUI.card(QFTabUI.stack([
      QFTabUI.label(receipt.merchant.isEmpty ? app.text("采购账单", "Purchase receipt") : receipt.merchant, size: 22, weight: .semibold, lines: 0),
      QFTabUI.label(receipt.date + " · " + app.text("已入库", "In stock"), size: 13, color: QFUI.secondary),
      QFTabUI.label(app.text("实际支付", "Amount paid"), size: 13, color: QFUI.secondary), totalLabel,
    ], spacing: 10), padding: 18, border: true))
    form.addArrangedSubview(QFTabUI.label(app.text("购买食材", "Purchased ingredients"), size: 18, weight: .semibold))
    for item in receipt.items {
      let amount = item.netAmount.map { money($0) } ?? app.text("价格待补全", "Price needed")
      let row = QFTabUI.stack([
        QFTabUI.stack([QFTabUI.label(item.name, size: 17, weight: .semibold, lines: 0),
          QFTabUI.label(item.quantity + " " + unitName(item.unitCode), size: 13, color: QFUI.secondary)], spacing: 6),
        UIView(), QFTabUI.label(amount, size: 17, weight: .semibold, lines: 0),
      ], axis: .horizontal, spacing: 12)
      form.addArrangedSubview(QFTabUI.card(row, padding: 16, border: true))
    }
    let sums = QFTabUI.stack([
      summaryRow(app.text("商品金额", "Items subtotal"), money(receipt.knownSubtotal)),
      summaryRow(app.text("优惠", "Discount"), "−" + money(receipt.discount)),
      summaryRow(app.text("退款", "Refund"), money(receipt.refundTotal ?? "0")),
      summaryRow(app.text("实际支付", "Amount paid"), (receipt.netPaidAmount ?? receipt.paidAmount).map(money) ?? app.text("价格待补全", "Price needed")),
    ], spacing: 14)
    form.addArrangedSubview(QFTabUI.card(sums, padding: 18, background: QFUI.paleGreen))
    let refund = QFTabUI.button(app.text("退款或退货", "Refund or return"), size: 14, color: QFUI.orange) { [weak self] in
      guard let self else { return }
      let editor = QFPurchaseAdjustmentViewController(app: self.app, receipt: receipt) { [weak self] updated in
        guard let self else { return }; self.receipt = updated; self.draft = .init(updated); self.render(); self.onChanged?()
      }
      self.open(editor)
    }
    form.addArrangedSubview(refund)
    for adjustment in receipt.adjustments ?? [] {
      form.addArrangedSubview(summaryRow(adjustment.date + " · " + (adjustment.type == "RETURN" ? app.text("退货", "Return") : app.text("退款", "Refund")), "−" + money(adjustment.totalAmount)))
    }
  }
  private func summaryRow(_ title: String, _ value: String) -> UIView {
    QFTabUI.stack([QFTabUI.label(title, size: 14, color: QFUI.secondary, lines: 0), UIView(), QFTabUI.label(value, size: 16, weight: .semibold, lines: 0)], axis: .horizontal, spacing: 10)
  }
  private func renderEditor() {
    barcodeRows.removeAll(); unitButtons.removeAll()
    let locked = draft.pending != nil || conflicted
    if draft.items.contains(where: { $0.ingredientId == nil }) {
      form.addArrangedSubview(QFTabUI.label(app.text("请核对商家、币种及每项商品的名称、数量、单位和价格，再选择对应食材；保存前不会入库。", "Review the merchant, currency, and each item's name, quantity, unit and price, then match its ingredient. Nothing is stocked until you save."), size: 13, color: QFUI.secondary, lines: 0))
    }
    if let sellerID = draft.scanSellerID {
      form.addArrangedSubview(QFTabUI.label(app.format("卖方编号 %@，请核对商家名称。", "Seller ID %@; check the merchant name.", sellerID), size: 13, color: QFUI.secondary, lines: 0))
    }
    if let total = draft.scanTotal {
      form.addArrangedSubview(QFTabUI.label(app.format("票面总额 %@，请核对商品与优惠。", "Invoice total %@; check items and discounts.", money(total)), size: 13, color: QFUI.secondary, lines: 0))
    }
    let merchant = field(app.text("商家", "Merchant"), value: draft.merchant, keyboard: .default) { [weak self] in self?.draft.merchant = $0; self?.persist() }
    merchant.accessibilityIdentifier = "purchase.merchant"
    let picker = UIDatePicker(); picker.datePickerMode = .date; picker.preferredDatePickerStyle = .compact
    picker.locale = locale; picker.calendar = QFManualPlanDraft.calendar; picker.timeZone = QFManualPlanDraft.calendar.timeZone
    picker.date = QFManualPlanDraft.date(draft.date) ?? Date(); picker.maximumDate = QFManualPlanDraft.date(QFContentDate.day(Date()))
    picker.accessibilityIdentifier = "purchase.date"
    picker.addAction(UIAction { [weak self, weak picker] _ in guard let self, let picker else { return }; self.draft.date = QFManualPlanDraft.string(picker.date); self.persist() }, for: .valueChanged)
    let metadata = QFTabUI.stack([labeled(app.text("商家", "Merchant"), merchant), labeled(app.text("购买日期", "Purchase date"), QFTabUI.card(picker, padding: 8, border: true))], axis: .horizontal, spacing: 10)
    metadata.distribution = .fillEqually; form.addArrangedSubview(metadata)
    let currency = field(app.text("币种", "Currency"), value: draft.currency, keyboard: .asciiCapable) { [weak self] in self?.draft.currency = $0.uppercased(); self?.persist(); self?.updateTotal() }
    currency.accessibilityIdentifier = "purchase.currency"; form.addArrangedSubview(labeled(app.text("币种", "Currency"), currency))
    for line in draft.items { form.addArrangedSubview(editableLine(line)) }
    let add = QFTabUI.button(app.text("添加食材", "Add ingredient") + "  ＋", size: 15, color: QFUI.orange) { [weak self] in self?.selectIngredient() }
    add.contentHorizontalAlignment = .leading; add.accessibilityIdentifier = "purchase.add"; add.isEnabled = draft.items.count < 40
    form.addArrangedSubview(add)
    if receipt == nil {
      let scan = QFTabUI.button(app.text("扫描商品条码", "Scan product barcode"), size: 15, color: QFUI.orange) { [weak self] in
        guard let self, self.draft.pending == nil, !self.submitting, self.draft.items.count < 40 else { return }
        self.view.endEditing(true)
        let scanner = QFProductBarcodeScannerViewController(app: self.app, householdID: self.draft.householdId)
        scanner.onScannedProduct = { [weak self] line in self?.appendScannedProduct(line) }
        self.open(scanner)
      }
      scan.accessibilityIdentifier = "purchase.scan-product"; scan.contentHorizontalAlignment = .leading
      scan.isEnabled = draft.items.count < 40; form.addArrangedSubview(scan)
    }
    let discount = field(app.text("优惠", "Discount"), value: draft.discount) { [weak self] in
      guard let self else { return }; self.draft.discount = QFPurchaseNumber.normalize($0, locale: self.locale); self.persist(); self.updateTotal()
    }
    discount.accessibilityIdentifier = "purchase.discount"
    let payment = QFTabUI.stack([labeled(app.text("优惠", "Discount"), discount), labeled(app.text("实际支付", "Amount paid"), totalLabel)], axis: .horizontal, spacing: 18)
    payment.distribution = .fillEqually; form.addArrangedSubview(payment)
    form.isUserInteractionEnabled = !locked && !submitting
    if locked { form.alpha = 0.65 } else { form.alpha = 1 }
  }
  private func editableLine(_ line: QFPurchaseReceiptLine) -> UIView {
    let productName = field(app.text("请输入商品名称", "Enter product name"), value: line.name, keyboard: .default, limit: 100) { [weak self] value in
      self?.edit(line.id) { $0.name = value }
    }
    productName.accessibilityIdentifier = "purchase.name." + line.id
    productName.accessibilityLabel = app.text("商品名称", "Product name")
    let identityTitle = line.ingredientId == nil ? app.text("选择对应食材", "Match an ingredient")
      : line.matchedIngredientName ?? app.text("已关联食材", "Ingredient matched")
    let identity = QFTabUI.button(identityTitle + "  ›", size: 15, color: line.ingredientId == nil ? QFUI.orange : QFUI.text) { [weak self] in self?.selectIngredient(replacing: line.id) }
    identity.accessibilityIdentifier = "purchase.ingredient." + line.id
    identity.contentHorizontalAlignment = .leading; identity.titleLabel?.numberOfLines = 0
    let delete = QFTabUI.iconButton("trash", label: app.text("删除", "Delete"), size: 20) { [weak self] in
      self?.draft.items.removeAll { $0.id == line.id }
      self?.draft.shoppingSource?.items.removeAll { $0.itemId == line.id }
      self?.persist(); self?.render()
    }
    delete.isHidden = receipt?.shoppingItemIds?.contains(line.id) == true
    identity.isEnabled = receipt == nil && (draft.shoppingSource == nil || line.ingredientId == nil)
    let heading = QFTabUI.stack([labeled(app.text("商品名称", "Product name"), productName), delete], axis: .horizontal, spacing: 8)
    let quantity = field(app.text("数量", "Quantity"), value: line.quantity) { [weak self] value in self?.edit(line.id) { $0.quantity = self.map { QFPurchaseNumber.normalize(value, locale: $0.locale) } ?? value } }
    quantity.accessibilityIdentifier = "purchase.quantity." + line.id
    let unit = QFTabUI.button(unitName(line.unitCode) + "  ⌄", size: 16, color: QFUI.text, background: QFUI.surface) { [weak self] in self?.chooseUnit(line.id) }
    unitButtons.append((unit, line.unitCode))
    unit.layer.borderColor = QFUI.border.cgColor; unit.layer.borderWidth = 1; unit.layer.cornerRadius = 12
    let amount = field(app.text("价格待补全", "Price needed"), value: line.lineAmount ?? "") { [weak self] value in
      self?.edit(line.id) { $0.lineAmount = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self.map { QFPurchaseNumber.normalize(value, locale: $0.locale) } ?? value }
      self?.updateTotal()
    }
    amount.accessibilityIdentifier = "purchase.amount." + line.id
    let values = QFTabUI.stack([labeled(app.text("购买数量", "Quantity bought"), quantity), labeled(app.text("单位", "Unit"), unit), labeled(app.text("行金额", "Line amount"), amount)], axis: .horizontal, spacing: 10)
    values.distribution = .fillEqually
    let location = field(app.text("存放位置", "Storage location"), value: line.location, keyboard: .default) { [weak self] value in self?.edit(line.id) { $0.location = value } }
    let details = QFTabUI.button(app.text("规格与有效期", "Specification and expiry") + "  ›", size: 13, color: QFUI.orange) { [weak self] in
      guard let self, let current = self.draft.items.first(where: { $0.id == line.id }) else { return }
      self.open(QFStockSpecificationViewController(app: self.app, unitCode: current.unitCode,
        value: .init(packageSize: current.packageSize, packageContentUnit: current.packageContentUnit, expiresOn: current.expiresOn), units: self.units) { [weak self] value in
        self?.edit(line.id) { $0.packageSize = value.packageSize; $0.packageContentUnit = value.packageContentUnit; $0.expiresOn = value.expiresOn; $0.packageUnit = QFStockSpecification.isPackage($0.unitCode) ? $0.unitCode : nil }; self?.render()
      })
    }
    details.contentHorizontalAlignment = .leading
    var rows: [UIView] = [heading, labeled(app.text("对应食材", "Matched ingredient"), identity)]
    if let barcode = line.scanBarcode {
      rows.append(QFTabUI.label(app.format("商品条码：%@", "Product barcode: %@", barcode), size: 12, color: QFUI.secondary, lines: 0))
      let status = QFTabUI.label("", size: 13, color: QFUI.secondary, lines: 0)
      status.accessibilityIdentifier = "purchase.barcode-status." + line.id
      let package = QFTabUI.label("", size: 13, color: QFUI.secondary, lines: 0)
      let referencePrice = QFTabUI.label("", size: 12, color: QFUI.secondary, lines: 0)
      referencePrice.accessibilityIdentifier = "purchase.reference-price." + line.id
      let contents = QFTabUI.label("", size: 16, weight: .semibold, lines: 0)
      contents.accessibilityIdentifier = "purchase.net-content." + line.id
      let source = QFTabUI.button("", size: 12, color: QFUI.secondary) { [weak self] in
        guard let self, let current = self.draft.items.first(where: { $0.id == line.id }) else { return }
        let url = current.scanProductSource == "JISU_ALIYUN" ? "https://www.jisuapi.com/api/barcode2/" : "https://world.openfoodfacts.org/data"
        self.present(SFSafariViewController(url: URL(string: url)!), animated: true)
      }
      source.contentHorizontalAlignment = .leading; source.titleLabel?.numberOfLines = 0
      let retry = QFTabUI.button(app.text("联网查询商品资料", "Look up product online"), size: 14, color: QFUI.orange) { [weak self] in self?.retryProduct(line.id) }
      retry.contentHorizontalAlignment = .leading; retry.titleLabel?.numberOfLines = 0
      retry.accessibilityIdentifier = "purchase.barcode-retry." + line.id
      barcodeRows[line.id] = .init(name: productName, status: status, package: package, referencePrice: referencePrice, contents: contents, source: source, retry: retry)
      updateBarcodeRow(line)
      rows.append(contentsOf: [status, package, referencePrice, source, retry])
      rows.append(QFTabUI.label(app.text("数量1是可修改的默认值，价格需手动填写；包装净含量不代表购买数量。", "1 is an editable starting count. Enter the price yourself; package contents are not the quantity bought."), size: 12, color: QFUI.secondary, lines: 0))
      rows.append(values)
      rows.append(labeled(app.text("每包装净含量", "Net content per package"), contents))
    } else {
      rows.append(values)
    }
    rows.append(contentsOf: [location, details])
    let body = QFTabUI.stack(rows, spacing: 14)
    return QFTabUI.card(body, padding: 15, border: true)
  }
  private func edit(_ id: String, mutation: (inout QFPurchaseReceiptLine) -> Void) {
    guard draft.pending == nil, let index = draft.items.firstIndex(where: { $0.id == id }) else { return }
    mutation(&draft.items[index]); persist(); updateAction()
  }
  private func field(_ placeholder: String, value: String, keyboard: UIKeyboardType = .decimalPad, limit: Int? = nil, change: @escaping (String) -> Void) -> UITextField {
    let field = QFContentUI.field(placeholder, text: value, keyboard: keyboard, limit: limit ?? (keyboard == .default ? 120 : 24), changed: change)
    field.layer.borderWidth = 1; field.layer.borderColor = QFUI.border.cgColor
    field.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
    return field
  }
  private func labeled(_ title: String, _ view: UIView) -> UIView {
    QFTabUI.stack([QFTabUI.label(title, size: 12, color: QFUI.secondary, lines: 0), view], spacing: 8)
  }
  private func unitName(_ code: String) -> String {
    units.first { $0.code == code }?.name ?? {
      switch code {
      case "pack": return app.text("包", "Pack")
      case "bottle": return app.text("瓶", "Bottle")
      case "bag": return app.text("袋", "Bag")
      case "box": return app.text("盒", "Box")
      default: return code
      }
    }()
  }
  private func updateBarcodeRow(_ line: QFPurchaseReceiptLine) {
    guard let row = barcodeRows[line.id] else { return }
    if row.name?.isFirstResponder == false, row.name?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { row.name?.text = line.name }
    let state = line.scanLookupState.flatMap(QFBarcodeLookupState.init(rawValue:)) ?? .skipped
    switch state {
    case .found:
      row.status?.text = line.name.isEmpty
        ? app.text("未获取到可靠名称，请手动填写并选择对应食材。", "No reliable name was retrieved. Enter it and match the ingredient yourself.")
        : app.text("已联网获取商品资料，请与包装核对。", "Product data retrieved online. Check it against the package.")
    case .notFound: row.status?.text = app.text("当前商品库未收录此条码，请填写商品名称和净含量。", "This barcode is not in the current product database. Enter its name and net contents.")
    case .unavailable: row.status?.text = app.text("商品查询失败，请检查网络后重试。", "Product lookup failed. Check your connection and retry.")
    case .rateLimited: row.status?.text = app.text("商品查询暂时受限，请稍后重试。", "Product lookup is temporarily rate limited. Please try again later.")
    case .localOnly: row.status?.text = app.text("门店内部条码需由门店提供商品资料，请手动填写。", "Store-specific barcodes need the store's product data. Enter the item manually.")
    case .skipped: row.status?.text = app.text("尚未查询商品资料，可点击联网查询。", "Product data has not been checked. Tap to look it up online.")
    }
    row.package?.text = line.scanPackageLabel.map { app.format("包装标注：%@", "Package label: %@", $0) }
    row.package?.isHidden = line.scanPackageLabel == nil
    row.contents?.text = line.packageSize.flatMap { size in line.packageContentUnit.map { size + " " + unitName($0) } }
      ?? app.text("待补全", "To complete")
    row.referencePrice?.text = line.scanReferencePrice.map { app.format("资料源标价：%@（计价单位未注明，请核对）", "Source price: %@ (pricing unit unspecified; please check)", $0) }
    row.referencePrice?.isHidden = line.scanReferencePrice == nil
    row.source?.setTitle(line.scanProductSource == "JISU_ALIYUN"
      ? app.text("商品资料来源：极速数据（阿里云市场）", "Product data: Jisu Data (Alibaba Cloud Marketplace)")
      : app.text("商品资料来源：Open Food Facts（ODbL）", "Product data: Open Food Facts (ODbL)"), for: .normal)
    row.source?.isHidden = !["OPEN_FOOD_FACTS", "JISU_ALIYUN"].contains(line.scanProductSource ?? "")
    row.retry?.isHidden = state == .localOnly
    row.retry?.isEnabled = productLookup == nil && draft.pending == nil && !submitting
      && (line.scanBarcodeSymbology != nil || line.scanBarcode?.count == 13)
    row.retry?.setTitle(lookupLineID == line.id ? app.text("查询中…", "Looking up…") : app.text("联网查询商品资料", "Look up product online"), for: .normal)
  }
  private func retryProduct(_ id: String) {
    guard productLookup == nil, receipt == nil, draft.pending == nil, !submitting,
      let line = draft.items.first(where: { $0.id == id }), let code = line.scanBarcode,
      let kind = line.scanBarcodeSymbology ?? (code.count == 13 ? "EAN13" : nil),
      let barcode = QFProductBarcode(value: code, symbology: kind), barcode.lookupCode != nil else { return }
    view.endEditing(true)
    let binding = QFAssistantAgent.scope(app), household = draft.householdId, operation = UUID()
    lookupOperation = operation; lookupLineID = id
    productLookup = Task { [weak self] in
      guard let self else { return }
      var info: QFBarcodeProductInfo?, state: QFBarcodeLookupState = .notFound
      do {
        info = try await QFBarcodeProductLookup.shared.product(for: barcode, language: binding.language, refresh: true, app: self.app)
        if info != nil { state = .found }
      } catch {
        if Task.isCancelled { return }
        state = (error as? QFBarcodeProductLookup.Failure) == .rateLimited ? .rateLimited : .unavailable
      }
      guard !Task.isCancelled, self.lookupOperation == operation else { return }
      self.productLookup = nil; self.lookupLineID = nil; self.lookupOperation = nil
      guard self.receipt == nil, self.editingBill,
        QFAssistantAgent.scope(self.app) == binding, self.draft.householdId == household,
        self.draft.pending == nil, !self.submitting, let index = self.draft.items.firstIndex(where: { $0.id == id }) else { return }
      self.draft.items[index].applyBarcodeInfo(info, status: state)
      self.persist()
      for item in self.draft.items { self.updateBarcodeRow(item) }
    }
    for item in draft.items { updateBarcodeRow(item) }
  }
  private func selectIngredient(replacing: String? = nil) {
    view.endEditing(true)
    open(QFCatalogSearchViewController(app: app, type: "INGREDIENT") { [weak self] item in
      guard let self else { return }
      if let replacing, let index = self.draft.items.firstIndex(where: { $0.id == replacing }) {
        self.draft.items[index].ingredientId = item.id; self.draft.items[index].matchedIngredientName = item.title
        if self.draft.items[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.draft.items[index].name = item.title }
      } else if self.draft.items.count < 40 {
        var line = QFPurchaseReceiptLine(ingredientId: item.id, name: item.title); line.matchedIngredientName = item.title; self.draft.items.append(line)
      }
      self.persist(); self.render()
    })
  }
  private func chooseUnit(_ id: String) {
    view.endEditing(true)
    guard !units.isEmpty else { loadMetadata(); return }
    let sheet = UIAlertController(title: app.text("选择单位", "Choose unit"), message: nil, preferredStyle: .actionSheet)
    for unit in units {
      sheet.addAction(UIAlertAction(title: unit.name + " · " + unit.symbol, style: .default) { [weak self] _ in self?.edit(id) { $0.unitCode = unit.code; $0.packageUnit = QFStockSpecification.isPackage(unit.code) ? unit.code : nil; $0.packageSize = nil; $0.packageContentUnit = nil }; self?.render() })
    }
    sheet.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    sheet.popoverPresentationController?.sourceView = form; sheet.popoverPresentationController?.sourceRect = form.bounds
    present(sheet, animated: true)
  }
  private func money(_ amount: String) -> String { QFPurchaseNumber.money(amount, currency: draft.currency, locale: locale) }
  private func updateTotal() {
    if !editingBill, let receipt { totalLabel.text = (receipt.netPaidAmount ?? receipt.paidAmount).map(money) ?? app.text("价格待补全", "Price needed"); updateAction(); return }
    totalLabel.text = draft.paidAmount.map { money(QFPurchaseNumber.string($0)) } ?? app.format("已知 %@ · %d 项待补全", "Known %@ · %d pending", money(QFPurchaseNumber.string(draft.knownSubtotal)), draft.pendingCount)
    updateAction()
  }
  private func updateAction() {
    guard action != nil else { return }
    let title = sourceUnavailable ? app.text("返回", "Back") : conflicted ? app.text("重新加载", "Reload") : draft.pending != nil ? app.text("重试", "Retry") : editingBill ? app.text("保存修改", "Save changes") : app.text("查看入库明细", "View stock entries")
    action.setTitle(title, for: .normal); action.isEnabled = !submitting
  }
  private func primaryAction() {
    if sourceUnavailable { QFContentDraftStore.remove(app: app, kind: draftKey); onChanged?(); close(); return }
    if conflicted { reloadConflict(); return }
    if !editingBill {
      let controller = QFReceiptInventoryViewController(app: app, receiptID: draft.id); controller.onChanged = { [weak self] in self?.reloadConflict(); self?.onChanged?() }; open(controller); return
    }
    view.endEditing(true)
    if draft.pending == nil {
      guard draft.items.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.ingredientId != nil }) else {
        message(app.text("请填写商品名称，并为每一项选择对应食材。", "Enter each product name and match every item to an ingredient."), error: true); return
      }
      do { draft.pending = .init(body: try draft.request(), language: app.interfaceLanguage) }
      catch { message(app.text("请检查日期、币种、数量和金额。未知价格不能分摊优惠。", "Check the date, currency, quantities and amounts. Discounts require all prices."), error: true); return }
      guard persist() else { draft.pending = nil; return }
    }
    guard let pending = draft.pending else { return }
    submitting = true; render()
    execute(label: app.text("正在保存", "Saving")) { [self] in
      defer { submitting = false; render() }
      do {
        let response = try await app.savePurchaseReceipt(id: draft.id, pending: pending)
        receipt = response; draft = .init(response); saved = true; editingBill = false
        QFContentDraftStore.remove(app: app, kind: draftKey); onChanged?()
        message(app.text("账单与库存已保存", "Receipt and inventory saved"))
      } catch let error as QFAPIError {
        // A definitive domain rejection releases this attempt; transport/auth failures remain frozen.
        if error.code == 40900 { conflicted = true }
        if error.code == 40000 || (42200...42299).contains(error.code) { draft.pending = nil; persist() }
        throw error
      }
    }
  }
  private func reloadConflict() {
    execute(label: app.text("正在加载", "Loading")) { [self] in
      if let source = draft.shoppingSource, draft.revision == nil {
        // A 409 is a known rejection, unlike a timeout: refresh source versions
        // before making a new request; never receive an already fulfilled row.
        let list = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.shoppingList(source.listId) }
        let rows = source.items.compactMap { ref in list.items.first { $0.id == ref.itemId } }
        guard rows.count == source.items.count, rows.allSatisfy({ $0.checked && $0.received != true }), list.status == "DRAFT" || list.status == "CONFIRMED" else {
          sourceUnavailable = true; form.isUserInteractionEnabled = false; action.setTitle(app.text("返回", "Back"), for: .normal)
          message(app.text("采购清单已变化，请返回后重新选择。", "The shopping list changed. Go back and select again."), error: true); return
        }
        draft.shoppingSource = .init(listId: list.id, expectedRevision: list.revision, items: rows.map { .init(itemId: $0.id, expectedRevision: $0.revision) })
        draft.pending = nil; conflicted = false; _ = persist(); render(); return
      }
      let response: QFPurchaseReceipt = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.contentRequest(path: "me/purchase-receipts/\(draft.id)") }
      receipt = response; draft = .init(response); conflicted = false; editingBill = false
      QFContentDraftStore.remove(app: app, kind: draftKey); render()
    }
  }
}
