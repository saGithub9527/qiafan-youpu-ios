import Combine
import MJRefresh
import SnapKit
import UIKit

@MainActor
final class QFHomeRecipeDetailViewController: UIViewController {
  private let app: QFAppSession
  private let recipeID: String
  private let onChanged: (QFRecipeHomeItem) -> Void
  private let scrollView = UIScrollView()
  private let body = QFContentListStack()
  private let relatedWorks = QFContentListStack()
  private let refresh = UIRefreshControl()
  private let hud = QFOperationHUD()
  private let headerTitleLabel = QFTabUI.label("", size: 23, weight: .semibold)
  private var backButton: UIButton!
  private let favoriteButton = QFTabUI.button("", size: 16, weight: .semibold, color: QFUI.text, background: QFUI.surface) {}
  private let planButton = QFTabUI.button("", size: 16, weight: .semibold, color: QFUI.onPrimary, background: QFUI.primary) {}
  private var detail: QFRecipeHomeDetail?
  private var initial: QFRecipeHomeItem
  private var hasListPreview = true
  private var loadTask: Task<Void, Never>?
  private var planTask: Task<Void, Never>?
  private var mutationTask: Task<Void, Never>?
  private var relatedTask: Task<Void, Never>?
  private var related: [QFUserWork] = []
  private var plannedMeals: [QFPlannedMeal] = []
  private var relatedTotal = 0
  private var relatedNextPage = 0
  private var relatedHasMore = false
  private var relatedFooter: MJRefreshAutoNormalFooter!
  private var loadedLanguage = ""
  private var subscriptions = Set<AnyCancellable>()

  init(
    app: QFAppSession, initial: QFRecipeHomeItem,
    onChanged: @escaping (QFRecipeHomeItem) -> Void
  ) {
    self.app = app
    recipeID = initial.id
    self.initial = initial
    self.onChanged = onChanged
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }
  /// Every ID-only entry loads the same published detail and language contract
  /// as the home feed. Empty preview values are never a second recipe dataset.
  convenience init(app: QFAppSession, recipeID: String, onChanged: @escaping () -> Void = {}) {
    self.init(app: app, initial: QFRecipeHomeItem(id: recipeID, title: app.text("菜谱详情", "Recipe details"),
      subtitle: "", mediaId: nil, minutes: nil, servings: nil, favoriteCount: 0,
      ratingAverage: nil, ratingCount: 0, isFavorite: false, myRating: nil,
      categoryIds: [], cuisineIds: [], tasteIds: [], countryCodes: []), onChanged: { _ in onChanged() })
    hasListPreview = false
  }
  deinit { loadTask?.cancel(); planTask?.cancel(); mutationTask?.cancel(); relatedTask?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.accessibilityIdentifier = "recipe.detail"
    buildLayout()
    renderInitial()
    load(force: false)
    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] _ in
      DispatchQueue.main.async { self?.applyLanguage() }
    }.store(in: &subscriptions)
    app.$planningScope.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] _ in self?.reloadPlanState(force: false)
    }.store(in: &subscriptions)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(true, animated: animated)
    applyLanguage()
    if !loadedLanguage.isEmpty, loadedLanguage != app.interfaceLanguage { load(force: false) }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isMovingFromParent || isBeingDismissed {
      loadTask?.cancel(); planTask?.cancel(); mutationTask?.cancel(); relatedTask?.cancel(); hud.hide()
    }
  }

  private func buildLayout() {
    backButton = QFTabUI.iconButton(
      "chevron.left", label: app.text("返回", "Back"), size: 22
    ) { [weak self] in self?.qfClose() }
    backButton.snp.remakeConstraints { $0.size.equalTo(44) }
    backButton.tintColor = QFUI.text
    headerTitleLabel.textAlignment = .center
    headerTitleLabel.accessibilityTraits.insert(.header)
    let trailing = UIView()
    trailing.snp.makeConstraints { $0.width.height.equalTo(44) }
    let header = QFTabUI.stack(
      [backButton, headerTitleLabel, trailing], axis: .horizontal, spacing: 4)
    header.alignment = .center
    QFSettingsPageUI.installHeader(header, in: view)
    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = false
    scrollView.keyboardDismissMode = .interactive
    refresh.tintColor = QFUI.primary
    refresh.addAction(UIAction { [weak self] _ in self?.load(force: true) }, for: .valueChanged)
    scrollView.refreshControl = refresh
    view.addSubview(scrollView)
    let footer = QFTabUI.stack([favoriteButton, planButton], axis: .horizontal, spacing: 12)
    footer.distribution = .fillEqually
    footer.backgroundColor = QFUI.background
    view.addSubview(footer)
    footer.snp.makeConstraints {
      $0.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20)
      $0.bottom.equalTo(view.safeAreaLayoutGuide).inset(12)
      $0.height.equalTo(52)
    }
    scrollView.snp.makeConstraints {
      $0.top.equalTo(header.snp.bottom)
      $0.leading.trailing.equalTo(view.safeAreaLayoutGuide)
      $0.bottom.equalTo(footer.snp.top).offset(-8)
    }
    body.axis = .vertical
    body.spacing = 16
    scrollView.addSubview(body)
    body.snp.makeConstraints {
      $0.top.equalTo(scrollView.contentLayoutGuide).offset(8)
      $0.bottom.equalTo(scrollView.contentLayoutGuide).inset(24)
      $0.centerX.equalToSuperview()
      $0.leading.greaterThanOrEqualTo(scrollView.contentLayoutGuide).offset(20)
      $0.trailing.lessThanOrEqualTo(scrollView.contentLayoutGuide).inset(20)
      $0.width.equalTo(scrollView.frameLayoutGuide).offset(-40).priority(999)
      $0.width.lessThanOrEqualTo(620)
    }
    favoriteButton.layer.cornerRadius = 16
    favoriteButton.layer.borderWidth = 0.7
    favoriteButton.layer.borderColor = QFUI.border.cgColor
    favoriteButton.addAction(UIAction { [weak self] _ in self?.toggleFavorite() }, for: .touchUpInside)
    planButton.layer.cornerRadius = 16
    planButton.addAction(UIAction { [weak self] _ in self?.addToPlan() }, for: .touchUpInside)
    planButton.setTitle(app.text("加入计划", "Add to plan"), for: .normal)
    relatedFooter = MJRefreshAutoNormalFooter { [weak self] in self?.loadMoreRelated() }
    relatedFooter.autoTriggerTimes = 1
    relatedFooter.triggerAutomaticallyRefreshPercent = 0.5
    relatedFooter.stateLabel?.font = .preferredFont(forTextStyle: .footnote)
    relatedFooter.stateLabel?.textColor = QFUI.secondary
    relatedFooter.setTitle(app.text("上拉加载更多作品", "Pull up for more works"), for: .idle)
    relatedFooter.setTitle(app.text("加载中…", "Loading…"), for: .refreshing)
    relatedFooter.setTitle(app.text("作品已全部加载", "All works loaded"), for: .noMoreData)
    scrollView.mj_footer = relatedFooter
    relatedFooter.isHidden = true
    applyLanguage()
  }

  private func applyLanguage() {
    guard isViewLoaded else { return }
    headerTitleLabel.text = app.text("菜谱详情", "Recipe")
    backButton?.accessibilityLabel = app.text("返回", "Back")
    relatedFooter?.setTitle(
      app.text("上拉加载更多作品", "Pull up for more works"), for: .idle)
    relatedFooter?.setTitle(app.text("加载中…", "Loading…"), for: .refreshing)
    relatedFooter?.setTitle(app.text("作品已全部加载", "All works loaded"), for: .noMoreData)
    renderDetailOrInitial()
    renderRelated()
  }

  private func renderInitial() {
    guard hasListPreview else {
      headerTitleLabel.text = app.text("菜谱详情", "Recipe details")
      favoriteButton.isEnabled = false; planButton.isEnabled = false
      return
    }
    render(item: initial, contentAvailable: nil, materials: nil, steps: nil)
  }

  private func load(force: Bool) {
    loadTask?.cancel()
    relatedTask?.cancel()
    if detail == nil && !refresh.isRefreshing { hud.show(in: view, text: app.text("加载中", "Loading")) }
    let shouldForce = force || refresh.isRefreshing
    let requestedLanguage = app.interfaceLanguage
    let requestedHouseholdID = app.planningHouseholdID
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        async let detailRequest: QFRecipeHomeDetail = QFContentLoadingContext.$forceRefresh.withValue(shouldForce) {
          try await self.app.publicContentRequest(path: "home/recipes/\(self.recipeID)")
        }
        async let worksRequest: QFContentPage<QFUserWork>? = self.loadFirstRelated(force: shouldForce)
        async let plansRequest: [QFPlannedMeal]? = self.loadPlans(
          force: shouldForce, householdID: requestedHouseholdID)
        let loaded = try await detailRequest
        try Task.checkCancellation()
        guard self.app.interfaceLanguage == requestedLanguage else { return }
        guard UUID(uuidString: loaded.id) == UUID(uuidString: self.recipeID),
          loaded.contentAvailable != true || loaded.contentLanguage == requestedLanguage else { throw URLError(.badServerResponse) }
        self.detail = loaded
        self.hasListPreview = true
        self.favoriteButton.isEnabled = loaded.contentAvailable == true
        self.planButton.isEnabled = loaded.contentAvailable == true
        self.loadedLanguage = loaded.contentLanguage ?? requestedLanguage
        self.initial = loaded.listItem
        self.renderDetail()
        self.onChanged(loaded.listItem)
        if let page = await worksRequest {
          self.related = page.items
          self.relatedTotal = page.total
          self.relatedNextPage = 1
          self.relatedHasMore = !page.items.isEmpty && page.items.count < page.total
          self.renderRelated()
        }
        if let plans = await plansRequest,
          self.app.planningHouseholdID == requestedHouseholdID
        {
          self.plannedMeals = plans
          self.updateEngagementControls(self.detail?.listItem ?? self.initial)
        }
        self.updateRelatedFooter()
        self.refresh.endRefreshing()
        self.hud.hide()
      } catch is CancellationError {
      } catch {
        self.refresh.endRefreshing()
        self.hud.hide()
        if self.detail == nil {
          QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self.view)
        }
      }
    }
  }

  private func loadFirstRelated(force: Bool) async -> QFContentPage<QFUserWork>? {
    do {
      return try await QFContentLoadingContext.$forceRefresh.withValue(force) {
        try await app.publicContentRequest(
          path: "catalog/RECIPE/\(recipeID)/works", query: ["page": "0"])
      }
    } catch { return nil }
  }

  private func loadPlans(force: Bool, householdID: String?) async -> [QFPlannedMeal]? {
    guard app.user != nil else { return [] }
    do {
      let page: QFContentPage<QFPlannedMeal> = try await
        QFContentLoadingContext.$forceRefresh.withValue(force) {
          try await app.plannedMeals(recipeID: recipeID, householdID: householdID)
        }
      return page.items
    } catch is CancellationError {
      return nil
    } catch {
      return nil
    }
  }

  private func reloadPlanState(force: Bool) {
    planTask?.cancel()
    let requestedHouseholdID = app.planningHouseholdID
    planTask = Task { [weak self] in
      guard let self,
        let plans = await self.loadPlans(force: force, householdID: requestedHouseholdID),
        !Task.isCancelled,
        self.app.planningHouseholdID == requestedHouseholdID
      else { return }
      self.plannedMeals = plans
      self.updateEngagementControls(self.detail?.listItem ?? self.initial)
    }
  }

  private func renderDetail() {
    guard let detail else { return }
    render(
      item: detail.listItem, contentAvailable: detail.contentAvailable,
      materials: detail.materials, steps: detail.steps)
  }

#if DEBUG
  /// Inspect the loaded recipe and rendered recipe text, excluding community
  /// posts whose pagination is independent. Never writes or changes UI state.
  func debugRecipeSnapshot() throws -> (data: Data, texts: [String], materials: Int, steps: Int)? {
    guard let detail else { return nil }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    func texts(in view: UIView) -> [String] {
      guard view !== relatedWorks, !view.isHidden else { return [] }
      if let label = view as? UILabel { return label.text.map { [$0] } ?? [] }
      return view.subviews.flatMap { texts(in: $0) }
    }
    return (try encoder.encode(detail), texts(in: body), detail.materials.count,
      detail.cookingSteps.compactMap(Self.visibleStep).count)
  }
#endif

  private func render(
    item: QFRecipeHomeItem, contentAvailable: Bool?, materials: [QFWorkMaterial]?,
    steps: [QFWorkStep]?
  ) {
    let language = app.interfaceLanguage
    body.beginUpdates()
    body.row(
      "hero",
      version: (item.mediaId ?? "fallback") + QFRecipeArtwork.asset(for: item) + language
    ) { [app] in
      QFRecipeHeroView(item: item, app: app)
    }
    body.row("identity", version: item.title + "|" + item.subtitle + "|" + language) { [app] in
      let kind = QFTabUI.label(app.text("收录菜谱", "Catalog recipe"), size: 12, weight: .semibold, color: QFUI.primary)
      let title = QFTabUI.label(item.title, size: 28, weight: .bold, lines: 0)
      let subtitle = QFTabUI.label(item.subtitle, size: 14, color: QFUI.secondary, lines: 0)
      subtitle.isHidden = item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      return QFTabUI.stack([kind, title, subtitle], spacing: 8)
    }
    let factsVersion = [item.countryCodes.joined(separator: ","), item.minutes.map(String.init) ?? "", item.servings.map(String.init) ?? ""].joined(separator: "|")
    if !factsVersion.replacingOccurrences(of: "|", with: "").isEmpty {
      body.row("facts", version: factsVersion + "|" + language) { [app] in
        QFRecipeDetailFacts(item: item, app: app)
      }
    }
    body.row("rating", version: "\(item.ratingAverage ?? -1)|\(item.ratingCount)|\(item.myRating ?? 0)|\(item.favoriteCount)|\(language)") { [weak self] in
      guard let self else { return UIView() }
      return self.makeRatingCard(item)
    }
    if contentAvailable == false {
      body.row("content.unavailable", version: app.interfaceLanguage) { [app] in
        QFTabUI.empty(
          app.text("暂无材料信息", "No ingredient details"),
          detail: app.text("仅展示已经核对的对应语言内容", "Only reviewed content in the selected language is shown"))
      }
    }
    if contentAvailable != false, let materials {
      body.row("materials.title", version: language) { QFTabUI.label(self.app.text("所需材料", "Ingredients"), size: 20, weight: .bold) }
      if materials.isEmpty {
        body.row("materials.empty", version: language) { QFTabUI.empty(self.app.text("暂无材料信息", "No ingredient details"), detail: "") }
      } else {
        for (index, material) in materials.enumerated() {
          body.row("material.\(index)", value: material) {
            let name = QFTabUI.label(material.name, size: 15, lines: 0)
            let amountText = [material.amount, material.unit].filter { !$0.isEmpty }.joined(separator: " ")
            let amount = QFTabUI.label(amountText, size: 14, weight: .medium, color: QFUI.secondary, lines: 0)
            amount.textAlignment = .right
            let row = QFTabUI.stack([name, UIView(), amount], axis: .horizontal, spacing: 12)
            return QFTabUI.card(row, padding: 14, background: QFUI.surface)
          }
        }
      }
    }
    if contentAvailable != false, let steps {
      let projection = QFRecipeDirections.project(steps.map { .init(title: $0.title, body: $0.body) })
      for (index, note) in projection.ingredients.enumerated() {
        body.row("ingredient.note.\(index)", version: note.title + "|" + note.body) {
          QFTabUI.card(QFTabUI.stack([
            QFTabUI.label(note.title, size: 15, weight: .semibold, lines: 0),
            QFTabUI.label(note.body, size: 15, color: QFUI.secondary, lines: 0)
          ], spacing: 7), padding: 14)
        }
      }
      let visibleSteps = projection.actions.map { QFWorkStep(title: $0.title, body: $0.body) }.compactMap(Self.visibleStep)
      if !visibleSteps.isEmpty {
        body.row("steps.title", version: language) { QFTabUI.label(self.app.text("做法步骤", "Directions"), size: 20, weight: .bold) }
        for (index, step) in visibleSteps.enumerated() {
          body.row("step.\(index)", value: step) {
            let number = QFTabUI.label("\(index + 1)", size: 14, weight: .bold, color: QFUI.onPrimary)
            number.textAlignment = .center
            number.backgroundColor = QFUI.primary
            number.layer.cornerRadius = 15
            number.clipsToBounds = true
            number.snp.makeConstraints { $0.width.height.equalTo(30) }
            let stepTitle = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyText = step.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let labels = QFTabUI.stack([
              QFTabUI.label(stepTitle, size: 15, weight: .semibold, lines: 0),
              QFTabUI.label(bodyText, size: 15, color: QFUI.secondary, lines: 0),
            ], spacing: 7)
            labels.arrangedSubviews[0].isHidden = stepTitle.isEmpty
            let row = QFTabUI.stack([number, labels], axis: .horizontal, spacing: 12)
            row.alignment = .top
            return QFTabUI.card(row, padding: 14)
          }
        }
      }
    }
    if contentAvailable != false, let steps {
      let notes = QFRecipeDirections.project(steps.map { .init(title: $0.title, body: $0.body) }).notes
      for (index, note) in notes.enumerated() {
        body.row("recipe.note.\(index)", version: note.title + "|" + note.body) {
          QFTabUI.card(QFTabUI.stack([
            QFTabUI.label(note.title, size: 15, weight: .semibold, lines: 0),
            QFTabUI.label(note.body, size: 15, color: QFUI.secondary, lines: 0)
          ], spacing: 7), padding: 14)
        }
      }
    }
    if materials != nil {
      body.row("related.title", version: language) { [app] in
        QFTabUI.label(app.text("大家的作品", "Community results"), size: 20, weight: .bold)
      }
      body.row("related") { [relatedWorks] in
        relatedWorks.axis = .vertical
        relatedWorks.spacing = 12
        return relatedWorks
      }
    }
    body.endUpdates()
    updateEngagementControls(item)
  }

  private static func visibleStep(_ step: QFWorkStep) -> QFWorkStep? {
    let rawTitle = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = rawTitle.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    let hiddenTitles = [
      "资料来源", "来源原文 · 附加内容", "source, attribution and license",
      "source introduction and credits", "references", "notes, tips, and variations",
      "notes, tips and variations", "note, tips, and variations",
    ]
    if hiddenTitles.contains(where: {
      normalized == $0.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX"))
    }) { return nil }
    var result = step
    for prefix in ["来源原文 · ", "来源原文·"] where result.title.hasPrefix(prefix) {
      result.title.removeFirst(prefix.count)
      break
    }
    return result
  }

  private func makeRatingCard(_ item: QFRecipeHomeItem) -> UIView {
    let average = item.ratingAverage.map {
      QFRecipeFilterState.ratingDisplayString(
        $0, language: QFInterfaceLanguage.normalized(app.interfaceLanguage))
    } ?? "—"
    let count = item.ratingCount > 0
      ? app.format("%d 人评分", "%d ratings", item.ratingCount)
      : app.text("暂无评分", "No ratings yet")
    let averageLabel = QFTabUI.label(average, size: 28, weight: .bold)
    let star = QFTabUI.label("★", size: 21, color: UIColor(hex: 0xE99A22))
    let score = QFTabUI.stack([star, averageLabel], axis: .horizontal, spacing: 6)
    score.alignment = .center
    let labels = QFTabUI.stack([
      score, QFTabUI.label(count, size: 12, color: QFUI.secondary),
      QFTabUI.label(
        app.format("%d 人收藏", "%d favorites", item.favoriteCount),
        size: 12, color: QFUI.secondary),
    ], spacing: 4)
    let rate = QFTabUI.button(
      item.myRating.map { app.format("我的评分 %d", "My rating %d", $0) }
        ?? app.text("给这道菜评分", "Rate this recipe"),
      size: 14, weight: .semibold, color: QFUI.primary, background: QFUI.tint
    ) { [weak self] in self?.openRating() }
    rate.layer.cornerRadius = 14
    rate.snp.makeConstraints { $0.height.greaterThanOrEqualTo(46) }
    let row = QFTabUI.stack([labels, UIView(), rate], axis: .horizontal, spacing: 12)
    row.alignment = .center
    return QFTabUI.card(row, padding: 16, border: true)
  }

  private func renderRelated() {
    let language = app.interfaceLanguage
    relatedWorks.beginUpdates()
    for work in related {
      let version = ((try? JSONEncoder().encode(work).base64EncodedString()) ?? work.id)
        + "|" + language
      relatedWorks.row(work.id, version: version) { [weak self] in
        guard let self else { return UIView() }
        let image = QFContentUI.thumbnail(work.coverMediaId ?? work.photoIds.first, app: self.app, height: 78)
        image.isUserInteractionEnabled = false
        image.snp.makeConstraints { $0.width.equalTo(78) }
        let subtitle = self.app.format("来自 %@", "By %@", work.authorName)
        let labels = QFTabUI.stack([
          QFTabUI.label(work.title, size: 15, weight: .semibold, lines: 2),
          QFTabUI.label(subtitle, size: 12, color: QFUI.secondary),
        ], spacing: 6)
        let row = QFTabUI.stack([image, labels], axis: .horizontal, spacing: 12)
        row.alignment = .center
        let card = QFTabUI.card(row, padding: 10)
        let tap = UITapGestureRecognizer(target: self, action: #selector(self.openRelated(_:)))
        card.addGestureRecognizer(tap)
        card.accessibilityLabel = "\(work.title)，\(subtitle)"
        card.accessibilityHint = self.app.user == nil
          ? self.app.text("登录后查看作品", "Sign in to view")
          : self.app.text("查看作品详情", "View result")
        card.accessibilityTraits = .button
        card.tag = self.related.firstIndex(where: { $0.id == work.id }) ?? 0
        return card
      }
    }
    if related.isEmpty {
      relatedWorks.row("empty", version: language) {
        QFTabUI.empty(self.app.text("还没有关联作品", "No shared results yet"), detail: self.app.text("做完后可以发布你的成果", "Share what you make"))
      }
    }
    relatedWorks.endUpdates()
  }

  @objc private func openRelated(_ gesture: UITapGestureRecognizer) {
    guard let index = gesture.view?.tag, related.indices.contains(index) else { return }
    let work = related[index]
    requireLogin { [weak self] in
      guard let self else { return }
      self.qfPush(QFWorkDetailViewController(app: self.app, workID: work.id))
    }
  }

  private func loadMoreRelated() {
    guard relatedHasMore, relatedTask == nil else { relatedFooter.endRefreshing(); return }
    let page = relatedNextPage
    relatedTask = Task { [weak self] in
      guard let self else { return }
      defer { self.relatedTask = nil }
      do {
        let response: QFContentPage<QFUserWork> = try await self.app.publicContentRequest(
          path: "catalog/RECIPE/\(self.recipeID)/works", query: ["page": String(page)])
        var ids = Set(self.related.map(\.id))
        let oldCount = self.related.count
        for work in response.items where ids.insert(work.id).inserted { self.related.append(work) }
        self.relatedTotal = response.total
        self.relatedNextPage = page + 1
        self.relatedHasMore = self.related.count > oldCount && self.related.count < response.total
        self.renderRelated()
        self.updateRelatedFooter()
      } catch is CancellationError {
      } catch {
        await self.relatedFooter.endRefreshing()
        self.relatedFooter.setTitle(self.app.text("加载失败，上拉重试", "Pull up to retry"), for: .idle)
      }
    }
  }

  private func updateRelatedFooter() {
    relatedFooter.resetNoMoreData()
    relatedFooter.isHidden = !relatedHasMore
    relatedFooter.isAutomaticallyRefresh = relatedHasMore
    relatedFooter.endRefreshing()
  }

  private func updateEngagementControls(_ item: QFRecipeHomeItem) {
    let title = item.isFavorite
      ? app.text("取消收藏", "Unfavorite") : app.text("收藏", "Favorite")
    favoriteButton.setTitle(title, for: .normal)
    favoriteButton.setImage(
      UIImage(systemName: item.isFavorite ? "bookmark.fill" : "bookmark"), for: .normal)
    favoriteButton.tintColor = QFUI.primary
    favoriteButton.accessibilityValue = app.format(
      "%d 人收藏", "%d favorites", item.favoriteCount)
    let planned = !plannedMeals.isEmpty
    planButton.setTitle(
      planned ? app.text("已加入计划", "Planned") : app.text("加入计划", "Add to plan"),
      for: .normal)
    planButton.setImage(
      UIImage(systemName: planned ? "checkmark.circle.fill" : "calendar.badge.plus"),
      for: .normal)
    planButton.tintColor = planned ? QFUI.primary : QFUI.onPrimary
    planButton.setTitleColor(planned ? QFUI.primary : QFUI.onPrimary, for: .normal)
    planButton.backgroundColor = planned ? QFUI.tint : QFUI.primary
    planButton.layer.borderWidth = planned ? 1 : 0
    planButton.layer.borderColor = planned ? QFUI.primary.cgColor : UIColor.clear.cgColor
    planButton.accessibilityHint = planned
      ? app.text("轻点选择要取消的计划", "Choose a plan to remove")
      : app.text("轻点选择日期和餐次", "Choose a date and meal")
  }

  private func toggleFavorite() {
    requireLogin { [weak self] in self?.performFavoriteToggle() }
  }

  private func performFavoriteToggle() {
    guard mutationTask == nil else { return }
    var item = detail?.listItem ?? initial
    let previous = item
    item.isFavorite.toggle()
    item.favoriteCount = max(0, item.favoriteCount + (item.isFavorite ? 1 : -1))
    applyLocal(item)
    favoriteButton.isEnabled = false
    mutationTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.app.contentMutation(
          path: "me/favorites/RECIPE/\(self.recipeID)", method: item.isFavorite ? "PUT" : "DELETE")
      } catch is CancellationError {
        self.applyLocal(previous)
      } catch {
        self.applyLocal(previous)
        QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self.view)
      }
      self.favoriteButton.isEnabled = true
      self.mutationTask = nil
    }
  }

  private func openRating() {
    requireLogin { [weak self] in
      guard let self else { return }
      let current = self.detail?.myRating ?? self.initial.myRating
      self.present(
        QFRecipeRatingPickerViewController(app: self.app, selected: current) { [weak self] value in
          self?.saveRating(value)
        }, animated: true)
    }
  }

  private func saveRating(_ value: Int?) {
    guard mutationTask == nil else { return }
    hud.show(in: view, text: app.text("保存评分", "Saving rating"))
    mutationTask = Task { [weak self] in
      guard let self else { return }
      defer { self.hud.hide(); self.mutationTask = nil }
      do {
        let engagement: QFRecipeEngagement
        if let value {
          engagement = try await self.app.contentRequest(
            path: "me/recipe-ratings/\(self.recipeID)", method: "PUT",
            body: JSONEncoder().encode(QFRecipeRatingRequest(rating: value)))
        } else {
          engagement = try await self.app.contentRequest(
            path: "me/recipe-ratings/\(self.recipeID)", method: "DELETE")
        }
        var item = self.detail?.listItem ?? self.initial
        item.apply(engagement)
        self.applyLocal(item)
      } catch is CancellationError {
      } catch {
        QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self.view)
      }
    }
  }

  private func applyLocal(_ item: QFRecipeHomeItem) {
    initial = item
    if var value = detail {
      value.favoriteCount = item.favoriteCount
      value.ratingAverage = item.ratingAverage
      value.ratingCount = item.ratingCount
      value.isFavorite = item.isFavorite
      value.myRating = item.myRating
      detail = value
    }
    renderDetailOrInitial()
    onChanged(item)
  }

  private func renderDetailOrInitial() {
    if detail != nil { renderDetail() } else { renderInitial() }
  }

  private func addToPlan() {
    requireLogin { [weak self] in
      guard let self else { return }
      if self.plannedMeals.isEmpty {
        self.qfPush(
          QFAddRecipePlanViewController(app: self.app, recipeID: self.recipeID) {
            [weak self] meal in
            guard let self else { return }
            self.plannedMeals.removeAll { $0.id == meal.id }
            self.plannedMeals.append(meal)
            self.updateEngagementControls(self.detail?.listItem ?? self.initial)
          })
      } else {
        self.choosePlanToRemove()
      }
    }
  }

  private func choosePlanToRemove() {
    guard !plannedMeals.isEmpty else { return }
    let controller = UIAlertController(
      title: app.text("选择要取消的计划", "Choose a plan to remove"),
      message: nil, preferredStyle: plannedMeals.count == 1 ? .alert : .actionSheet)
    for meal in plannedMeals {
      controller.addAction(UIAlertAction(title: planDescription(meal), style: .destructive) {
        [weak self] _ in self?.removePlan(meal)
      })
    }
    controller.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    if let popover = controller.popoverPresentationController {
      popover.sourceView = planButton
      popover.sourceRect = planButton.bounds
    }
    present(controller, animated: true)
  }

  private func planDescription(_ meal: QFPlannedMeal) -> String {
    let mealName = QFCookingMeal(rawValue: meal.meal)?.title(app: app) ?? meal.meal
    return "\(meal.date) · \(mealName) · \(app.format("%d 份", "%d servings", meal.servings))"
  }

  private func removePlan(_ meal: QFPlannedMeal) {
    guard mutationTask == nil else { return }
    hud.show(in: view, text: app.text("取消计划", "Removing plan"))
    planButton.isEnabled = false
    mutationTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.hud.hide()
        self.planButton.isEnabled = true
        self.mutationTask = nil
      }
      do {
        try await self.app.deletePlannedMeal(meal.id, expectedRevision: meal.revision)
        self.plannedMeals.removeAll { $0.id == meal.id }
        self.updateEngagementControls(self.detail?.listItem ?? self.initial)
        QFOperationHUD.toast(self.app.text("计划已取消", "Plan removed"), in: self.view)
      } catch is CancellationError {
      } catch {
        QFOperationHUD.toast(
          QFProfileContentController.errorText(error, app: self.app), in: self.view)
      }
    }
  }

  private func requireLogin(_ action: @escaping () -> Void) {
    guard app.user == nil else { action(); return }
    weak var login: QFLoginViewController?
    let controller = QFLoginViewController(app: app) { [weak self] in
      guard let self, self.app.user != nil,
        self.navigationController?.topViewController === login
      else { return }
      login?.qfClose { [weak self] in self?.refreshPersonalizationThen(action) }
    }
    login = controller
    qfPush(controller)
  }

  private func refreshPersonalizationThen(_ action: @escaping () -> Void) {
    loadTask?.cancel()
    let requestedLanguage = app.interfaceLanguage
    let requestedHouseholdID = app.planningHouseholdID
    hud.show(in: view, text: app.text("更新菜谱状态", "Updating recipe"))
    loadTask = Task { [weak self] in
      guard let self else { return }
      defer { self.hud.hide() }
      do {
        async let detailRequest: QFRecipeHomeDetail = QFContentLoadingContext.$forceRefresh
          .withValue(true) {
            try await self.app.publicContentRequest(path: "home/recipes/\(self.recipeID)")
          }
        async let plansRequest: [QFPlannedMeal]? = self.loadPlans(
          force: true, householdID: requestedHouseholdID)
        let loaded = try await detailRequest
        let plans = await plansRequest
        try Task.checkCancellation()
        guard self.app.interfaceLanguage == requestedLanguage,
          self.app.planningHouseholdID == requestedHouseholdID,
          let plans
        else { return }
        self.detail = loaded
        self.initial = loaded.listItem
        self.loadedLanguage = loaded.contentLanguage ?? requestedLanguage
        self.plannedMeals = plans
        self.renderDetail()
        self.onChanged(loaded.listItem)
        action()
      } catch is CancellationError {
      } catch {
        QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self.view)
      }
    }
  }
}

@MainActor
private final class QFRecipeHeroView: UIView {
  init(item: QFRecipeHomeItem, app: QFAppSession) {
    super.init(frame: .zero)
    backgroundColor = QFUI.tint
    layer.cornerRadius = 20
    layer.cornerCurve = .continuous
    clipsToBounds = true
    if let mediaID = item.mediaId {
      let image = QFContentImageView()
      image.load(mediaID, app: app)
      addSubview(image)
      image.snp.makeConstraints { $0.edges.equalToSuperview() }
    } else {
      let image = UIImageView(image: UIImage(named: QFRecipeArtwork.asset(for: item)))
      image.contentMode = .scaleAspectFill
      image.accessibilityLabel = app.text("菜谱分类插画", "Recipe illustration")
      addSubview(image)
      image.snp.makeConstraints { $0.edges.equalToSuperview() }
      let badge = QFTabUI.label(app.text("插画", "Illustration"), size: 11, weight: .semibold, color: QFUI.onTint)
      badge.textAlignment = .center
      badge.backgroundColor = QFUI.tint.withAlphaComponent(0.94)
      badge.layer.cornerRadius = 11
      badge.clipsToBounds = true
      addSubview(badge)
      badge.snp.makeConstraints { $0.trailing.bottom.equalToSuperview().inset(12); $0.width.equalTo(48); $0.height.equalTo(24) }
    }
    snp.makeConstraints { $0.height.equalTo(230) }
  }
  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class QFRecipeDetailFacts: UIView {
  init(item: QFRecipeHomeItem, app: QFAppSession) {
    super.init(frame: .zero)
    let locale = Locale(
      identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    // Keep time and servings visible even when a recipe is associated with several regions.
    var facts: [(String, String)] = item.countryCodes.prefix(1).map {
      ("globe.asia.australia", locale.localizedString(forRegionCode: $0) ?? $0)
    }
    if let minutes = item.minutes {
      facts.append(("clock", app.format("%d 分钟", "%d min", minutes)))
    }
    if let servings = item.servings {
      facts.append(("person.2", app.format("%d 人份", "Serves %d", servings)))
    }
    let stack = QFTabUI.stack([], axis: .horizontal, spacing: 8)
    stack.distribution = .fillEqually
    for (symbol, text) in facts.prefix(3) {
      let icon = QFTabUI.symbol(symbol, size: 15, color: QFUI.primary)
      let label = QFTabUI.label(text, size: 12, weight: .medium, lines: 2)
      label.textAlignment = .center
      let itemStack = QFTabUI.stack([icon, label], spacing: 7)
      itemStack.alignment = .center
      stack.addArrangedSubview(QFTabUI.card(itemStack, padding: 12, background: QFUI.surfaceAlt))
    }
    addSubview(stack)
    stack.snp.makeConstraints { $0.edges.equalToSuperview() }
  }
  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class QFRecipeRatingPickerViewController: UIViewController {
  private let app: QFAppSession
  private let original: Int?
  private let selection: (Int?) -> Void
  private var selected: Int?
  private var starButtons: [UIButton] = []
  private let valueLabel = QFTabUI.label("", size: 16, weight: .semibold)

  init(app: QFAppSession, selected: Int?, selection: @escaping (Int?) -> Void) {
    self.app = app
    original = selected
    self.selected = selected
    self.selection = selection
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
  }
  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    let title = QFTabUI.label(app.text("给这道菜评分", "Rate this recipe"), size: 20, weight: .semibold)
    title.textAlignment = .center
    let close = QFTabUI.iconButton("xmark", label: app.text("关闭", "Close"), size: 17) { [weak self] in self?.dismiss(animated: true) }
    let spacer = UIView(); spacer.snp.makeConstraints { $0.size.equalTo(44) }
    let header = QFTabUI.stack([spacer, title, close], axis: .horizontal, spacing: 4)
    header.alignment = .center
    view.addSubview(header)
    header.snp.makeConstraints { $0.top.equalTo(view.safeAreaLayoutGuide).offset(8); $0.leading.trailing.equalToSuperview().inset(16); $0.height.equalTo(48) }
    let stars = QFTabUI.stack([], axis: .horizontal, spacing: 7)
    stars.distribution = .fillEqually
    for value in 1...5 {
      let button = QFTabUI.iconButton(
        "star", label: app.format("%d 星", "%d stars", value), size: 29
      ) { [weak self] in
        self?.selected = value
        self?.render()
      }
      button.tintColor = UIColor(hex: 0xE99A22)
      button.tag = value
      button.snp.remakeConstraints { $0.width.height.equalTo(52) }
      stars.addArrangedSubview(button)
      starButtons.append(button)
    }
    valueLabel.textAlignment = .center
    let content = QFTabUI.stack([stars, valueLabel], spacing: 16)
    view.addSubview(content)
    content.snp.makeConstraints { $0.top.equalTo(header.snp.bottom).offset(28); $0.leading.trailing.equalToSuperview().inset(28) }
    let remove = QFTabUI.button(app.text("删除评分", "Remove rating"), size: 15, weight: .semibold, color: QFUI.danger, background: QFUI.surface) { [weak self] in
      guard let self else { return }
      self.dismiss(animated: true) { self.selection(nil) }
    }
    remove.isHidden = original == nil
    let confirm = QFTabUI.button(app.text("保存评分", "Save rating"), size: 16, weight: .semibold, color: QFUI.onPrimary, background: QFUI.primary) { [weak self] in
      guard let self, let value = self.selected else { return }
      self.dismiss(animated: true) { self.selection(value) }
    }
    for button in [remove, confirm] { button.layer.cornerRadius = 15; button.snp.makeConstraints { $0.height.equalTo(50) } }
    let footer = QFTabUI.stack([remove, confirm], axis: .horizontal, spacing: 12)
    footer.distribution = .fillEqually
    view.addSubview(footer)
    footer.snp.makeConstraints { $0.leading.trailing.equalToSuperview().inset(20); $0.bottom.equalTo(view.safeAreaLayoutGuide).inset(12) }
    if let sheet = sheetPresentationController {
      sheet.detents = [.medium()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 24
    }
    render()
  }

  private func render() {
    for button in starButtons {
      let filled = button.tag <= (selected ?? 0)
      button.setImage(
        UIImage(
          systemName: filled ? "star.fill" : "star",
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 29, weight: .semibold)),
        for: .normal)
      button.accessibilityTraits = button.tag == selected ? [.button, .selected] : [.button]
    }
    valueLabel.text = selected.map { app.format("%d 星", "%d stars", $0) }
      ?? app.text("请选择 1–5 星", "Choose 1–5 stars")
  }
}
