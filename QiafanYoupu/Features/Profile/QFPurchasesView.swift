import UIKit

struct QFPurchaseItem: Codable, Equatable {
  var name = ""
  var amount = ""
  var unit = "克"
  var cost = ""
}
struct QFPurchaseDraft: Codable, Equatable {
  var date: String
  var currency: String
  var note = ""
  var items: [QFPurchaseItem] = []
}
struct QFPurchase: Codable {
  let id: String
  let date: String
  let currency: String
  let total: String
  let note: String
  let items: [QFPurchaseItem]
  var draft: QFPurchaseDraft {
    QFPurchaseDraft(date: date, currency: currency, note: note, items: items)
  }
}

@MainActor
final class QFPurchasesViewController: QFProfileContentController {
  private let date: String
  private let results = QFContentListTable(frame: .zero, style: .plain)
  private var pagination = QFContentPagination<QFPurchase>()
  init(app: QFAppSession, date: String) {
    self.date = date
    super.init(app: app, title: app.text("备菜花销与采购账单", "Shopping spend and receipts"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    results.spacing = 14
    installList(results, controls: QFContentUI.label(date, size: 19, bold: true))
    _ = addFooter(app.text("记录采购账单", "Record purchase")) { [weak self] in self?.edit(nil) }
    load()
  }
  private func edit(_ purchase: QFPurchase?) {
    guard purchase != nil || date <= QFContentDate.day(Date()) else {
      message(app.text("未来日期还不能记录实际采购，请先选择今天或过去的日期。", "Purchases cannot be recorded for a future date. Choose today or an earlier date."), error: true)
      return
    }
    let editor = QFPurchaseEditorViewController(app: app, date: date, purchase: purchase)
    editor.onChanged = { [weak self] in self?.reloadIfVisible() }
    open(editor)
  }
  private func load(append: Bool = false) {
    setReloadAction { [weak self] in self?.load() }
    let previous = pagination
    let reset = isRefreshingContent
    execute(reloadOnFailure: true, loadingMore: append) { [self] in
      pagination = try await previous.fetching(
        app: app, path: "me/purchases", query: ["date": date], append: append, reset: reset,
        id: { $0.id })
      render()
    }
  }
  private func render() {
    results.beginUpdatesForRows()
    var totals: [String: Decimal] = [:]
    if let fullTotals = pagination.totals {
      for item in fullTotals { totals[item.currency] = Decimal(string: item.total) ?? 0 }
    } else if !pagination.hasMore {
      for bill in pagination.items {
        totals[bill.currency, default: 0] += Decimal(string: bill.total) ?? 0
      }
    }
    for currency in totals.keys.sorted() {
      results.row("total." + currency, version: "\(totals[currency] ?? 0)") {
        QFTabUI.card(
          QFContentUI.label("\(currency) \(totals[currency] ?? 0)", size: 28, bold: true),
          background: QFUI.paleGreen)
      }
    }
    if pagination.items.isEmpty {
      results.row("static.2", version: "") { [weak self] in
        guard let self else { return UIView() }
        return QFTabUI.empty(
          self.app.text("暂无采购账单", "No purchase records"),
          detail: self.app.text(
            "记录实际支付金额；不会用菜谱估价或做菜成本代替。",
            "Record what you actually paid. Recipe estimates and cooking costs are not substituted."))
      }
    }
    for bill in pagination.items {
      results.row(bill.id, value: bill) { [weak self] in
        guard let self else { return UIView() }
        let rows = QFTabUI.stack(
          [
            QFContentUI.label(
              self.app.format(
                "%d 项采购 · %@ %@", "%d items · %@ %@",
                bill.items.count, bill.currency, bill.total), size: 19, bold: true)
          ], spacing: 10)
        for item in bill.items {
          rows.addArrangedSubview(
            QFContentUI.label(
              "\(item.name) · \(item.amount) \(item.unit) · \(item.cost)", size: 14))
        }
        if !bill.note.isEmpty {
          rows.addArrangedSubview(QFContentUI.label(bill.note, size: 13, color: QFUI.secondary))
        }
        rows.addArrangedSubview(QFContentUI.action(self.app.text("编辑账单", "Edit purchase")) { [weak self] in self?.edit(bill) })
        rows.addArrangedSubview(
          QFContentUI.action(self.app.text("删除账单", "Delete purchase"), destructive: true) { [weak self] in
            guard let self else { return }
            self.confirm(
              self.app.text("删除这张采购账单？", "Delete this purchase record?"), detail: self.app.text("只删除该笔支出记录，不更改库存或做菜记录。", "Only this expense is deleted. Inventory and cooking history are unchanged."), actionTitle: self.app.text("删除", "Delete"), destructive: true
            ) { [weak self] in
              self?.execute { [weak self] in
                guard let self else { return }
                try await self.app.contentMutation(
                  path: "me/purchases/\(bill.id)", method: "DELETE")
                DispatchQueue.main.async { self.load() }
              }
            }
          })
        return QFTabUI.card(rows)
      }
    }
    results.endUpdatesForRows()
    setLoadMoreAction(pagination.hasMore ? { [weak self] in self?.load(append: true) } : nil)
  }
}

@MainActor
private final class QFPurchaseEditorViewController: QFProfileContentController {
  private struct LocalDraft: Codable { let id: String; let value: QFPurchaseDraft }
  private let id: String
  private let draftKey: String
  private var draft: QFPurchaseDraft
  private let original: QFPurchaseDraft
  override var hasUnsavedChanges: Bool { draft != original }
  init(app: QFAppSession, date: String, purchase: QFPurchase?) {
    draftKey = purchase.map { "purchase-" + $0.id } ?? "purchase-new-" + date
    let saved = QFContentDraftStore.load(LocalDraft.self, app: app, kind: draftKey)
    id = purchase?.id ?? saved?.id ?? UUID().uuidString.lowercased()
    let value =
      purchase?.draft
      ?? QFPurchaseDraft(
        date: date, currency: Locale.current.currencyCode ?? "CNY", items: [{
          var item = QFPurchaseItem(); item.unit = app.text("克", "g"); return item
        }()])
    draft = saved?.value ?? value
    original = value
    super.init(app: app, title: purchase == nil ? app.text("记录采购", "Record purchase") : app.text("编辑采购", "Edit purchase"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    _ = addFooter(app.text("保存账单", "Save purchase")) { [weak self] in self?.save() }
    render()
  }
  private func render() {
    QFTabUI.clear(bodyStack)
    bodyStack.addArrangedSubview(QFContentUI.label(draft.date, size: 18, bold: true))
    bodyStack.addArrangedSubview(
      QFContentUI.field(app.text("账单币种，例如 CNY / USD", "Currency, for example CNY / USD"), text: draft.currency) { [weak self] in
        self?.draft.currency = $0.uppercased()
      })
    for index in draft.items.indices {
      let value = draft.items[index]
      let rows = QFTabUI.stack(
        [
          QFContentUI.field(app.text("采购食材", "Purchased ingredient"), text: value.name) { [weak self] in
            self?.draft.items[index].name = $0
          },
          QFContentUI.field(app.text("购买数量", "Quantity"), text: value.amount, keyboard: .decimalPad) { [weak self] in
            self?.draft.items[index].amount = $0
          },
          QFContentUI.field(app.text("计量单位", "Unit"), text: value.unit) { [weak self] in
            self?.draft.items[index].unit = $0
          },
          QFContentUI.field(app.text("该项实际支付小计", "Amount paid for this item"), text: value.cost, keyboard: .decimalPad) { [weak self] in
            self?.draft.items[index].cost = $0
          },
          QFContentUI.action(app.text("移除", "Remove"), destructive: true) { [weak self] in
            self?.draft.items.remove(at: index)
            self?.render()
          },
        ], spacing: 8)
      bodyStack.addArrangedSubview(QFTabUI.card(rows))
    }
    bodyStack.addArrangedSubview(
      QFContentUI.action(app.text("＋ 添加采购项", "+ Add item")) { [weak self] in
        guard let self, self.draft.items.count < 40 else { return }
        var item = QFPurchaseItem(); item.unit = self.app.text("克", "g")
        self.draft.items.append(item)
        self.render()
      })
    bodyStack.addArrangedSubview(
      QFContentTextArea(app.text("备注（选填）", "Notes (optional)"), text: draft.note, limit: 2000) { [weak self] in
        self?.draft.note = $0
      })
  }
  private func save() {
    guard draft.currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil,
      !draft.items.isEmpty,
      draft.items.allSatisfy({
        !$0.name.isEmpty && !$0.unit.isEmpty && (Decimal(string: $0.amount) ?? 0) > 0
          && (Decimal(string: $0.cost) ?? -1) >= 0
      })
    else {
      message(app.text("请填写有效币种，以及每项的名称、数量、单位和实际小计。", "Enter a valid currency and each item's name, quantity, unit, and actual subtotal."), error: true)
      return
    }
    preserveLocally()
    execute { [self] in
      let _: QFPurchase = try await app.contentRequest(
        path: "me/purchases/\(id)", method: "PUT", body: JSONEncoder().encode(draft))
      QFContentDraftStore.remove(app: app, kind: draftKey)
      onChanged?()
      qfClose()
    }
  }
  private func preserveLocally() {
    QFContentDraftStore.save(LocalDraft(id: id, value: draft), app: app, kind: draftKey)
  }
  override func close() {
    if draft == original {
      super.close()
      return
    }
    preserveOrDiscard({ [self] in preserveLocally() }, discard: { [self] in
      QFContentDraftStore.remove(app: app, kind: draftKey)
    })
  }
}
