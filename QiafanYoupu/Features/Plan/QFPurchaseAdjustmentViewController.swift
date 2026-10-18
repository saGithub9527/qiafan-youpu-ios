import SnapKit
import UIKit

private struct QFPurchaseAdjustmentDraft: Codable {
  var type = "REFUND"
  var date = QFContentDate.day(Date())
  var items: [QFPurchaseAdjustmentItem] = []
  var note = ""
  var pending: QFPurchaseAdjustmentRequest?
  var language: String?
}
@MainActor
final class QFPurchaseAdjustmentViewController: QFProfileContentController {
  private var receipt: QFPurchaseReceipt
  private let onSaved: (QFPurchaseReceipt) -> Void
  private var draft: QFPurchaseAdjustmentDraft
  private let key: String
  private var sending = false
  private var conflicted = false
  private var saveButton: UIButton!
  override var reloadsOnAppearance: Bool { false }
  override var hasUnsavedChanges: Bool { draft.pending != nil || draft.items.contains { !$0.refundAmount.isEmpty } }
  init(app: QFAppSession, receipt: QFPurchaseReceipt, onSaved: @escaping (QFPurchaseReceipt) -> Void) {
    self.receipt = receipt; self.onSaved = onSaved; key = "receipt-adjustment." + receipt.id
    draft = QFContentDraftStore.load(QFPurchaseAdjustmentDraft.self, app: app, kind: key) ?? .init(items: receipt.items.map { .init(lineId: $0.id, refundAmount: "", quantity: nil, unitCode: $0.unitCode) })
    super.init(app: app, title: app.text("退款或退货", "Refund or return"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); view.accessibilityIdentifier = "purchase.adjustment"
    saveButton = addFooter(app.text("保存", "Save")) { [weak self] in self?.save() }; saveButton.accessibilityIdentifier = "purchase.adjustment.save"; render()
  }
  @discardableResult private func persist() -> Bool {
    let ok = QFContentDraftStore.save(draft, app: app, kind: key)
    if !ok { message(app.text("草稿保存失败，请重试。", "Could not save the draft. Please retry."), error: true) }; return ok
  }
  private func render() {
    QFTabUI.clear(bodyStack)
    bodyStack.addArrangedSubview(QFContentUI.segments([app.text("仅退款", "Refund only"), app.text("退货退款", "Return and refund")], selected: draft.type == "RETURN" ? 1 : 0) { [weak self] index in self?.draft.type = index == 1 ? "RETURN" : "REFUND"; self?.persist(); self?.render() })
    let picker = UIDatePicker(); picker.datePickerMode = .date; picker.preferredDatePickerStyle = .compact
    picker.calendar = QFManualPlanDraft.calendar; picker.timeZone = QFManualPlanDraft.calendar.timeZone
    picker.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    picker.date = QFManualPlanDraft.date(draft.date) ?? Date(); picker.minimumDate = QFManualPlanDraft.date(receipt.date); picker.maximumDate = QFManualPlanDraft.date(QFContentDate.day(Date()))
    picker.addAction(UIAction { [weak self, weak picker] _ in guard let self, let picker else { return }; self.draft.date = QFManualPlanDraft.string(picker.date); self.persist() }, for: .valueChanged)
    bodyStack.addArrangedSubview(picker)
    for item in receipt.items {
      guard let row = draft.items.first(where: { $0.lineId == item.id }) else { continue }
      let amount = QFContentUI.field(app.text("退款金额", "Refund amount"), text: row.refundAmount, keyboard: .decimalPad) { [weak self] value in self?.update(item.id) { $0.refundAmount = value } }
      amount.accessibilityIdentifier = "purchase.refund." + item.id
      let body = QFTabUI.stack([QFTabUI.label(item.name, size: 17, weight: .semibold), amount], spacing: 12)
      if draft.type == "RETURN" {
        body.addArrangedSubview(QFContentUI.field(app.text("退货数量", "Return quantity"), text: row.quantity ?? "", keyboard: .decimalPad) { [weak self] value in self?.update(item.id) { $0.quantity = value } })
        body.addArrangedSubview(QFTabUI.label(item.unitCode, size: 13, color: QFUI.secondary))
      }
      bodyStack.addArrangedSubview(QFTabUI.card(body, padding: 16, border: true))
    }
    bodyStack.addArrangedSubview(QFContentUI.field(app.text("备注", "Note"), text: draft.note, limit: 500) { [weak self] in self?.draft.note = $0; self?.persist() })
    bodyStack.isUserInteractionEnabled = draft.pending == nil && !sending; saveButton.isEnabled = !sending
    saveButton.setTitle(conflicted ? app.text("重新加载", "Reload") : draft.pending == nil ? app.text("保存", "Save") : app.text("重试", "Retry"), for: .normal)
  }
  private func update(_ id: String, edit: (inout QFPurchaseAdjustmentItem) -> Void) {
    guard let index = draft.items.firstIndex(where: { $0.lineId == id }), draft.pending == nil else { return }
    edit(&draft.items[index]); persist()
  }
  private func save() {
    view.endEditing(true); guard !sending else { return }
    if conflicted {
      sending = true; render()
      execute(label: app.text("正在加载", "Loading")) { [self] in
        defer { sending = false; render() }
        receipt = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.contentRequest(path: "me/purchase-receipts/\(receipt.id)") }
        draft.pending = nil; conflicted = false; persist()
      }; return
    }
    if draft.pending == nil {
      let locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
      let items = draft.items.filter { !$0.refundAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { row in
        QFPurchaseAdjustmentItem(lineId: row.lineId, refundAmount: QFPurchaseNumber.normalize(row.refundAmount, locale: locale), quantity: draft.type == "RETURN" ? row.quantity.map { QFPurchaseNumber.normalize($0, locale: locale) } : nil, unitCode: draft.type == "RETURN" ? row.unitCode : nil)
      }
      guard !items.isEmpty, draft.date >= receipt.date, draft.date <= QFContentDate.day(Date()), items.allSatisfy({
        (QFPurchaseNumber.decimal($0.refundAmount) ?? -1) >= 0 && (draft.type != "RETURN" || (QFPurchaseNumber.decimal($0.quantity ?? "") ?? 0) > 0)
      }) else { message(app.text("请检查日期、数量和退款金额。", "Check the date, quantities and refund amounts."), error: true); return }
      draft.pending = .init(requestId: UUID(), expectedRevision: receipt.revision, date: draft.date, time: nil, timeZone: TimeZone.current.identifier, type: draft.type, items: items, note: draft.note)
      draft.language = app.interfaceLanguage; guard persist() else { draft.pending = nil; return }
    }
    guard let request = draft.pending else { return }; sending = true; render()
    execute(label: app.text("正在保存", "Saving")) { [self] in
      defer { sending = false; render() }
      do {
        let result: QFPurchaseReceipt = try await QFContentLoadingContext.$language.withValue(draft.language ?? app.interfaceLanguage) {
          try await app.contentRequest(path: "me/purchase-receipts/\(receipt.id)/adjustments", method: "POST", body: JSONEncoder().encode(request), operationID: request.requestId)
        }
        QFContentDraftStore.remove(app: app, kind: key); onSaved(result); qfClose()
      } catch {
        if let failure = error as? QFAPIError {
          if failure.code == 40900 { conflicted = true }
          if failure.code == 40000 || (42200...42299).contains(failure.code) { draft.pending = nil; persist() }
        }
        throw error
      }
    }
  }
}
