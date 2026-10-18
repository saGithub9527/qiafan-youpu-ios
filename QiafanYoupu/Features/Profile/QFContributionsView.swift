import SnapKit
import UIKit

@MainActor
final class QFContributionEditorViewController: QFProfileContentController {
  private var draft: QFContributionDraft {
    didSet {
      guard isViewLoaded else { return }
      QFContentDraftStore.save(draft, app: app, kind: "contribution")
      if draft.mediaId != oldValue.mediaId { QFLocalMediaStore.remove(oldValue.mediaId, scope: app.contentScope) }
    }
  }
  private var initial: QFContributionDraft
  private var submitButton: UIButton!
  private var targetCategory: UISegmentedControl?
  override var hasUnsavedChanges: Bool { draft != initial }
  init(app: QFAppSession, targetType: String? = nil, targetID: String? = nil, title: String = "") {
    let saved =
      targetID == nil
      ? QFContentDraftStore.load(QFContributionDraft.self, app: app, kind: "contribution") : nil
    var value = saved ?? QFContributionDraft()
    if let targetType { value.targetType = targetType }
    if let targetID {
      value.targetId = targetID
      value.targetTitle = title
    }
    draft = value
    initial = value
    super.init(app: app, title: app.text("补充图片", "Contribute photo"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    submitButton = addFooter(app.text("提交审核", "Submit for review")) { [weak self] in self?.submit() }
    render()
  }
  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row("category", version: draft.targetType) { [self] in
      let control = QFContentUI.segments(
        [app.text("食材", "Ingredient"), app.text("菜谱", "Recipe")], selected: draft.targetType == "INGREDIENT" ? 0 : 1
      ) {
        [weak self] index in
        guard let self else { return }
        let type = index == 0 ? "INGREDIENT" : "RECIPE"
        if type != self.draft.targetType {
          self.changeTarget {
            self.draft = QFContributionDraft()
            self.draft.targetType = type
            self.render()
          }
        }
      }
      targetCategory = control
      return control
    }
    bodyStack.row("search", version: draft.targetType) { [self] in
      QFContentUI.action(draft.targetType == "INGREDIENT" ? app.text("搜索并选择食材", "Search and choose an ingredient") : app.text("搜索并选择菜谱", "Search and choose a recipe")) { [weak self] in
        guard let self else { return }
        self.open(
          QFCatalogSearchViewController(app: self.app, type: self.draft.targetType) {
            [weak self] item in
            guard let self else { return }
            self.changeTarget {
              self.draft.targetId = item.id
              self.draft.targetTitle = item.title
              self.draft.mediaId = nil
              self.draft.id = UUID().uuidString.lowercased()
              self.render()
            }
          })
      }
    }
    if draft.targetId == nil {
      bodyStack.row("empty") { [app] in QFTabUI.empty(app.text("先找到要补图的条目", "Choose an item first"), detail: app.text("搜索食材或菜谱，再添加对应图片。", "Search for an ingredient or recipe, then add its photo.")) }
    } else {
      bodyStack.row("target", version: (draft.targetId ?? "") + draft.targetTitle) { [self] in
        QFTabUI.card(
          QFTabUI.stack(
            [
              QFContentUI.label(draft.targetTitle, size: 20, bold: true),
              QFContentUI.label(
                draft.targetType == "INGREDIENT" ? app.text("已选择 · 食材", "Selected · Ingredient") : app.text("已选择 · 菜谱", "Selected · Recipe"), size: 13,
                color: QFUI.success),
              QFContentUI.action(app.text("清除条目", "Clear item")) { [weak self] in
                self?.changeTarget { [weak self] in
                  self?.draft = QFContributionDraft()
                  self?.render()
                }
              },
            ], spacing: 10))
      }
    }
    bodyStack.row("image.title") { [app] in QFContentUI.label(app.text("选择图片 · 每次1张", "Choose one photo"), size: 19, bold: true) }
    if let id = draft.mediaId {
      bodyStack.row("image", version: id) { [self] in
        QFContentUI.thumbnail(id, app: app, height: 240)
      }
      bodyStack.row("remove") { [self] in
        QFContentUI.action(app.text("移除图片", "Remove photo"), destructive: true) { [weak self] in
          self?.draft.mediaId = nil
          self?.render()
        }
      }
    }
    bodyStack.row("choose", version: (draft.targetId ?? "") + (draft.mediaId ?? "")) { [self] in
      let choose = QFContentUI.action(
        draft.targetId == nil ? app.text("请先选择条目", "Choose an item first") : draft.mediaId == nil ? app.text("从相册选择", "Choose from Photos") : app.text("更换图片", "Replace photo")
      ) { [weak self] in
        self?.chooseMedia { [weak self] media in
          self?.draft.mediaId = media.id
          self?.draft.id = UUID().uuidString.lowercased()
          self?.render()
        }
      }
      if draft.mediaId == nil {
        choose.setImage(UIImage(systemName: "photo.badge.plus"), for: .normal)
        choose.backgroundColor = QFUI.surface
        choose.layer.cornerRadius = 16
        choose.snp.makeConstraints { $0.height.equalTo(240) }
        choose.accessibilityLabel = draft.targetId == nil ? app.text("请先选择食材或菜谱", "Choose an ingredient or recipe first") : app.text("添加图片", "Add photo")
      }
      choose.isEnabled = draft.targetId != nil
      return choose
    }
    bodyStack.endUpdates()
    targetCategory?.selectedSegmentIndex = draft.targetType == "INGREDIENT" ? 0 : 1
    submitButton.isEnabled = draft.targetId != nil && draft.mediaId != nil
    submitButton.alpha = submitButton.isEnabled ? 1 : 0.45
  }
  private func changeTarget(_ action: @escaping () -> Void) {
    if draft.mediaId != nil {
      confirm(app.text("更换图片对应的条目？", "Change the item for this photo?"), detail: app.text("更换条目后需要重新选择对应图片。", "You will need to choose a new photo after changing the item."), actionTitle: app.text("更换", "Change")) { action() }
      render()
    } else {
      action()
    }
  }
  private func submit() {
    guard let target = draft.targetId, let media = draft.mediaId else {
      return
    }
    QFContentDraftStore.save(draft, app: app, kind: "contribution")
    execute(label: app.text("提交审核中", "Submitting for review")) { [self] in
      let uploaded = try await app.uploadedMediaID(media)
      let body = try JSONSerialization.data(withJSONObject: [
        "targetType": draft.targetType, "targetId": target, "mediaId": uploaded,
      ])
      let _: QFContribution = try await app.contentRequest(
        path: "me/contributions/\(draft.id)", method: "PUT", body: body)
      QFContentDraftStore.remove(app: app, kind: "contribution")
      QFLocalMediaStore.remove(media, scope: app.contentScope)
      onChanged?()
      closeWithSuccess(app.text("图片已提交审核", "Photo submitted for review"))
    }
  }
  override func close() {
    guard draft.targetId != nil || draft.mediaId != nil else {
      super.close()
      return
    }
    preserveOrDiscard(
      { [self] in QFContentDraftStore.save(draft, app: app, kind: "contribution") },
      discard: { [self] in
        QFLocalMediaStore.remove(draft.mediaId, scope: app.contentScope)
        QFContentDraftStore.remove(app: app, kind: "contribution")
      })
  }
}

@MainActor
final class QFContributionsViewController: QFProfileContentController {
  private var filter = "ALL"
  private var pagination = QFContentPagination<QFContribution>()
  private let results = QFContentListTable(frame: .zero, style: .plain)
  init(app: QFAppSession) { super.init(app: app, title: app.text("我的图片贡献", "My photo contributions")) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    _ = addFooter(app.text("补充图片", "Contribute photo")) { [weak self] in self?.edit() }
    let tabs = categoryTabs([app.text("全部", "All"), app.text("审核中", "In review"), app.text("已采用", "Accepted"), app.text("未采用", "Not accepted")]) { [weak self] index in
      self?.filter = ["ALL", "PENDING", "ACCEPTED", "REJECTED"][index]
      self?.pagination = QFContentPagination()
      self?.results.apply([])
      self?.setLoadMoreAction(nil)
      self?.results.setContentOffset(.zero, animated: false)
      self?.load()
    }
    results.spacing = 14
    installList(results, controls: tabs)
    load()
  }
  private func edit(_ contribution: QFContribution? = nil) {
    let editor = QFContributionEditorViewController(
      app: app, targetType: contribution?.targetType, targetID: contribution?.targetId,
      title: contribution?.targetTitle ?? "")
    editor.onChanged = { [weak self] in
      self?.reloadIfVisible()
      self?.onChanged?()
    }
    open(editor)
  }
  private func load(append: Bool = false) {
    setReloadAction { [weak self] in self?.load() }
    let previous = pagination
    let requestedFilter = filter
    let reset = isRefreshingContent
    execute(reloadOnFailure: true, loadingMore: append) { [self] in
      let updated = try await previous.fetching(
        app: app, path: "me/contributions", query: ["status": requestedFilter],
        append: append, reset: reset, id: { $0.id })
      guard filter == requestedFilter else { throw CancellationError() }
      pagination = updated
      render()
    }
  }
  private func render() {
    let app = app
    let pagination = pagination
    results.beginUpdatesForRows()
    results.row("static.1", version: "\(pagination.total)|\(filter)") {
      QFContentUI.label(
        app.format("共 %d 条贡献", "%d contributions", pagination.total), size: 14, bold: true)
    }
    if pagination.items.isEmpty {
      results.row("static.2", version: "\(pagination.total)|\(filter)") {
        QFTabUI.empty(app.text("暂无贡献记录", "No contributions"), detail: app.text("投稿会先进入审核，不会直接替换条目图片。", "Submissions are reviewed before they can replace an item photo."))
      }
    }
    for item in pagination.items {
      results.row(item.id, value: item) { [weak self] in
        let image = QFContentUI.thumbnail(item.mediaId, app: app, height: 140)
        let rows = QFTabUI.stack(
          [
            image, QFContentUI.label(item.targetTitle, size: 19, bold: true),
            QFContentUI.label(
              item.statusTitle(app: app) + " · " + String(item.createdAt.prefix(10)), size: 13,
              color: QFUI.success),
          ], spacing: 10)
        if let reason = item.reason, !reason.isEmpty {
          rows.addArrangedSubview(QFContentUI.label(
            app.format("原因：%@", "Reason: %@", reason), size: 14, color: QFUI.danger))
        }
        rows.addArrangedSubview(
          QFContentUI.action(app.text("查看条目 ›", "View item ›")) { [weak self] in
            guard let self else { return }
            self.open(
              QFCatalogDetailViewController.make(
                app: self.app, type: item.targetType, id: item.targetId))
          })
        if item.status == "REJECTED" || item.status == "WITHDRAWN" {
          rows.addArrangedSubview(QFContentUI.action(app.text("重新提交", "Resubmit")) { [weak self] in self?.edit(item) })
        }
        if ["PENDING", "ACCEPTED"].contains(item.status) && !item.withdrawalRequested {
          rows.addArrangedSubview(
            QFContentUI.action(item.status == "PENDING" ? app.text("撤回投稿", "Withdraw submission") : app.text("申请撤回", "Request withdrawal")) { [weak self] in
              self?.confirm(
                app.text("撤回这张图片？", "Withdraw this photo?"),
                detail: item.status == "PENDING" ? app.text("确认后退出待审核队列。", "It will leave the review queue after confirmation.") : app.text("提交申请后核实使用记录，再停止公开展示。", "We will check its usage after your request before removing it from public view."),
                actionTitle: app.text("确认撤回", "Withdraw")
              ) { [weak self] in
                self?.execute { [weak self] in
                  guard let self else { return }
                  let _: QFContribution = try await self.app.contentRequest(
                    path: "me/contributions/\(item.id)/withdraw", method: "POST")
                  self.onChanged?()
                  DispatchQueue.main.async { self.load() }
                }
              }
            })
        }
        return QFTabUI.card(rows)
      }
    }
    results.endUpdatesForRows()
    setLoadMoreAction(pagination.hasMore ? { [weak self] in self?.load(append: true) } : nil)
  }
}
