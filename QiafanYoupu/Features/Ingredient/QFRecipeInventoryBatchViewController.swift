import SnapKit
import UIKit

private struct QFRecipeInventoryLine: Codable {
  let id: String
  let idempotencyKey: String
  let name: String
  var ingredientID: String?
  var quantity: String
  var unitCode: String
  var selected: Bool
  var sourceUnit: String?

  init(material: QFWorkMaterial) {
    id = UUID().uuidString.lowercased()
    idempotencyKey = UUID().uuidString.lowercased()
    name = material.name
    ingredientID = material.ingredientId
    quantity = material.hasNumericAmount ? material.amount : ""
    unitCode = ""
    selected = true
    sourceUnit = material.unit
  }

  init(assistant: QFAssistantIngredient) {
    id = UUID().uuidString.lowercased()
    idempotencyKey = UUID().uuidString.lowercased()
    name = assistant.name
    ingredientID = nil
    quantity = assistant.quantity
    unitCode = ""
    selected = true
    sourceUnit = assistant.unit
  }
}

private struct QFRecipeInventoryDraft: Codable {
  var lines: [QFRecipeInventoryLine] = []
  var pending: QFInventoryLotBatch?
  var language: String?
}

/// One local recipe draft; the server commits every selected lot in a single transaction.
@MainActor
final class QFRecipeInventoryBatchViewController: QFProfileContentController {
  private let recipe: QFCatalogItem?
  private let sourceTitle: String
  private let householdID: String?
  private let onSaved: ([QFInventoryLot]) -> Void
  private let draftKey: String
  private var draft: QFRecipeInventoryDraft
  private var units: [QFMeasurementUnit] = []
  private var saveButton: UIButton!
  private var submitting = false
  private var saved = false
  override var reloadsOnAppearance: Bool { false }
  override var hasUnsavedChanges: Bool { !saved && (draft.pending != nil || !draft.lines.isEmpty) }

  init(app: QFAppSession, recipe: QFCatalogItem, householdID: String?, onSaved: @escaping ([QFInventoryLot]) -> Void) {
    self.recipe = recipe; sourceTitle = recipe.title; self.householdID = householdID; self.onSaved = onSaved
    draftKey = "inventory.recipe.\(householdID ?? "personal").\(recipe.id)"
    draft = QFContentDraftStore.load(QFRecipeInventoryDraft.self, app: app, kind: draftKey) ?? .init()
    super.init(app: app, title: app.text("按菜谱添加食材", "Add ingredients from a recipe"))
  }
  init(app: QFAppSession, assistant: QFAssistantPreview, requestID: String, householdID: String?, onSaved: @escaping ([QFInventoryLot]) -> Void) {
    recipe = nil; sourceTitle = app.text("AI 建议的食材", "AI-suggested ingredients")
    self.householdID = householdID; self.onSaved = onSaved
    draftKey = "inventory.assistant.\(householdID ?? "personal").\(requestID)"
    draft = QFContentDraftStore.load(QFRecipeInventoryDraft.self, app: app, kind: draftKey)
      ?? QFRecipeInventoryDraft(lines: assistant.ingredients.prefix(30).map(QFRecipeInventoryLine.init(assistant:)), pending: nil, language: nil)
    super.init(app: app, title: app.text("核对并添加食材", "Review and add ingredients"))
  }
  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "inventory.recipe.batch"
    saveButton = addFooter(app.text("批量保存食材", "Save ingredients")) { [weak self] in self?.save() }
    saveButton.accessibilityIdentifier = "inventory.recipe.batch.save"
    render()
    execute(reloadOnFailure: true, showsInitialReadProgress: false) { [self] in
      units = try await app.inventoryMeasurementUnits(householdID: householdID)
      if let recipe, draft.lines.isEmpty && draft.pending == nil {
        let detail: QFCatalogItem = try await app.contentRequest(path: "catalog/RECIPE/\(recipe.id)")
        draft.lines = Array(detail.materials.prefix(30)).map(QFRecipeInventoryLine.init)
        if detail.materials.count > 30 {
          message(app.text("此菜谱超过30种材料，本次仅显示前30种。", "This recipe has more than 30 ingredients; only the first 30 are shown."))
        }
      }
      for index in draft.lines.indices where draft.lines[index].unitCode.isEmpty {
        let value = draft.lines[index].sourceUnit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        draft.lines[index].unitCode = units.first { $0.code == value || $0.symbol == value || $0.name == value }?.code ?? ""
      }
      _ = persist()
      render()
    }
  }

  @discardableResult private func persist() -> Bool {
    let ok = QFContentDraftStore.save(draft, app: app, kind: draftKey)
    if !ok { message(app.text("草稿保存失败，请重试。", "Could not save the draft. Please retry."), error: true) }
    return ok
  }

  private func render() {
    QFTabUI.clear(bodyStack)
    bodyStack.addArrangedSubview(QFTabUI.card(QFTabUI.label(sourceTitle, size: 20, weight: .semibold, lines: 0), padding: 16, background: QFUI.paleGreen))
    if draft.lines.isEmpty {
      bodyStack.addArrangedSubview(QFTabUI.label(app.text("此菜谱没有可添加的材料", "This recipe has no ingredients to add"), size: 15, color: QFUI.secondary, lines: 0))
    }
    for index in draft.lines.indices {
      let line = draft.lines[index]
      let toggle = UISwitch(); toggle.isOn = line.selected
      toggle.accessibilityIdentifier = "inventory.recipe.select.\(index)"
      toggle.addAction(UIAction { [weak self] _ in
        guard let self, self.draft.pending == nil else { return }
        self.draft.lines[index].selected = toggle.isOn; _ = self.persist()
      }, for: .valueChanged)
      let name = QFTabUI.label(line.name, size: 16, weight: .semibold, lines: 0)
      let title = QFTabUI.stack([name, UIView(), toggle], axis: .horizontal, spacing: 8)
      let quantity = QFContentUI.field(app.text("数量", "Quantity"), text: line.quantity, keyboard: .decimalPad, limit: 24) { [weak self] value in
        self?.draft.lines[index].quantity = QFPurchaseNumber.normalize(value, locale: .current)
        _ = self?.persist()
      }
      quantity.accessibilityIdentifier = "inventory.recipe.quantity.\(index)"
      let chosen = units.first { $0.code == line.unitCode }
      let unit = QFTabUI.button(chosen?.name ?? app.text("选择单位", "Choose unit"), color: QFUI.text, background: QFUI.surfaceAlt) { [weak self] in self?.chooseUnit(at: index) }
      unit.accessibilityIdentifier = "inventory.recipe.unit.\(index)"
      let fields = QFTabUI.stack([quantity, unit], axis: .horizontal, spacing: 10); fields.distribution = .fillEqually
      let association = QFTabUI.button(line.ingredientID == nil ? app.text("关联目录食材（可选）", "Link a catalog ingredient (optional)") : app.text("已关联目录食材 · 更改", "Linked to catalog · Change"), size: 13, color: QFUI.orange) { [weak self] in
        guard let self, self.draft.pending == nil else { return }
        self.qfPush(QFCatalogSearchViewController(app: self.app, type: "INGREDIENT") { [weak self] item in
          guard let self else { return }; self.draft.lines[index].ingredientID = item.id; _ = self.persist(); self.render()
        })
      }
      bodyStack.addArrangedSubview(QFTabUI.card(QFTabUI.stack([title, fields, association], spacing: 10), padding: 14, border: true))
    }
    bodyStack.isUserInteractionEnabled = draft.pending == nil && !submitting
    saveButton.isEnabled = !submitting && !draft.lines.isEmpty
    saveButton.setTitle(draft.pending == nil ? app.text("批量保存食材", "Save ingredients") : app.text("重试", "Retry"), for: .normal)
  }

  private func chooseUnit(at index: Int) {
    view.endEditing(true)
    guard !units.isEmpty else {
      message(app.text("单位列表尚未加载，请稍后重试。", "The unit list is still loading. Try again shortly."), error: true)
      return
    }
    qfPush(QFMeasurementUnitSearchViewController(app: app, units: units, onSelect: { [weak self] unit in
      guard let self else { return }
      self.draft.lines[index].unitCode = unit.code
      _ = self.persist()
      self.render()
    }, onCustom: { [weak self] in self?.promptCustomUnit(at: index) }))
  }

  private func promptCustomUnit(at index: Int) {
    let alert = UIAlertController(title: app.text("自定义单位", "Custom unit"), message: app.text("自定义单位只按原单位计数，不会自动换算成克或毫升。", "Custom units are counted as entered and are not converted to grams or millilitres."), preferredStyle: .alert)
    alert.addTextField { $0.placeholder = self.app.text("例如：把、条、罐", "For example: bunch, strip, can") }
    alert.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: app.text("保存单位", "Save unit"), style: .default) { [weak self, weak alert] _ in
      guard let self, let label = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty, label.count <= 16 else { return }
      self.execute(label: self.app.text("正在保存", "Saving")) { [self] in
        let unit = try await self.app.createInventoryUnit(label: label, householdID: self.householdID)
        if !self.units.contains(where: { $0.code == unit.code }) { self.units.append(unit) }
        self.draft.lines[index].unitCode = unit.code; _ = self.persist(); self.render()
      }
    })
    present(alert, animated: true)
  }

  private func save() {
    view.endEditing(true)
    guard !submitting else { return }
    if draft.pending == nil {
      let selected = draft.lines.filter(\.selected)
      guard !selected.isEmpty else { message(app.text("请至少选择一种食材", "Choose at least one ingredient"), error: true); return }
      var items: [QFInventoryLotBatchItem] = []
      for line in selected {
        guard let quantity = QFPurchaseNumber.decimal(line.quantity), quantity > 0, !line.unitCode.isEmpty else {
          message(app.text("请填写选中食材的数量和单位", "Enter a quantity and unit for each selected ingredient"), error: true); return
        }
        let id = line.ingredientID ?? line.id
        let item = QFInventoryLotDraft(ingredientId: id, quantity: line.quantity, unitCode: line.unitCode,
          expiresOn: nil, location: "", householdId: householdID, expectedRevision: nil,
          idempotencyKey: line.idempotencyKey, customIngredientName: line.ingredientID == nil ? line.name : nil)
        items.append(.init(id: line.id, draft: item))
      }
      draft.pending = .init(items: items); draft.language = app.interfaceLanguage
      guard persist() else { draft.pending = nil; return }
    }
    guard let pending = draft.pending else { return }
    submitting = true; render()
    execute(label: app.text("正在保存", "Saving")) { [self] in
      defer { submitting = false; render() }
      do {
        let result = try await QFContentLoadingContext.$language.withValue(draft.language ?? app.interfaceLanguage) { try await app.saveInventoryLots(pending) }
        saved = true; QFContentDraftStore.remove(app: app, kind: draftKey); onSaved(result)
        closeWithSuccess(app.text("库存已更新", "Inventory updated"))
      } catch {
        if let failure = error as? QFAPIError, failure.code == 40000 || failure.code == 42207 { draft.pending = nil; _ = persist() }
        throw error
      }
    }
  }
}
