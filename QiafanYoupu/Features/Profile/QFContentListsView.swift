import SnapKit
import UIKit

@MainActor
final class QFMyWorksViewController: QFProfileContentController {
  private var status = "PUBLISHED"
  private var pagination = QFContentPagination<QFUserWork>()
  private var localDrafts: [QFStoredWorkDraft] = []
  private var visibleDraftCount = 20
  private let results = QFContentListTable(frame: .zero, style: .plain)
  init(app: QFAppSession) { super.init(app: app, title: app.text("我的作品", "My posts")) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    _ = addFooter(app.text("发布作品", "Publish post")) { [weak self] in self?.edit(nil) }
    let controls = QFTabUI.stack(
      [
        categoryTabs([app.text("已发布", "Published"), app.text("审核中", "In review"), app.text("未通过", "Not approved"), app.text("草稿", "Drafts")]) { [weak self] index in
          self?.status = ["PUBLISHED", "PENDING", "REJECTED", "LOCAL"][index]
          self?.pagination = QFContentPagination()
          self?.results.apply([])
          self?.setLoadMoreAction(nil)
          self?.results.setContentOffset(.zero, animated: false)
          self?.load()
        },
      ], spacing: 8)
    results.spacing = 16
    installList(results, controls: controls)
    load()
  }
  private func edit(_ work: QFUserWork?, localDraft: QFStoredWorkDraft? = nil) {
    let controller = QFWorkEditorViewController(app: app, work: work, localDraft: localDraft)
    controller.onChanged = { [weak self] in
      self?.reloadIfVisible()
      self?.onChanged?()
    }
    open(controller)
  }
  private func load(append: Bool = false) {
    setReloadAction { [weak self] in self?.load() }
    if status == "LOCAL" {
      let saved = QFContentDraftStore.all(QFStoredWorkDraft.self, app: app, prefix: "work-")
      localDrafts = Dictionary(grouping: saved, by: \.id).values.compactMap {
        $0.max { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }
      }.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
      visibleDraftCount = append ? visibleDraftCount + 20 : 20
      execute(reloadOnFailure: true, loadingMore: append) { [self] in renderLocalDrafts() }
      return
    }
    let previous = pagination
    let requestedStatus = status
    let reset = isRefreshingContent
    execute(reloadOnFailure: true, loadingMore: append) { [self] in
      let updated = try await previous.fetching(
        app: app, path: "me/works", query: ["status": requestedStatus],
        append: append, reset: reset, id: { $0.id })
      guard status == requestedStatus else { throw CancellationError() }
      pagination = updated
      render()
    }
  }
  private func render() {
    let app = app
    let pagination = pagination
    let status = status
    results.beginUpdatesForRows()
    results.row("static.1", version: "\(pagination.total)|\(status)") {
      let label = status == "PUBLISHED" ? app.text("已发布", "Published")
        : status == "PENDING" ? app.text("审核中", "In review")
        : status == "REJECTED" ? app.text("未通过", "Not approved") : app.text("作品", "Posts")
      return QFContentUI.label(
        app.format("%@ %d 篇", "%@ · %d", label, pagination.total), size: 14,
        color: QFUI.secondary)
    }
    if pagination.items.isEmpty {
      results.row("static.2", version: "\(pagination.total)|\(status)") {
        QFTabUI.empty(app.text("暂无作品", "No posts"), detail: app.text("当前分类中没有作品。", "There are no posts in this category."))
      }
    }
    for work in pagination.items {
      results.row(work.id, value: work) { [weak self] in
        let title = QFContentUI.label(
          work.title.isEmpty ? app.text("未命名草稿", "Untitled draft") : work.title, size: 19, bold: true)
        let image = QFContentUI.thumbnail(work.coverMediaId ?? work.photoIds.first, app: app)
        image.snp.makeConstraints { $0.width.equalTo(96) }
        let meta = QFContentUI.label(
          app.format("%@ · %d 种材料", "%@ · %d materials", work.statusTitle(app: app), work.materials.count)
            + "\n\(String(work.updatedAt.prefix(10)))" + (work.reviewNote.map { "\n" + $0 } ?? ""),
          size: 13, color: QFUI.secondary)
        let top = QFTabUI.stack(
          [image, QFTabUI.stack([title, meta], spacing: 8)], axis: .horizontal, spacing: 14)
        top.alignment = .center
        let actions = QFTabUI.stack(
          [
            QFContentUI.action(status == "DRAFT" ? app.text("继续编辑", "Continue editing") : app.text("查看作品", "View post")) { [weak self] in
              guard let self else { return }
              if work.status == "DRAFT" {
                self.edit(work)
              } else {
                self.open(QFWorkDetailViewController(app: self.app, workID: work.id))
              }
            },
            QFContentUI.action(app.text("编辑", "Edit")) { [weak self] in self?.edit(work) },
            QFContentUI.action(app.text("删除", "Delete"), destructive: true) { [weak self] in
              self?.confirm(
                app.text("删除这篇作品？", "Delete this post?"), detail: app.text("删除后将不再展示，不会删除关联菜谱或做菜记录。", "It will no longer appear. Related recipes and cooking history are kept."), actionTitle: app.text("确认删除", "Delete"),
                destructive: true
              ) { [weak self] in
                self?.execute { [weak self] in
                  guard let self else { return }
                  try await self.app.contentMutation(
                    path: "me/works/\(work.id)", method: "DELETE")
                  self.onChanged?()
                  // The current operation finishes before the refreshed read starts.
                  DispatchQueue.main.async { self.load() }
                }
              }
            },
          ], axis: .horizontal, spacing: 14)
        return QFTabUI.card(QFTabUI.stack([top, actions], spacing: 12))
      }
    }
    results.endUpdatesForRows()
    setLoadMoreAction(pagination.hasMore ? { [weak self] in self?.load(append: true) } : nil)
  }

  private func renderLocalDrafts() {
    results.beginUpdatesForRows()
    if localDrafts.isEmpty {
      results.row("local.empty") { [app] in QFTabUI.empty(app.text("还没有草稿", "No drafts yet"), detail: app.text("未提交的作品会保存在这台设备。", "Unsubmitted posts are saved on this device.")) }
    }
    for draft in localDrafts.prefix(visibleDraftCount) {
      results.row("local." + draft.id, value: draft) { [weak self] in
        guard let self else { return UIView() }
        let thumbnail = QFContentUI.thumbnail(draft.value.coverMediaId ?? draft.value.photoIds.first, app: self.app)
        thumbnail.snp.makeConstraints { $0.width.equalTo(96) }
        let title = QFContentUI.label(draft.value.title.isEmpty ? self.app.text("未命名草稿", "Untitled draft") : draft.value.title, size: 18, bold: true)
        let date = QFContentUI.label(String((draft.updatedAt ?? "").prefix(10)), size: 13, color: QFUI.secondary)
        let top = QFTabUI.stack([thumbnail, QFTabUI.stack([title, date], spacing: 8)], axis: .horizontal, spacing: 12)
        top.alignment = .center
        let actions = QFTabUI.stack([
          QFContentUI.action(self.app.text("继续编辑", "Continue editing")) { [weak self] in self?.edit(nil, localDraft: draft) },
          QFContentUI.action(self.app.text("删除草稿", "Delete draft"), destructive: true) { [weak self] in
            guard let self else { return }
            self.confirm(self.app.text("删除这份本地草稿？", "Delete this local draft?"), detail: self.app.text("草稿和未提交的图片、视频将从这台设备移除。", "The draft and its unsubmitted photos and video will be removed from this device."), actionTitle: self.app.text("删除", "Delete"), destructive: true) { [weak self] in
              guard let self else { return }
              for id in draft.value.photoIds + [draft.value.videoId].compactMap({ $0 }) {
                QFLocalMediaStore.remove(id, scope: self.app.contentScope)
              }
              QFContentDraftStore.remove(app: self.app, kind: "work-" + draft.id)
              if QFContentDraftStore.load(QFStoredWorkDraft.self, app: self.app, kind: "work-new")?.id == draft.id {
                QFContentDraftStore.remove(app: self.app, kind: "work-new")
              }
              self.load()
            }
          }
        ], axis: .horizontal, spacing: 18)
        return QFTabUI.card(QFTabUI.stack([top, actions], spacing: 12))
      }
    }
    results.endUpdatesForRows()
    setLoadMoreAction(localDrafts.count > visibleDraftCount ? { [weak self] in self?.load(append: true) } : nil)
  }

}

@MainActor
final class QFFavoritesViewController: QFProfileContentController {
  private var selected = 0
  private var queries = ["", ""]
  private var activeQueries = ["", ""]
  private var paginations = [
    QFContentPagination<QFFavoriteItem>(), QFContentPagination<QFFavoriteItem>(),
  ]
  private var renderedTab: Int?
  private var offsets = [CGPoint.zero, CGPoint.zero]
  private var searchField: UITextField!
  private let results = QFContentListTable(frame: .zero, style: .plain)
  init(app: QFAppSession) { super.init(app: app, title: app.text("我的收藏", "Saved")) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    let tabs = categoryTabs([app.text("菜谱", "Recipes"), app.text("用户作品", "Community posts")]) { [weak self] index in
      guard let self else { return }
      self.offsets[self.selected] = self.results.contentOffset
      self.selected = index
      self.searchField.text = self.queries[index]
      self.render()
      self.load()
    }
    searchField = QFContentUI.field(app.text("搜索当前分类的收藏", "Search saved items in this category")) { [weak self] value in
      guard let self else { return }
      self.queries[self.selected] = value
    }
    let search = QFContentUI.action(app.text("搜索", "Search")) { [weak self] in
      guard let self else { return }
      self.activeQueries[self.selected] = self.queries[self.selected]
      self.paginations[self.selected] = QFContentPagination()
      self.offsets[self.selected] = .zero
      self.renderedTab = nil
      self.render()
      self.load()
    }
    results.spacing = 14
    let searchRow = QFTabUI.stack([searchField, search], axis: .horizontal, spacing: 8)
    search.setContentHuggingPriority(.required, for: .horizontal)
    installList(results, controls: QFTabUI.stack([tabs, searchRow], spacing: 8))
    load()
  }
  private func load(append: Bool = false) {
    setReloadAction { [weak self] in self?.load() }
    let tab = selected
    let previous = paginations[tab]
    let query = activeQueries[tab]
    let reset = isRefreshingContent
    execute(reloadOnFailure: true, loadingMore: append) { [self] in
      let updated = try await previous.fetching(
        app: app, path: "me/favorites",
        query: ["type": tab == 0 ? "RECIPE" : "WORK", "q": query],
        append: append, reset: reset, id: { $0.type + $0.id })
      guard selected == tab, activeQueries[tab] == query else { throw CancellationError() }
      paginations[tab] = updated
      render()
    }
  }
  private func render() {
    let app = app
    let pagination = paginations[selected]
    results.beginUpdatesForRows()
    results.row("static.5", version: "\(pagination.total)|\(selected)") {
      QFContentUI.label(
        app.format(
          "当前分类 %d 项 · 按收藏时间", "%d in this category · Saved date", pagination.total),
        size: 13, color: QFUI.secondary)
    }
    if pagination.items.isEmpty {
      results.row("static.6", version: "\(pagination.total)|\(selected)") {
        QFTabUI.empty(app.text("暂无符合条件的收藏", "No matching saved items"), detail: app.text("清空搜索，或返回浏览菜谱与用户作品。", "Clear the search or browse recipes and community posts."))
      }
    }
    for item in pagination.items {
      results.row(item.type + item.id, value: item) { [weak self] in
        let image = QFContentUI.thumbnail(item.mediaId, app: app)
        image.snp.makeConstraints { $0.width.equalTo(96) }
        let content = QFTabUI.stack(
          [
            QFContentUI.action(item.title) { [weak self] in
              guard let self else { return }
              let changed: () -> Void = { [weak self] in
                self?.reloadIfVisible()
                self?.onChanged?()
              }
              if item.type == "WORK" {
                let detail = QFWorkDetailViewController(app: self.app, workID: item.id)
                detail.onChanged = changed; self.open(detail)
              } else {
                self.open(QFCatalogDetailViewController.make(app: self.app, type: "RECIPE", id: item.id, onChanged: changed))
              }
            },
            QFContentUI.label(
              item.type == "WORK" ? app.text("用户作品", "Community post") : app.text("官方菜谱", "Official recipe"), size: 12, color: QFUI.success),
            QFContentUI.label(item.subtitle, size: 13, color: QFUI.secondary),
            QFContentUI.action(app.text("取消收藏", "Remove from saved")) { [weak self] in
              self?.execute { [weak self] in
                guard let self else { return }
                try await self.app.contentMutation(
                  path: "me/favorites/\(item.type)/\(item.id)", method: "DELETE")
                self.onChanged?()
                DispatchQueue.main.async { self.load() }
              }
            },
          ], spacing: 4)
        let row = QFTabUI.stack([image, content], axis: .horizontal, spacing: 12)
        row.alignment = .center
        return QFTabUI.card(row)
      }
    }
    results.endUpdatesForRows()
    if renderedTab != selected {
      view.layoutIfNeeded()
      results.setContentOffset(offsets[selected], animated: false)
      renderedTab = selected
    }
    setLoadMoreAction(pagination.hasMore ? { [weak self] in self?.load(append: true) } : nil)
  }
}
