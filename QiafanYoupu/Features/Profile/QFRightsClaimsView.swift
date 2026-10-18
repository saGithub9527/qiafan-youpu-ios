import UIKit

@MainActor
final class QFImageRightsViewController: QFProfileContentController {
  init(app: QFAppSession) { super.init(app: app, title: app.text("图片侵权保护", "Image rights protection")) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    bodyStack.addArrangedSubview(QFContentUI.label(app.text("尊重原创，也支持依法授权的图片", "Respect original work and properly licensed images"), size: 20, bold: true))
    bodyStack.addArrangedSubview(
      QFContentUI.label(app.text("发现疑似侵权图片时，请提供图片所在条目或链接、原作品、权利或授权材料，以及可以联系你的方式。投稿者也可以对处理结果提出申诉。", "If you find a potentially infringing image, provide the item or link, the original work, proof of rights or permission, and your contact details. Contributors may also appeal a decision.")))
    bodyStack.addArrangedSubview(
      QFContentUI.action(app.text("阅读完整图片侵权保护规则", "Read the full image rights policy")) { [weak self] in
        guard let self else { return }
        self.open(QFLocalLegalViewController(document: "image-rights", title: self.app.text("图片侵权保护规则", "Image rights policy"), language: self.app.interfaceLanguage))
      })
    bodyStack.addArrangedSubview(
      QFContentUI.action(app.text("查看处理记录", "View case history")) { [weak self] in
        guard let self else { return }
        self.open(QFRightsClaimsViewController(app: self.app))
      })
    _ = addFooter(app.text("提交侵权投诉", "Submit infringement report")) { [weak self] in
      guard let self else { return }
      self.open(QFRightsClaimEditorViewController(app: self.app))
    }
  }
}

@MainActor
final class QFRightsClaimEditorViewController: QFProfileContentController {
  private var draft: QFRightsClaim
  private var submitButton: UIButton!
  override var hasUnsavedChanges: Bool { !draft.description.isEmpty || !draft.contact.isEmpty }
  init(app: QFAppSession, target: String = "") {
    draft =
      QFContentDraftStore.load(QFRightsClaim.self, app: app, kind: "rights-claim")
      ?? QFRightsClaim()
    if !target.isEmpty { draft.target = String(target.prefix(500)) }
    super.init(app: app, title: app.text("权利投诉与申诉", "Rights complaint or appeal"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    bodyStack.addArrangedSubview(
      QFContentUI.field(app.text("涉及的条目、作品编号或链接", "Item, post ID, or link involved"), text: draft.target, limit: 500) { [weak self] in
        self?.draft.target = $0
        self?.validate()
      })
    bodyStack.addArrangedSubview(
      QFContentTextArea(app.text("说明权利依据、问题及证明材料链接", "Describe your rights, the issue, and links to supporting evidence"), text: draft.description, limit: 4000) { [weak self] in
        self?.draft.description = $0
        self?.validate()
      })
    bodyStack.addArrangedSubview(
      QFContentUI.field(app.text("可联系你的邮箱或联系方式", "Email or other contact details"), text: draft.contact, keyboard: .emailAddress, limit: 255) {
        [weak self] in
        self?.draft.contact = $0
        self?.validate()
      })
    bodyStack.addArrangedSubview(
      QFContentUI.field(app.text("电子签名（签署姓名）", "Electronic signature (full name)"), text: draft.signature) { [weak self] in
        self?.draft.signature = $0
        self?.validate()
      })
    let consent = QFContentUI.action("") {}
    func updateConsent() {
      consent.setTitle(
        (draft.statementAccepted ? "☑ " : "□ ") + app.text("我善意提出申请，确认信息真实并有权投诉或申诉。", "I submit this request in good faith, confirm the information is accurate, and have the right to complain or appeal."), for: .normal)
    }
    consent.titleLabel?.numberOfLines = 0
    consent.addAction(
      UIAction { [weak self, weak consent] _ in
        guard let self else { return }
        self.draft.statementAccepted.toggle()
        consent?.setTitle(
          (self.draft.statementAccepted ? "☑ " : "□ ") + self.app.text("我善意提出申请，确认信息真实并有权投诉或申诉。", "I submit this request in good faith, confirm the information is accurate, and have the right to complain or appeal."), for: .normal)
        self.validate()
      }, for: .touchUpInside)
    updateConsent()
    bodyStack.addArrangedSubview(consent)
    submitButton = addFooter(app.text("提交申请", "Submit request")) { [weak self] in self?.submit() }
    validate()
  }
  private func validate() {
    submitButton?.isEnabled =
      !draft.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && draft.description.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
      && draft.contact.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
      && !draft.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && draft.statementAccepted
    submitButton?.alpha = submitButton?.isEnabled == true ? 1 : 0.45
  }
  private func submit() {
    QFContentDraftStore.save(draft, app: app, kind: "rights-claim")
    execute { [self] in
      let body = try JSONSerialization.data(withJSONObject: [
        "target": draft.target, "description": draft.description, "contact": draft.contact,
        "statementAccepted": draft.statementAccepted, "signature": draft.signature,
      ])
      let _: QFRightsClaim = try await app.contentRequest(
        path: "me/rights-claims/\(draft.id)", method: "PUT", body: body)
      QFContentDraftStore.remove(app: app, kind: "rights-claim")
      onChanged?()
      qfClose()
    }
  }
  override func close() {
    if draft.description.isEmpty && draft.contact.isEmpty {
      super.close()
      return
    }
    preserveOrDiscard(
      { [self] in QFContentDraftStore.save(draft, app: app, kind: "rights-claim") },
      discard: { [self] in QFContentDraftStore.remove(app: app, kind: "rights-claim") })
  }
}

@MainActor
final class QFRightsClaimsViewController: QFProfileContentController {
  private var pagination = QFContentPagination<QFRightsClaim>()
  private let results = QFContentListTable(frame: .zero, style: .plain)
  init(app: QFAppSession) { super.init(app: app, title: app.text("投诉与申诉记录", "Complaints and appeals")) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    results.spacing = 14
    installList(results)
    load()
  }
  private func load(append: Bool = false) {
    setReloadAction { [weak self] in self?.load() }
    let previous = pagination
    let reset = isRefreshingContent
    execute(reloadOnFailure: true, loadingMore: append) { [self] in
      pagination = try await previous.fetching(
        app: app, path: "me/rights-claims", append: append, reset: reset, id: { $0.id })
      render()
    }
  }
  private func render() {
    results.beginUpdatesForRows()
    if pagination.items.isEmpty {
      results.row("static.1", version: "\(pagination.total)") { [weak self] in
        guard let self else { return UIView() }
        return QFTabUI.empty(
          self.app.text("暂无申请记录", "No requests"),
          detail: self.app.text("你提交的投诉和申诉会显示在这里。", "Your complaints and appeals will appear here."))
      }
    }
    for item in pagination.items {
      results.row(item.id, value: item) { [weak self] in
        guard let self else { return UIView() }
        let status: String
        switch item.status ?? "PENDING" {
        case "PENDING": status = self.app.text("待核查", "Pending review")
        case "PROCESSING": status = self.app.text("处理中", "In progress")
        case "RESOLVED": status = self.app.text("已处理", "Resolved")
        case "REJECTED": status = self.app.text("未通过", "Not approved")
        default: status = self.app.text("处理中", "In progress")
        }
        let card = QFTabUI.card(
          QFTabUI.stack(
            [
              QFContentUI.label(item.target, bold: true),
              QFContentUI.label(status, size: 13, color: QFUI.success),
              QFContentUI.label(item.description, size: 14),
              QFContentUI.label(item.reviewNote ?? self.app.text("等待处理说明", "Awaiting an update"), size: 14, color: QFUI.secondary),
              QFContentUI.label(
                String((item.createdAt ?? "").prefix(10)), size: 12, color: QFUI.secondary),
            ], spacing: 10))
        let action = QFContentUI.action(self.app.text("补充材料或对本案申诉", "Add evidence or appeal this case")) { [weak self] in
          guard let self else { return }
          let editor = QFRightsClaimEditorViewController(
            app: self.app,
            target: self.app.format("案件 %@：%@", "Case %@: %@", item.id, item.target))
          editor.onChanged = { [weak self] in
            self?.reloadIfVisible()
          }
          self.open(editor)
        }
        return QFTabUI.stack([card, action], spacing: 8)
      }
    }
    results.endUpdatesForRows()
    setLoadMoreAction(pagination.hasMore ? { [weak self] in self?.load(append: true) } : nil)
  }
}
