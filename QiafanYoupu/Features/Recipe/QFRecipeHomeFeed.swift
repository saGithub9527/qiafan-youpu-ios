import MJRefresh
import SnapKit
import UIKit

@MainActor
final class QFRecipeCardCell: UITableViewCell {
  static let reuseIdentifier = "recipe-home-card"

  private let card = UIView()
  private let fallbackImage = UIImageView()
  private let remoteImage = QFContentImageView()
  private let titleLabel = QFTabUI.label("", size: 16, weight: .semibold, lines: 2)
  private let subtitleLabel = QFTabUI.label("", size: 11, color: QFUI.secondary, lines: 2)
  private let factsLabel = QFTabUI.label("", size: 11, color: QFUI.secondary, lines: 2)
  private let ratingLabel = QFTabUI.label("", size: 12, weight: .semibold)
  private let favoriteCountLabel = QFTabUI.label("", size: 10.5, color: QFUI.secondary)
  private let favoriteButton = UIButton(type: .system)
  private var favoriteAction: (() -> Void)?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none
    contentView.backgroundColor = .clear
    card.backgroundColor = QFUI.surface
    card.layer.cornerRadius = QFRecipeHomeLayout.cardCornerRadius
    card.layer.cornerCurve = .continuous
    contentView.addSubview(card)
    card.snp.makeConstraints {
      $0.top.equalToSuperview()
      $0.bottom.equalToSuperview().inset(QFRecipeHomeLayout.cardGap)
      $0.centerX.equalToSuperview()
      $0.leading.greaterThanOrEqualToSuperview().offset(QFRecipeHomeLayout.pageHorizontalInset)
      $0.trailing.lessThanOrEqualToSuperview().inset(QFRecipeHomeLayout.pageHorizontalInset)
      $0.width.equalToSuperview().offset(-2 * QFRecipeHomeLayout.pageHorizontalInset).priority(999)
      $0.width.lessThanOrEqualTo(620)
      $0.height.greaterThanOrEqualTo(QFRecipeHomeLayout.cardMinimumHeight)
    }

    fallbackImage.contentMode = .scaleAspectFill
    fallbackImage.clipsToBounds = true
    fallbackImage.layer.cornerRadius = 12
    fallbackImage.layer.cornerCurve = .continuous
    fallbackImage.backgroundColor = QFUI.tint
    remoteImage.clipsToBounds = true
    remoteImage.layer.cornerRadius = 12
    remoteImage.layer.cornerCurve = .continuous
    remoteImage.isUserInteractionEnabled = false
    card.addSubview(fallbackImage)
    card.addSubview(remoteImage)
    fallbackImage.snp.makeConstraints {
      $0.leading.top.equalToSuperview().inset(10)
      $0.size.equalTo(QFRecipeHomeLayout.cardImageSize)
      $0.bottom.lessThanOrEqualToSuperview().inset(10)
    }
    remoteImage.snp.makeConstraints { $0.edges.equalTo(fallbackImage) }

    favoriteButton.tintColor = QFUI.primary
    favoriteButton.contentHorizontalAlignment = .center
    favoriteButton.contentVerticalAlignment = .center
    favoriteButton.addAction(UIAction { [weak self] _ in self?.favoriteAction?() }, for: .touchUpInside)
    favoriteButton.snp.makeConstraints { $0.size.equalTo(44) }
    card.addSubview(favoriteButton)
    favoriteButton.snp.makeConstraints {
      $0.top.equalToSuperview().offset(2)
      $0.trailing.equalToSuperview().inset(3)
    }

    let star = UIImageView(
      image: UIImage(
        systemName: "star.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
    star.tintColor = UIColor(hex: 0xE99A22)
    star.setContentHuggingPriority(.required, for: .horizontal)
    let ratingRow = QFTabUI.stack(
      [star, ratingLabel, UIView(), favoriteCountLabel], axis: .horizontal, spacing: 5)
    ratingRow.alignment = .center
    let text = QFTabUI.stack([titleLabel, subtitleLabel, factsLabel, ratingRow], spacing: 7)
    card.addSubview(text)
    text.snp.makeConstraints {
      $0.leading.equalTo(fallbackImage.snp.trailing).offset(14)
      $0.trailing.equalToSuperview().inset(14)
      $0.top.bottom.equalToSuperview().inset(14)
    }
    titleLabel.snp.makeConstraints { $0.trailing.lessThanOrEqualTo(favoriteButton.snp.leading).offset(-4) }
  }

  required init?(coder: NSCoder) { nil }

  func configure(
    _ item: QFRecipeHomeItem, app: QFAppSession, favoriteEnabled: Bool,
    onFavorite: @escaping () -> Void
  ) {
    titleLabel.text = item.title
    let locale = Locale(
      identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    let countries = item.countryCodes.prefix(2).map {
      locale.localizedString(forRegionCode: $0) ?? $0
    }
    let subtitleParts = countries + [item.subtitle].filter {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    subtitleLabel.text = subtitleParts.joined(separator: " · ")
    subtitleLabel.isHidden = subtitleParts.isEmpty
    var facts: [String] = []
    if let minutes = item.minutes { facts.append(app.format("%d 分钟", "%d min", minutes)) }
    if let servings = item.servings { facts.append(app.format("%d 人份", "Serves %d", servings)) }
    factsLabel.text = facts.joined(separator: " · ")
    factsLabel.isHidden = facts.isEmpty
    if let rating = item.ratingAverage, item.ratingCount > 0 {
      ratingLabel.text = String(
        format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rating)
    } else {
      ratingLabel.text = app.text("暂无评分", "No ratings yet")
    }
    let countFormatter = NumberFormatter()
    countFormatter.numberStyle = .decimal
    countFormatter.locale = Locale(
      identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    let favoriteCount = countFormatter.string(from: NSNumber(value: item.favoriteCount))
      ?? String(item.favoriteCount)
    favoriteCountLabel.text = app.format("%@ 收藏", "%@ favorites", favoriteCount)
    let symbol = item.isFavorite ? "bookmark.fill" : "bookmark"
    favoriteButton.setImage(
      UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)),
      for: .normal)
    favoriteButton.tintColor = item.isFavorite ? QFUI.primary : QFUI.secondary
    favoriteButton.accessibilityLabel = item.isFavorite
      ? app.format("取消收藏 %@", "Remove %@ from favorites", item.title)
      : app.format("收藏 %@", "Favorite %@", item.title)
    favoriteButton.accessibilityValue = favoriteCountLabel.text
    favoriteButton.isEnabled = favoriteEnabled
    favoriteButton.alpha = favoriteEnabled ? 1 : 0.45
    favoriteAction = onFavorite
    fallbackImage.image = UIImage(named: QFRecipeArtwork.asset(for: item))
    remoteImage.isHidden = item.mediaId == nil
    if let mediaID = item.mediaId { remoteImage.load(mediaID, app: app) }
    accessibilityLabel = [
      item.title, subtitleLabel.isHidden ? nil : subtitleLabel.text, factsLabel.text,
      ratingLabel.text, favoriteCountLabel.text,
    ]
      .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "，")
    accessibilityHint = app.text("轻点查看菜谱详情", "Double tap for recipe details")
    accessibilityTraits = .button
  }
}

@MainActor
private final class QFRecipeFeedLoadingView: UIView {
  init(app: QFAppSession) {
    super.init(frame: .zero)
    backgroundColor = QFUI.background
    isAccessibilityElement = true
    accessibilityLabel = app.text("加载中", "Loading")
    accessibilityTraits = [.staticText, .updatesFrequently]

    let rows = QFUI.stack([], spacing: QFRecipeHomeLayout.cardGap)
    addSubview(rows)
    rows.snp.makeConstraints {
      $0.top.equalToSuperview()
      $0.leading.trailing.equalToSuperview().inset(QFRecipeHomeLayout.pageHorizontalInset)
    }
    for _ in 0..<3 { rows.addArrangedSubview(Self.makeRow()) }
  }

  required init?(coder: NSCoder) { nil }

  private static func makeRow() -> UIView {
    let tint = QFUI.border.withAlphaComponent(0.72)
    let card = UIView()
    card.backgroundColor = QFUI.surface
    card.layer.cornerRadius = QFRecipeHomeLayout.cardCornerRadius
    card.snp.makeConstraints { $0.height.equalTo(QFRecipeHomeLayout.cardMinimumHeight) }

    let image = UIView()
    image.backgroundColor = tint
    image.layer.cornerRadius = 12
    let title = UIView()
    title.backgroundColor = tint
    title.layer.cornerRadius = 5
    let subtitle = UIView()
    subtitle.backgroundColor = tint.withAlphaComponent(0.74)
    subtitle.layer.cornerRadius = 4
    let facts = UIView()
    facts.backgroundColor = tint.withAlphaComponent(0.6)
    facts.layer.cornerRadius = 4
    let copy = QFUI.stack([title, subtitle, facts], spacing: 12)
    copy.alignment = .leading

    card.addSubview(image)
    card.addSubview(copy)
    image.snp.makeConstraints {
      $0.leading.top.equalToSuperview().inset(10)
      $0.size.equalTo(QFRecipeHomeLayout.cardImageSize)
      $0.bottom.lessThanOrEqualToSuperview().inset(10)
    }
    copy.snp.makeConstraints {
      $0.leading.equalTo(image.snp.trailing).offset(14)
      $0.trailing.equalToSuperview().inset(16)
      $0.centerY.equalToSuperview()
    }
    title.snp.makeConstraints { $0.height.equalTo(16); $0.width.equalToSuperview().multipliedBy(0.78) }
    subtitle.snp.makeConstraints { $0.height.equalTo(11); $0.width.equalToSuperview().multipliedBy(0.92) }
    facts.snp.makeConstraints { $0.height.equalTo(10); $0.width.equalToSuperview().multipliedBy(0.58) }
    return card
  }
}

@MainActor
private final class QFRecipeFeedStateView: UIView {
  private let symbolView = UIImageView()
  private let titleLabel = QFTabUI.label("", size: 17, weight: .semibold, lines: 0)
  private let detailLabel = QFTabUI.label("", size: 13, color: QFUI.secondary, lines: 0)
  private let retryButton = UIButton(type: .system)
  private var retryAction: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = QFUI.background
    symbolView.contentMode = .scaleAspectFit
    symbolView.tintColor = QFUI.secondary
    symbolView.isAccessibilityElement = false
    titleLabel.textAlignment = .center
    detailLabel.textAlignment = .center

    var configuration = UIButton.Configuration.filled()
    configuration.baseBackgroundColor = QFUI.primary
    configuration.baseForegroundColor = QFUI.onPrimary
    configuration.cornerStyle = .large
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 22, bottom: 11, trailing: 22)
    retryButton.configuration = configuration
    retryButton.addAction(UIAction { [weak self] _ in self?.retryAction?() }, for: .touchUpInside)
    retryButton.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }

    let stack = QFUI.stack([symbolView, titleLabel, detailLabel, retryButton], spacing: 12)
    stack.alignment = .center
    setCustomSpacing(18, after: symbolView, in: stack)
    addSubview(stack)
    stack.snp.makeConstraints {
      $0.centerY.equalToSuperview().offset(-24)
      $0.centerX.equalToSuperview()
      $0.leading.greaterThanOrEqualToSuperview().offset(28)
      $0.trailing.lessThanOrEqualToSuperview().inset(28)
      $0.width.lessThanOrEqualTo(340)
    }
    symbolView.snp.makeConstraints { $0.size.equalTo(42) }
  }

  required init?(coder: NSCoder) { nil }

  func configure(
    symbol: String, title: String, detail: String, retryTitle: String? = nil,
    retry: (() -> Void)? = nil
  ) {
    symbolView.image = UIImage(
      systemName: symbol,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .regular))
    titleLabel.text = title
    detailLabel.text = detail
    detailLabel.isHidden = detail.isEmpty
    retryAction = retry
    retryButton.configuration?.title = retryTitle
    retryButton.isHidden = retryTitle == nil || retry == nil
    accessibilityLabel = [title, detail].filter { !$0.isEmpty }.joined(separator: "，")
  }

  private func setCustomSpacing(_ spacing: CGFloat, after view: UIView, in stack: UIStackView) {
    stack.setCustomSpacing(spacing, after: view)
  }
}

@MainActor
final class QFRecipeFeedView: UIView, UITableViewDelegate {
  let tableView = UITableView(frame: .zero, style: .plain)
  private let app: QFAppSession
  private lazy var loadingView = QFRecipeFeedLoadingView(app: app)
  private let stateView = QFRecipeFeedStateView()
  private let refresh = UIRefreshControl()
  private var footer: MJRefreshAutoNormalFooter!
  private var dataSource: UITableViewDiffableDataSource<Int, String>!
  private var itemsByID: [String: QFRecipeHomeItem] = [:]
  private var busyFavoriteIDs = Set<String>()
  var onRefresh: (() -> Void)?
  var onLoadMore: (() -> Void)?
  var onOpen: ((QFRecipeHomeItem) -> Void)?
  var onFavorite: ((QFRecipeHomeItem) -> Void)?
  var onRetry: (() -> Void)?

  init(app: QFAppSession) {
    self.app = app
    super.init(frame: .zero)
    tableView.backgroundColor = QFUI.background
    tableView.separatorStyle = .none
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = QFRecipeHomeLayout.cardMinimumHeight + QFRecipeHomeLayout.cardGap
    tableView.sectionHeaderTopPadding = 0
    tableView.alwaysBounceVertical = true
    tableView.keyboardDismissMode = .interactive
    tableView.delegate = self
    tableView.register(QFRecipeCardCell.self, forCellReuseIdentifier: QFRecipeCardCell.reuseIdentifier)
    addSubview(tableView)
    tableView.snp.makeConstraints { $0.edges.equalToSuperview() }
    refresh.tintColor = QFUI.primary
    refresh.addAction(UIAction { [weak self] _ in self?.onRefresh?() }, for: .valueChanged)
    tableView.refreshControl = refresh
    dataSource = UITableViewDiffableDataSource<Int, String>(tableView: tableView) {
      [weak self] table, indexPath, id in
      guard let self, let item = self.itemsByID[id],
        let cell = table.dequeueReusableCell(
          withIdentifier: QFRecipeCardCell.reuseIdentifier, for: indexPath) as? QFRecipeCardCell
      else { return nil }
      cell.configure(
        item, app: self.app, favoriteEnabled: !self.busyFavoriteIDs.contains(id)
      ) { [weak self] in
        guard let self, let latest = self.itemsByID[id] else { return }
        self.onFavorite?(latest)
      }
      return cell
    }
    footer = MJRefreshAutoNormalFooter { [weak self] in self?.onLoadMore?() }
    footer.autoTriggerTimes = 1
    footer.triggerAutomaticallyRefreshPercent = 0.45
    footer.stateLabel?.font = .preferredFont(forTextStyle: .footnote)
    footer.stateLabel?.textColor = QFUI.secondary
    footer.setTitle(app.text("上拉加载更多", "Pull up for more"), for: .idle)
    footer.setTitle(app.text("加载中…", "Loading…"), for: .refreshing)
    footer.setTitle(app.text("已全部加载", "All loaded"), for: .noMoreData)
    tableView.mj_footer = footer
    footer.isHidden = true
  }

  required init?(coder: NSCoder) { nil }

  var isRefreshing: Bool { refresh.isRefreshing }
  var items: [QFRecipeHomeItem] { dataSource.snapshot().itemIdentifiers.compactMap { itemsByID[$0] } }

  func apply(_ items: [QFRecipeHomeItem], emptyText: String) {
    let previous = dataSource.snapshot()
    let previousIDs = Set(previous.itemIdentifiers)
    let changed = items.compactMap { item -> String? in
      guard previousIDs.contains(item.id), itemsByID[item.id] != item else { return nil }
      return item.id
    }
    itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
    snapshot.appendSections([0])
    snapshot.appendItems(items.map(\.id))
    snapshot.reconfigureItems(changed)
    dataSource.apply(snapshot, animatingDifferences: false)
    if items.isEmpty {
      stateView.configure(symbol: "fork.knife", title: emptyText, detail: "")
      tableView.backgroundView = stateView
    } else {
      tableView.backgroundView = nil
    }
  }

  func showLoading(clearingContent: Bool = false) {
    if clearingContent {
      itemsByID.removeAll()
      var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
      snapshot.appendSections([0])
      dataSource.apply(snapshot, animatingDifferences: false)
    }
    guard itemsByID.isEmpty else { return }
    tableView.backgroundView = loadingView
  }

  func showFailure() {
    guard itemsByID.isEmpty else { return }
    stateView.configure(
      symbol: "exclamationmark.triangle",
      title: app.text("加载失败", "Could not load"),
      detail: app.text(
        "服务暂时不可用，请稍后重试。",
        "The service is temporarily unavailable. Please try again later."),
      retryTitle: app.text("重试", "Retry"), retry: { [weak self] in self?.onRetry?() })
    tableView.backgroundView = stateView
  }

  func reconfigure(_ item: QFRecipeHomeItem) {
    guard dataSource.snapshot().indexOfItem(item.id) != nil else { return }
    itemsByID[item.id] = item
    var snapshot = dataSource.snapshot()
    snapshot.reconfigureItems([item.id])
    dataSource.apply(snapshot, animatingDifferences: false)
  }

  func setFavoriteBusy(_ busy: Bool, id: String) {
    if busy { busyFavoriteIDs.insert(id) } else { busyFavoriteIDs.remove(id) }
    guard dataSource.snapshot().indexOfItem(id) != nil else { return }
    var snapshot = dataSource.snapshot()
    snapshot.reconfigureItems([id])
    dataSource.apply(snapshot, animatingDifferences: false)
  }

  func finishRefresh() { refresh.endRefreshing() }

  func updateFooter(hasMore: Bool, loading: Bool, failed: Bool = false) {
    footer.resetNoMoreData()
    footer.isHidden = !hasMore && !loading && !failed
    footer.isAutomaticallyRefresh = hasMore && !loading && !failed
    if loading { return }
    footer.endRefreshing()
    if failed {
      footer.setTitle(app.text("加载失败，上拉重试", "Pull up to retry"), for: .idle)
      footer.isHidden = false
      footer.isAutomaticallyRefresh = true
    } else if hasMore {
      footer.setTitle(app.text("上拉加载更多", "Pull up for more"), for: .idle)
    } else if !itemsByID.isEmpty {
      footer.endRefreshingWithNoMoreData()
    }
  }

  func scrollToTop() {
    guard !dataSource.snapshot().itemIdentifiers.isEmpty else { return }
    tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard let id = dataSource.itemIdentifier(for: indexPath), let item = itemsByID[id] else { return }
    onOpen?(item)
  }
}

@MainActor
class QFRecipeFeedViewController: UIViewController {
  private struct FirstPageSnapshot: Codable {
    let storedAt: Date
    let items: [QFRecipeHomeItem]
    let total: Int
  }

  private static let firstPageSnapshotTTL: TimeInterval = 86_400
  let app: QFAppSession
  let feed: QFRecipeFeedView
  private let hud = QFOperationHUD()
  private var requestTask: Task<Void, Never>?
  private var favoriteTasks: [String: Task<Void, Never>] = [:]
  private var requestID = UUID()
  private var refreshAfterAuthenticatedAction = false
  private(set) var recipes: [QFRecipeHomeItem] = []
  private(set) var total = 0
  private(set) var nextPage = 0
  private(set) var hasMore = false
  private(set) var currentQuery: [String: String] = [:]
  private var loadingMore = false

  init(app: QFAppSession) {
    self.app = app
    feed = QFRecipeFeedView(app: app)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    requestTask?.cancel()
    favoriteTasks.values.forEach { $0.cancel() }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    feed.onRefresh = { [weak self] in self?.reloadCurrent(force: true) }
    feed.onLoadMore = { [weak self] in self?.loadMore() }
    feed.onOpen = { [weak self] item in self?.openRecipe(item) }
    feed.onFavorite = { [weak self] item in self?.toggleFavorite(item) }
    feed.onRetry = { [weak self] in self?.reloadCurrent(force: true) }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isMovingFromParent || isBeingDismissed { requestTask?.cancel(); hud.hide() }
  }

  func installFeed(below topView: UIView) {
    view.addSubview(feed)
    feed.snp.makeConstraints {
      $0.top.equalTo(topView.snp.bottom)
      $0.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
    }
  }

  func installFeedToFillView() {
    view.addSubview(feed)
    feed.snp.makeConstraints { $0.edges.equalToSuperview() }
  }

  func requestRecipes(
    query: [String: String], resetScroll: Bool = false, force: Bool = false,
    showProgress: Bool = false
  ) {
    requestTask?.cancel()
    requestID = UUID()
    let id = requestID
    let oldQuery = currentQuery
    loadingMore = false
    feed.updateFooter(hasMore: false, loading: false)
    let servedSnapshot = !force && !feed.isRefreshing && recipes.isEmpty
      ? restoreFirstPageSnapshot(query: query, resetScroll: resetScroll) : false
    if !servedSnapshot && recipes.isEmpty && !feed.isRefreshing {
      feed.showLoading()
    } else if showProgress {
      hud.show(in: view, text: app.text("加载中", "Loading"))
    }
    requestTask = Task { [weak self] in
      guard let self else { return }
      do {
        var parameters = query
        parameters["page"] = "0"
        let response: QFContentPage<QFRecipeHomeItem> = try await
          QFContentLoadingContext.$forceRefresh.withValue(force || self.feed.isRefreshing) {
            try await self.app.publicContentRequest(path: "home/recipes", query: parameters)
          }
        try Task.checkCancellation()
        guard self.requestID == id else { return }
        self.currentQuery = query
        self.persistFirstPageSnapshot(response, query: query)
        self.recipes = self.presentedFirstPage(response.items, query: query)
        self.total = response.total
        self.nextPage = 1
        self.hasMore = !response.items.isEmpty && response.items.count < response.total
        self.feed.apply(self.recipes, emptyText: self.emptyText(for: query))
        self.feed.updateFooter(hasMore: self.hasMore, loading: false)
        self.feed.finishRefresh()
        self.hud.hide()
        if resetScroll { self.feed.scrollToTop() }
        self.recipeRequestDidSucceed(query: query)
      } catch is CancellationError {
      } catch {
        guard self.requestID == id else { return }
        self.feed.finishRefresh()
        self.feed.updateFooter(hasMore: self.hasMore, loading: false)
        self.hud.hide()
        if self.recipes.isEmpty {
          self.feed.showFailure()
        } else {
          QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self.view)
        }
        self.recipeRequestDidFail(query: query, previousQuery: oldQuery, error: error)
      }
    }
  }

  /// Recommendation ordering is a presentation concern. The server contract and
  /// pagination query stay unchanged; only the first recommendation page is
  /// shuffled so a cold home screen does not always lead with the same recipes.
  private func presentedFirstPage(
    _ items: [QFRecipeHomeItem], query: [String: String]
  ) -> [QFRecipeHomeItem] {
    guard query.isEmpty, items.count > 1 else { return items }
    return items.shuffled()
  }

  @discardableResult
  private func restoreFirstPageSnapshot(query: [String: String], resetScroll: Bool) -> Bool {
    guard query.isEmpty else { return false }
    let keyQuery = query.merging(["__language": app.interfaceLanguage]) { _, value in value }
    guard let data = app.contentCache.querySnapshotData(
      scope: app.contentScope, path: "home/recipes", query: keyQuery),
      let snapshot = try? JSONDecoder().decode(FirstPageSnapshot.self, from: data),
      Date().timeIntervalSince(snapshot.storedAt) <= Self.firstPageSnapshotTTL,
      !snapshot.items.isEmpty else { return false }
    currentQuery = query
    recipes = presentedFirstPage(snapshot.items, query: query)
    total = snapshot.total
    nextPage = 1
    hasMore = recipes.count < total
    feed.apply(recipes, emptyText: emptyText(for: query))
    feed.updateFooter(hasMore: hasMore, loading: false)
    feed.finishRefresh()
    if resetScroll { feed.scrollToTop() }
    return true
  }

  private func persistFirstPageSnapshot(
    _ response: QFContentPage<QFRecipeHomeItem>, query: [String: String]
  ) {
    guard query.isEmpty, !response.items.isEmpty else { return }
    let snapshot = FirstPageSnapshot(storedAt: Date(), items: response.items, total: response.total)
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    let keyQuery = query.merging(["__language": app.interfaceLanguage]) { _, value in value }
    app.contentCache.storeQuerySnapshotData(
      data, scope: app.contentScope, path: "home/recipes", query: keyQuery)
  }

  func reloadCurrent(force: Bool = false) {
    requestRecipes(query: currentQuery, force: force)
  }

  func invalidateLocalizedContent() {
    requestTask?.cancel()
    requestTask = nil
    requestID = UUID()
    recipes = []
    total = 0
    nextPage = 0
    hasMore = false
    loadingMore = false
    feed.showLoading(clearingContent: true)
    feed.updateFooter(hasMore: false, loading: false)
    feed.finishRefresh()
    hud.hide()
  }

  private func loadMore() {
    guard hasMore, !loadingMore else { feed.updateFooter(hasMore: hasMore, loading: false); return }
    loadingMore = true
    feed.updateFooter(hasMore: true, loading: true)
    let id = requestID
    let query = currentQuery
    let page = nextPage
    requestTask = Task { [weak self] in
      guard let self else { return }
      do {
        var parameters = query
        parameters["page"] = String(page)
        let response: QFContentPage<QFRecipeHomeItem> = try await self.app.publicContentRequest(
          path: "home/recipes", query: parameters)
        try Task.checkCancellation()
        guard self.requestID == id, self.currentQuery == query else { return }
        var positions = Dictionary(uniqueKeysWithValues: self.recipes.enumerated().map { ($0.element.id, $0.offset) })
        let count = self.recipes.count
        for item in response.items {
          if let index = positions[item.id] { self.recipes[index] = item }
          else { positions[item.id] = self.recipes.count; self.recipes.append(item) }
        }
        self.total = response.total
        self.nextPage = page + 1
        self.hasMore = self.recipes.count > count && self.recipes.count < response.total
        self.loadingMore = false
        self.feed.apply(self.recipes, emptyText: self.emptyText(for: query))
        self.feed.updateFooter(hasMore: self.hasMore, loading: false)
        self.recipeRequestDidSucceed(query: query)
      } catch is CancellationError {
      } catch {
        guard self.requestID == id else { return }
        self.loadingMore = false
        self.feed.updateFooter(hasMore: true, loading: false, failed: true)
      }
    }
  }

  func emptyText(for query: [String: String]) -> String {
    app.text("没有找到符合条件的菜谱", "No recipes match these filters")
  }

  func recipeRequestDidSucceed(query: [String: String]) {}
  func recipeRequestDidFail(query: [String: String], previousQuery: [String: String], error: Error) {}

  func updateRecipe(_ item: QFRecipeHomeItem, notify: Bool = true) {
    guard let index = recipes.firstIndex(where: { $0.id == item.id }) else { return }
    recipes[index] = item
    feed.reconfigure(item)
    if notify { recipeDidChange(item) }
  }

  func recipeDidChange(_ item: QFRecipeHomeItem) {}

  private func openRecipe(_ item: QFRecipeHomeItem) {
    let detail = QFHomeRecipeDetailViewController(app: app, initial: item) { [weak self] updated in
      self?.updateRecipe(updated)
    }
    qfPush(detail)
  }

  private func toggleFavorite(_ item: QFRecipeHomeItem) {
    requireLogin { [weak self] in self?.performFavoriteToggle(item.id) }
  }

  private func performFavoriteToggle(_ id: String) {
    guard favoriteTasks[id] == nil, var item = recipes.first(where: { $0.id == id }) else { return }
    let previous = item
    item.isFavorite.toggle()
    item.favoriteCount = max(0, item.favoriteCount + (item.isFavorite ? 1 : -1))
    updateRecipe(item)
    feed.setFavoriteBusy(true, id: id)
    favoriteTasks[id] = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.app.contentMutation(
          path: "me/favorites/RECIPE/\(id)", method: item.isFavorite ? "PUT" : "DELETE")
      } catch is CancellationError {
        self.updateRecipe(previous)
      } catch {
        self.updateRecipe(previous)
        QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self.view)
      }
      self.favoriteTasks[id] = nil
      self.feed.setFavoriteBusy(false, id: id)
      if self.refreshAfterAuthenticatedAction {
        self.refreshAfterAuthenticatedAction = false
        self.reloadCurrent(force: true)
      }
    }
  }

  func requireLogin(_ action: @escaping () -> Void) {
    guard app.user == nil else { action(); return }
    weak var login: QFLoginViewController?
    let controller = QFLoginViewController(app: app) { [weak self] in
      guard let self else { return }
      if self.navigationController?.topViewController === login {
        self.navigationController?.popViewController(animated: true)
      }
      if self.app.user != nil {
        self.refreshAfterAuthenticatedAction = true
        action()
      }
    }
    login = controller
    qfPush(controller)
  }
}
