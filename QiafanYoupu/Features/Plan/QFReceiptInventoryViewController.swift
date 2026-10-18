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
