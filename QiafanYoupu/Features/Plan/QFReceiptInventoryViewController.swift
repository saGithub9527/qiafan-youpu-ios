import UIKit

@MainActor
final class QFReceiptInventoryViewController: QFProfileContentController {
  private let receiptID: String
  private var items: [QFInventoryLot] = []
  private var loaded = false
  override var reloadsOnAppearance: Bool { false }
  init(app: QFAppSession, receiptID: String) { self.receiptID = receiptID; super.init(app: app, title: app.text("查看入库明细", "View stock entries")) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); setReloadAction { [weak self] in self?.load(force: true) }; render(); load()
  }
  private func load(force: Bool = false) {
    execute(reloadOnFailure: true, showsInitialReadProgress: false) { [self] in
      items = try await QFContentLoadingContext.$forceRefresh.withValue(force) { try await app.contentRequest(path: "me/purchase-receipts/\(receiptID)/inventory") }
      loaded = true; render()
    }
  }
  private func render() {
    bodyStack.beginUpdates()
    if items.isEmpty {
      bodyStack.row("state", version: String(loaded)) { [self] in QFTabUI.empty(loaded ? app.text("没有关联的库存批次", "No linked stock lots") : app.text("正在加载", "Loading"), detail: "") }
    }
    for item in items {
      bodyStack.row(item.id, value: item) { [weak self] in
        guard let self else { return UIView() }
        let status = item.status == "ARCHIVED" ? self.app.text("已归档", "Archived") : self.app.text("当前库存", "Current stock")
        let name = item.ingredientName ?? self.app.text("食材", "Ingredients")
        let details = [status + " · " + item.currentQuantity + " " + item.unitCode, item.location, item.acquiredOn ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let button = QFTabUI.button(self.app.text("补全食材成本", "Complete ingredient costs") + "  ›", size: 14, color: QFUI.orange) { [weak self] in
          guard let self else { return }; let editor = QFInventoryCostSourcesViewController(app: self.app, lot: item)
          editor.onChanged = { [weak self] in self?.onChanged?(); self?.load(force: true) }; self.open(editor)
        }
        return QFTabUI.card(QFTabUI.stack([QFTabUI.label(name, size: 18, weight: .semibold, lines: 0), QFTabUI.label(details, size: 13, color: QFUI.secondary, lines: 0), button], spacing: 12), padding: 16, border: true)
      }
    }
    bodyStack.endUpdates()
  }
}

/// A grouped fridge card is a read projection. Editing always selects a real lot.
@MainActor
final class QFInventoryBatchesViewController: QFProfileContentController {
  private let ingredient: QFInventoryLot
  private let binding: QFAgentScope
  private let selected: (QFInventoryLot) -> Void
  private var items: [QFInventoryLot] = []
  private var total = 0, nextPage = 0
  private var loaded = false, reachedEnd = false
  override var reloadsOnAppearance: Bool { false }
  init(app: QFAppSession, ingredient: QFInventoryLot, selected: @escaping (QFInventoryLot) -> Void) {
    self.ingredient = ingredient; self.selected = selected; binding = QFAssistantAgent.scope(app)
    super.init(app: app, title: app.text("入库批次", "Stock batches"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); view.accessibilityIdentifier = "inventory.batches"
    setReloadAction { [weak self] in self?.load(force: true) }; render(); load()
  }
  private func load(append: Bool = false, force: Bool = false) {
    let page = append ? nextPage : 0
    execute(reloadOnFailure: true, loadingMore: append, showsInitialReadProgress: false) { [self] in
      let response = try await QFContentLoadingContext.$forceRefresh.withValue(force) {
        try await app.inventoryLots(householdID: ingredient.householdId, page: page, ingredientID: ingredient.ingredientId)
      }
      try Task.checkCancellation()
      guard QFAssistantAgent.scope(app) == binding else { throw CancellationError() }
      // A legacy server ignoring ingredientId must never expose an unrelated
      // item as a batch of this product.
      guard response.items.allSatisfy({ $0.ingredientId == ingredient.ingredientId && $0.householdId == ingredient.householdId }) else {
        throw QFAPIError(code: 50300, message: app.text("暂时无法读取入库批次", "Stock batches are temporarily unavailable"))
      }
      if append {
        let known = Set(items.map(\.id)), additions = response.items.filter { !known.contains($0.id) }
        items.append(contentsOf: additions); reachedEnd = additions.isEmpty
      } else { items = response.items; reachedEnd = response.items.isEmpty }
      total = response.total; nextPage = page + 1; loaded = true; render()
    }
  }
  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row("name", version: ingredient.ingredientName ?? "") { [self] in
      QFTabUI.label(ingredient.ingredientName ?? app.text("食材", "Ingredients"), size: 20, weight: .semibold, lines: 0)
    }
    if items.isEmpty {
      bodyStack.row("empty", version: String(loaded)) { [self] in
        QFTabUI.empty(loaded ? app.text("没有关联的库存批次", "No linked stock lots") : app.text("正在加载", "Loading"), detail: "")
      }
    }
    for item in items {
      bodyStack.row(item.id, value: item) { [weak self] in
        guard let self else { return UIView() }
        let edit = QFTabUI.button(self.app.text("调整此批次数量", "Edit this batch") + "  ›", size: 14, color: QFUI.orange) { [weak self] in
          guard let self, QFAssistantAgent.scope(self.app) == self.binding else { return }
          self.qfClose { [weak self] in self?.selected(item) }
        }
        let date = item.acquiredOn ?? item.createdAt.map { String($0.prefix(10)) } ?? ""
        let unit = item.displayedUnitCode == "bottle" ? self.app.text("瓶", "Bottle") : item.displayedUnitCode
        let quantity = QFTabUI.label(item.displayedQuantity + " " + unit, size: 18, weight: .semibold)
        let details = [date, item.expiresOn.map { self.app.text("有效期", "Expiry date") + ": " + $0 } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return QFTabUI.card(QFTabUI.stack([quantity, QFTabUI.label(details, size: 13, color: QFUI.secondary, lines: 0), edit], spacing: 12), padding: 16, border: true)
      }
    }
    bodyStack.endUpdates()
    setLoadMoreAction(!reachedEnd && items.count < total ? { [weak self] in self?.load(append: true) } : nil)
  }
}
