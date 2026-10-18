import AVKit
import SnapKit
import UIKit

private struct QFSavedFavorite: Decodable { let saved: Bool }

@MainActor
final class QFWorkDetailViewController: QFProfileContentController {
  private let workID: String
  private var favorite = false
  private var favoriteButton: UIButton!
  init(app: QFAppSession, workID: String) {
    self.workID = workID
    super.init(app: app, title: app.text("作品详情", "Post details"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    favoriteButton = addFooter(app.text("收藏作品", "Save post"), primary: false) { [weak self] in self?.toggleFavorite() }
    load()
  }
  private func load() {
    setReloadAction { [weak self] in self?.load() }
    execute(reloadOnFailure: true) { [self] in
      favoriteButton.isEnabled = false
      let work: QFUserWork = try await app.contentRequest(path: "works/\(workID)")
      bodyStack.beginUpdates()
      bodyStack.row("date", version: work.updatedAt + work.status + (work.reviewNote ?? "")) { [self] in
        QFContentUI.label(
          "\(work.statusTitle(app: app)) · \(String(work.updatedAt.prefix(10)))" + (work.reviewNote.map { "\n" + $0 } ?? ""), size: 13, color: QFUI.primary)
      }
      let authorVersion = [
        work.authorName, work.authorAvatarMediaId ?? "", work.authorCountryCode ?? "",
        work.authorRegionCode ?? "",
      ].joined(separator: "|")
      bodyStack.row("author", version: authorVersion) { [self] in
        let image = QFContentUI.thumbnail(work.authorAvatarMediaId, app: app, height: 48)
        if work.authorAvatarMediaId == nil { image.image = UIImage(named: "default-avatar") }
        image.snp.makeConstraints { $0.width.equalTo(48) }
        image.layer.cornerRadius = 24
        let country = work.authorCountryCode.flatMap {
          Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier).localizedString(forRegionCode: $0)
        }
        let region = [country, work.authorRegionCode].compactMap { $0 }.filter { !$0.isEmpty }
          .joined(separator: " · ")
        let labels = QFTabUI.stack(
          [
            QFContentUI.label(work.authorName, size: 18, bold: true),
            QFContentUI.label(region, size: 13, color: QFUI.secondary),
          ], spacing: 5)
        let row = QFTabUI.stack([image, labels], axis: .horizontal, spacing: 12)
        row.alignment = .center
        return row
      }
      for id in work.photoIds {
        bodyStack.row("image." + id) { [self] in QFContentUI.thumbnail(id, app: app, height: 260) }
      }
      bodyStack.row("title", version: work.title) {
        QFContentUI.label(work.title, size: 28, bold: true)
      }
      if !work.body.isEmpty {
        bodyStack.row("body", version: work.body) { QFContentUI.label(work.body) }
      }
      QFContentDetailUI.materialRows(work.materials, into: bodyStack, app: app)
      QFContentDetailUI.stepRows(work.steps, into: bodyStack, app: app)
      if let video = work.videoId {
        bodyStack.row("video", version: video) { [self] in
          let preview = QFVideoPreviewView(app: app)
          preview.load(video)
          return preview
        }
      }
      if let recipe = work.linkedRecipeId {
        bodyStack.row("recipe", version: recipe) { [self] in
          QFContentUI.action(app.text("查看关联菜谱 ›", "View related recipe ›")) { [weak self] in
            guard let self else { return }
            self.open(QFCatalogDetailViewController.make(app: self.app, type: "RECIPE", id: recipe))
          }
        }
      }
      bodyStack.row("report") { [self] in
        QFContentUI.action(app.text("举报侵权或不当内容", "Report infringement or inappropriate content")) { [weak self] in
          guard let self else { return }
          self.open(QFRightsClaimEditorViewController(app: self.app, target: "WORK:\(self.workID)"))
        }
      }
      bodyStack.endUpdates()
      favoriteButton.isHidden = work.status != "PUBLISHED"
      guard work.status == "PUBLISHED" else { return }
      let state: QFSavedFavorite = try await app.contentRequest(path: "me/favorites/WORK/\(workID)")
      favorite = state.saved
      updateFavorite()
      favoriteButton.isEnabled = true
    }
  }
  private func updateFavorite() {
    favoriteButton.setTitle(favorite ? app.text("已收藏 · 取消", "Saved · Remove") : app.text("收藏作品", "Save post"), for: .normal)
  }
  private func toggleFavorite() {
    execute { [self] in
      try await app.contentMutation(
        path: "me/favorites/WORK/\(workID)", method: favorite ? "DELETE" : "PUT")
      favorite.toggle()
      updateFavorite()
      onChanged?()
    }
  }
}

@MainActor
final class QFCatalogDetailViewController: QFProfileContentController {
  static func make(app: QFAppSession, type: String, id: String, onChanged: @escaping () -> Void = {}) -> UIViewController {
    if type == "RECIPE" { return QFHomeRecipeDetailViewController(app: app, recipeID: id, onChanged: onChanged) }
    let controller = QFCatalogDetailViewController(app: app, type: type, id: id)
    controller.onChanged = onChanged
    return controller
  }
  private let type: String
  private let contentID: String
  private var relatedPagination = QFContentPagination<QFUserWork>()
  private let relatedWorks = QFContentListStack()
  private var favorite = false
  private var favoriteButton: UIButton?
  init(app: QFAppSession, type: String, id: String) {
    self.type = type
    contentID = id
    super.init(app: app, title: type == "RECIPE" ? app.text("菜谱详情", "Recipe details") : app.text("食材详情", "Ingredient details"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    if type == "RECIPE" {
      favoriteButton = addFooter(app.text("收藏", "Save"), primary: false) { [weak self] in self?.toggleFavorite() }
      _ = addFooter(app.text("加入计划", "Add to plan")) { [weak self] in
        guard let self else { return }
        self.open(QFAddRecipePlanViewController(app: self.app, recipeID: self.contentID))
      }
    }
    load()
  }
  private func load() {
    setReloadAction { [weak self] in self?.load() }
    execute(reloadOnFailure: true) { [self] in
      let item: QFCatalogItem = try await app.contentRequest(path: "catalog/\(type)/\(contentID)")
      bodyStack.beginUpdates()
      if let id = item.mediaId {
        bodyStack.row("image", version: id) { [self] in
          QFContentUI.thumbnail(id, app: app, height: 220)
        }
      }
      bodyStack.row("title", version: item.title) {
        QFContentUI.label(item.title, size: 28, bold: true)
      }
      bodyStack.row("subtitle", version: item.subtitle) {
        QFContentUI.label(item.subtitle, size: 14, color: QFUI.secondary)
      }
      if let minutes = item.minutes {
        bodyStack.row("time", version: String(minutes)) { [self] in
          QFContentUI.label(app.format("预计 %d 分钟", "About %d min", minutes), size: 14)
        }
      }
      if type == "RECIPE" {
        QFContentDetailUI.materialRows(item.materials, into: bodyStack, app: app)
        QFContentDetailUI.stepRows(item.steps, into: bodyStack, app: app)
      }
      if type == "RECIPE" {
        bodyStack.row("related.title") { [app] in QFContentUI.label(app.text("大家的作品", "Community posts"), size: 20, bold: true) }
        bodyStack.row("related") { [self] in
          relatedWorks.axis = .vertical
          relatedWorks.spacing = 12
          return relatedWorks
        }
      }
      bodyStack.endUpdates()
      if type == "RECIPE" {
        let state: QFSavedFavorite = try await app.contentRequest(
          path: "me/favorites/RECIPE/\(contentID)")
        favorite = state.saved
        updateFavorite()
        try await fetchRelatedWorks(reset: isRefreshingContent)
      }
    }
  }

  private func fetchRelatedWorks(append: Bool = false, reset: Bool = false) async throws {
    let previous = relatedPagination
    relatedPagination = try await previous.fetching(
      app: app, path: "catalog/RECIPE/\(contentID)/works", append: append, reset: reset,
      id: { $0.id })
    relatedWorks.beginUpdates()
    for work in relatedPagination.items {
      relatedWorks.row(work.id, value: work) { [self] in
        QFTabUI.card(
          QFTabUI.stack(
            [
              QFContentUI.label(
                app.format("用户作品 · %@", "Community post · %@", work.authorName),
                size: 12, color: QFUI.primary),
              QFContentUI.action(work.title + " ›") { [weak self] in
                guard let self else { return }
                self.open(QFWorkDetailViewController(app: self.app, workID: work.id))
              },
            ], spacing: 8))
      }
    }
    if relatedPagination.items.isEmpty {
      relatedWorks.row("empty") { [app] in QFTabUI.empty(app.text("还没有关联作品", "No related posts yet"), detail: app.text("分享你做这道菜的成果。", "Share how this dish turned out.")) }
    }
    relatedWorks.endUpdates()
    setLoadMoreAction(relatedPagination.hasMore ? { [weak self] in self?.loadMoreWorks() } : nil)
  }
  private func loadMoreWorks() {
    execute(reloadOnFailure: true, loadingMore: true) { [self] in
      try await fetchRelatedWorks(append: true)
    }
  }
  private func updateFavorite() {
    favoriteButton?.setTitle(favorite ? app.text("已收藏 · 取消", "Saved · Remove") : app.text("收藏", "Save"), for: .normal)
  }
  private func toggleFavorite() {
    execute { [self] in
      try await app.contentMutation(
        path: "me/favorites/RECIPE/\(contentID)", method: favorite ? "DELETE" : "PUT")
      favorite.toggle()
      updateFavorite()
      onChanged?()
    }
  }
}

@MainActor
private enum QFContentDetailUI {
  static func materialRows(_ items: [QFWorkMaterial], into stack: QFContentListStack, app: QFAppSession) {
    stack.row("materials.title", version: app.interfaceLanguage) { [app] in QFContentUI.label(app.text("所需材料", "Materials"), size: 20, bold: true) }
    for (index, item) in items.enumerated() {
      stack.row("material.\(index)", value: item) {
        let amount = QFContentUI.label("\(item.amount) \(item.unit)")
        amount.textAlignment = .right
        return QFTabUI.stack(
          [QFContentUI.label(item.name), amount], axis: .horizontal, spacing: 12)
      }
    }
  }
  static func stepRows(_ items: [QFWorkStep], into stack: QFContentListStack, app: QFAppSession) {
    guard !items.isEmpty else { return }
    stack.row("steps.title", version: app.interfaceLanguage) { [app] in QFContentUI.label(app.text("做法步骤", "Steps"), size: 20, bold: true) }
    for (index, step) in items.enumerated() {
      stack.row("step.\(index)", value: step) {
        QFTabUI.card(
          QFTabUI.stack(
            [
              QFContentUI.label("\(index + 1)  \(step.title)", bold: true),
              QFContentUI.label(step.body),
            ], spacing: 10))
      }
    }
  }

  static func materials(_ materials: [QFWorkMaterial], into stack: UIStackView, app: QFAppSession) {
    stack.addArrangedSubview(QFContentUI.label(app.text("所需材料", "Materials"), size: 20, bold: true))
    let rows = QFTabUI.stack([], spacing: 14)
    for item in materials {
      let amount = QFContentUI.label("\(item.amount) \(item.unit)")
      amount.textAlignment = .right
      rows.addArrangedSubview(
        QFTabUI.stack([QFContentUI.label(item.name), amount], axis: .horizontal, spacing: 12))
    }
    stack.addArrangedSubview(QFTabUI.card(rows))
  }
  static func steps(_ steps: [QFWorkStep], into stack: UIStackView, app: QFAppSession) {
    stack.addArrangedSubview(QFContentUI.label(app.text("做法步骤", "Steps"), size: 20, bold: true))
    for (index, step) in steps.enumerated() {
      stack.addArrangedSubview(
        QFTabUI.card(
          QFTabUI.stack(
            [
              QFContentUI.label("\(index + 1)  \(step.title)", bold: true),
              QFContentUI.label(step.body),
            ], spacing: 10)))
    }
  }
}

@MainActor
final class QFAddRecipePlanViewController: QFProfileContentController {
  private var draft: QFPlannedMealDraft
  private let id = UUID().uuidString.lowercased()
  private let datePicker = UIDatePicker()
  private let initialDate: Date
  private let onSaved: (QFPlannedMeal) -> Void
  init(
    app: QFAppSession, recipeID: String, initialDate: Date = Date(),
    onSaved: @escaping (QFPlannedMeal) -> Void = { _ in }
  ) {
    let allowedDate = max(Calendar.current.startOfDay(for: Date()), initialDate)
    draft = QFPlannedMealDraft(
      recipeId: recipeID, date: QFContentDate.day(allowedDate), meal: "LUNCH", servings: 1,
      householdId: app.planningHouseholdID)
    self.initialDate = allowedDate
    self.onSaved = onSaved
    super.init(app: app, title: app.text("加入计划", "Add to plan"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    datePicker.datePickerMode = .date
    datePicker.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    datePicker.preferredDatePickerStyle = .inline
    datePicker.minimumDate = Calendar.current.startOfDay(for: Date())
    datePicker.date = initialDate
    datePicker.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.draft.date = QFContentDate.day(self.datePicker.date)
      }, for: .valueChanged)
    bodyStack.addArrangedSubview(datePicker)
    bodyStack.addArrangedSubview(
      QFContentUI.segments([app.text("早餐", "Breakfast"), app.text("午餐", "Lunch"), app.text("晚餐", "Dinner"), app.text("加餐", "Snack")], selected: 1) { [weak self] index in
        self?.draft.meal = ["BREAKFAST", "LUNCH", "DINNER", "SNACK"][index]
      })
    bodyStack.addArrangedSubview(
      QFContentUI.field(app.text("计划份数", "Servings"), text: "1", keyboard: .numberPad) { [weak self] in
        self?.draft.servings = Int($0) ?? 0
      })
    _ = addFooter(app.text("确认加入", "Add to plan")) { [weak self] in
      guard let self else { return }
      guard (1...100).contains(self.draft.servings) else {
        self.message(self.app.text("份数需为1至100。", "Servings must be between 1 and 100."), error: true)
        return
      }
      self.execute { [self] in
        let saved = try await self.app.savePlannedMeal(self.id, draft: self.draft)
        self.qfClose { self.onSaved(saved) }
      }
    }
  }
}

@MainActor
final class QFContentVideoController: AVPlayerViewController {
  private let localFile: URL
  private var ownsFile = true
  init(url: URL) {
    localFile = url; ownsFile = false
    super.init(nibName: nil, bundle: nil)
    player = AVPlayer(url: url)
  }
  init(data: Data) throws {
    localFile = FileManager.default.temporaryDirectory.appendingPathComponent(
      "qf-video-\(UUID().uuidString).mov")
    try data.write(to: localFile, options: .atomic)
    super.init(nibName: nil, bundle: nil)
    player = AVPlayer(url: localFile)
  }
  required init?(coder: NSCoder) { nil }
  deinit { if ownsFile { try? FileManager.default.removeItem(at: localFile) } }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    player?.pause()
  }
}
