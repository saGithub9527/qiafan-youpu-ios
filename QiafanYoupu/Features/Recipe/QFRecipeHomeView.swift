import Combine
@preconcurrency import JXSegmentedView
import SnapKit
import UIKit

@MainActor
private final class QFRecipeCategoryListViewController: QFRecipeFeedViewController,
  @preconcurrency JXSegmentedListContainerViewListDelegate
{
  private let categoryID: String
  private var filter: QFRecipeFilterState
  private var isActive = false
  private var hasLoaded = false
  private var needsReload = true
  private var forceNextReload = false
  var onRecipeChange: ((QFRecipeHomeItem) -> Void)?

  init(app: QFAppSession, categoryID: String, filter: QFRecipeFilterState) {
    self.categoryID = categoryID
    self.filter = filter
    super.init(app: app)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    installFeedToFillView()
  }

  func listView() -> UIView { view }

  func listWillAppear() {
    isActive = true
    loadIfNeeded()
  }

  func listWillDisappear() { isActive = false }

  func apply(filter: QFRecipeFilterState, force: Bool) {
    let oldQuery = query(for: self.filter)
    let newQuery = query(for: filter)
    self.filter = filter
    guard oldQuery != newQuery || force else { return }
    needsReload = true
    forceNextReload = forceNextReload || force
    if isActive { loadIfNeeded(resetScroll: oldQuery != newQuery) }
  }

  func applyExternalRecipe(_ item: QFRecipeHomeItem) {
    updateRecipe(item, notify: false)
  }

  private func query(for state: QFRecipeFilterState) -> [String: String] {
    var scoped = state
    scoped.categoryID = categoryID
    var query = scoped.query(page: 0)
    query.removeValue(forKey: "page")
    return query
  }

  private func loadIfNeeded(resetScroll: Bool = false) {
    guard needsReload || !hasLoaded else { return }
    let force = forceNextReload
    forceNextReload = false
    needsReload = false
    requestRecipes(query: query(for: filter), resetScroll: resetScroll, force: force)
  }

  override func recipeRequestDidSucceed(query: [String: String]) {
    hasLoaded = true
    needsReload = false
  }

  override func recipeRequestDidFail(
    query: [String: String], previousQuery: [String: String], error: Error
  ) {
    needsReload = true
  }

  override func recipeDidChange(_ item: QFRecipeHomeItem) { onRecipeChange?(item) }
}

@MainActor
final class QFRecipeViewController: UIViewController, @preconcurrency JXSegmentedViewDelegate,
  @preconcurrency JXSegmentedListContainerViewDataSource
{
  let app: QFAppSession
  private let chrome = UIView()
  private let segmentedView = JXSegmentedView()
  private let segmentedDataSource = JXSegmentedTitleDataSource()
  private lazy var listContainer = JXSegmentedListContainerView(dataSource: self, type: .scrollView)
  private let filtersStack = UIStackView()
  private let sectionTitle = QFTabUI.label("", size: 17, weight: .semibold)
  private var searchButton: UIButton!
  private var clearButton: UIButton!
  private var filterButtons: [String: QFRecipeFilterButton] = [:]
  private var options: QFRecipeHomeOptions?
  private var displayedCategories: [QFRecipeOption] = []
  private var filter = QFRecipeFilterState()
  private var optionsTask: Task<Void, Never>?
  private var optionsRequestID = UUID()
  private var subscriptions = Set<AnyCancellable>()
  private var needsIdentityReload = false
  private var appeared = false
  private var loadedLanguage = ""
  private var installedBackGesturePriority = false

  init(app: QFAppSession) {
    self.app = app
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }
  deinit { optionsTask?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.accessibilityIdentifier = "recipe.home"
    buildChrome()
    rebuildCategories([])
    loadOptions(countryID: nil)

    app.$user.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
      guard let self else { return }
      if self.view.window != nil, self.navigationController?.topViewController === self {
        self.refreshLoadedLists(force: true)
      } else {
        self.needsIdentityReload = true
      }
    }.store(in: &subscriptions)

    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        self.optionsTask?.cancel()
        self.options = nil
        self.loadedLanguage = ""
        self.applyChromeLanguage()
        self.rebuildCategories([])
        if self.view.window != nil, self.navigationController?.topViewController === self {
          self.loadOptions(countryID: self.filter.countryID)
        }
      }
    }.store(in: &subscriptions)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    let language = app.interfaceLanguage
    if appeared, loadedLanguage != language {
      loadOptions(countryID: filter.countryID)
      refreshLoadedLists(force: true)
    } else if appeared, needsIdentityReload {
      needsIdentityReload = false
      refreshLoadedLists(force: true)
    }
    appeared = true
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard !installedBackGesturePriority,
      let pop = navigationController?.interactivePopGestureRecognizer
    else { return }
    listContainer.scrollView.panGestureRecognizer.require(toFail: pop)
    installedBackGesturePriority = true
  }

  private func buildChrome() {
    chrome.backgroundColor = QFUI.background
    view.addSubview(chrome)
    chrome.snp.makeConstraints {
      $0.top.equalTo(view.safeAreaLayoutGuide)
      $0.leading.trailing.equalTo(view.safeAreaLayoutGuide)
    }

    segmentedDataSource.titleNormalColor = QFUI.secondary
    segmentedDataSource.titleSelectedColor = QFUI.text
    segmentedDataSource.titleNormalFont = .systemFont(ofSize: 16, weight: .medium)
    segmentedDataSource.titleSelectedFont = .systemFont(ofSize: 20, weight: .semibold)
    segmentedDataSource.isTitleColorGradientEnabled = true
    segmentedDataSource.isItemSpacingAverageEnabled = false
    segmentedDataSource.itemSpacing = QFRecipeHomeLayout.categorySpacing
    segmentedDataSource.itemWidthIncrement = 16
    segmentedView.dataSource = segmentedDataSource
    segmentedView.delegate = self
    segmentedView.contentEdgeInsetLeft = 0
    segmentedView.contentEdgeInsetRight = 0
    segmentedView.isContentScrollViewClickTransitionAnimationEnabled = true
    let indicator = JXSegmentedIndicatorLineView()
    indicator.indicatorColor = QFUI.primary
    indicator.indicatorWidth = 32
    indicator.indicatorHeight = 3
    indicator.verticalOffset = 1
    segmentedView.indicators = [indicator]
    segmentedView.accessibilityIdentifier = "recipe.categories"

    searchButton = QFTabUI.iconButton(
      "magnifyingglass", label: app.text("搜索菜谱", "Search recipes"), size: 18,
      weight: .medium
    ) { [weak self] in self?.openSearch() }
    searchButton.tintColor = QFUI.text
    searchButton.accessibilityIdentifier = "recipe.search"

    for item in [segmentedView, searchButton!] { chrome.addSubview(item) }
    searchButton.snp.makeConstraints {
      $0.top.equalToSuperview().offset(QFRecipeHomeLayout.categoryTopOffset)
      $0.trailing.equalToSuperview().inset(12)
      $0.width.equalTo(46)
      $0.height.equalTo(QFRecipeHomeLayout.categoryHeight)
    }
    segmentedView.snp.makeConstraints {
      $0.top.height.equalTo(searchButton)
      $0.leading.equalToSuperview().offset(QFRecipeHomeLayout.categoryControlLeading)
      $0.trailing.equalTo(searchButton.snp.leading).offset(-8)
    }

    filtersStack.axis = .horizontal
    filtersStack.spacing = QFRecipeHomeLayout.filterSpacing
    filtersStack.distribution = .fillEqually
    for (key, name) in [
      ("country", app.text("国家", "Country")), ("taste", app.text("口味", "Taste")),
      ("cuisine", app.text("菜系", "Cuisine")), ("rating", app.text("评分", "Rating")),
    ] {
      let button = QFRecipeFilterButton(name: name) { [weak self] in self?.openFilter(key) }
      button.accessibilityIdentifier = "recipe.filter.\(key)"
      filtersStack.addArrangedSubview(button)
      filterButtons[key] = button
    }
    chrome.addSubview(filtersStack)
    filtersStack.snp.makeConstraints {
      $0.top.equalTo(searchButton.snp.bottom).offset(QFRecipeHomeLayout.filterTopGap)
      $0.leading.trailing.equalToSuperview().inset(QFRecipeHomeLayout.pageHorizontalInset)
      $0.height.equalTo(QFRecipeHomeLayout.filterHeight)
    }

    clearButton = QFTabUI.button(
      app.text("清空筛选", "Clear filters"), size: 11.5, weight: .regular,
      color: QFUI.secondary
    ) { [weak self] in self?.clearFilters() }
    clearButton.accessibilityIdentifier = "recipe.clearFilters"
    clearButton.snp.makeConstraints { $0.height.equalTo(36) }
    let section = QFTabUI.stack(
      [sectionTitle, UIView(), clearButton], axis: .horizontal, spacing: 8)
    section.alignment = .center
    chrome.addSubview(section)
    section.snp.makeConstraints {
      $0.top.equalTo(filtersStack.snp.bottom).offset(3)
      $0.leading.trailing.equalToSuperview().inset(QFRecipeHomeLayout.pageHorizontalInset)
      $0.bottom.equalToSuperview()
      $0.height.equalTo(QFRecipeHomeLayout.sectionHeight)
    }

    view.addSubview(listContainer)
    listContainer.backgroundColor = QFUI.background
    listContainer.listCellBackgroundColor = QFUI.background
    listContainer.snp.makeConstraints {
      $0.top.equalTo(chrome.snp.bottom).offset(QFRecipeHomeLayout.listTopGap)
      $0.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
    }
    segmentedView.listContainer = listContainer
    renderFilterControls()
  }

  private func applyChromeLanguage() {
    searchButton?.accessibilityLabel = app.text("搜索菜谱", "Search recipes")
    clearButton?.setTitle(app.text("清空筛选", "Clear filters"), for: .normal)
    for (key, title) in [
      ("country", app.text("国家", "Country")), ("taste", app.text("口味", "Taste")),
      ("cuisine", app.text("菜系", "Cuisine")), ("rating", app.text("评分", "Rating")),
    ] {
      filterButtons[key]?.setName(title)
    }
    renderFilterControls()
  }

  private func loadOptions(countryID: String?) {
    optionsTask?.cancel()
    optionsRequestID = UUID()
    let id = optionsRequestID
    let requestedCountry = countryID
    let requestedLanguage = app.interfaceLanguage
    optionsTask = Task { [weak self] in
      guard let self else { return }
      do {
        let response: QFRecipeHomeOptions = try await self.app.publicContentRequest(
          path: "home/recipe-options",
          query: ["country": requestedCountry ?? "GLOBAL"])
        try Task.checkCancellation()
        guard self.optionsRequestID == id, self.filter.countryID == requestedCountry,
          self.app.interfaceLanguage == requestedLanguage
        else { return }
        self.options = response
        self.loadedLanguage = requestedLanguage
        if let cuisine = self.filter.cuisineID,
          !response.cuisines.contains(where: { $0.id == cuisine })
        {
          self.filter.cuisineID = nil
        }
        self.rebuildCategories(response.categories)
        self.renderFilterControls()
      } catch is CancellationError {
      } catch {
        guard self.optionsRequestID == id, self.app.interfaceLanguage == requestedLanguage,
          self.options == nil || self.loadedLanguage != requestedLanguage
        else { return }
        QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self.view)
      }
    }
  }

  private func rebuildCategories(_ values: [QFRecipeOption]) {
    let fallback = QFRecipeOption(
      id: "RECOMMENDED", name: app.text("推荐", "For you"), countryIds: nil)
    let all = values.contains(where: { QFRecipeFilterState.representsAll($0.id) })
      ? values : [fallback] + values
    displayedCategories = all.isEmpty ? [fallback] : all
    if filter.categoryID == nil { filter.categoryID = displayedCategories.first?.id }
    if let selected = filter.categoryID,
      !displayedCategories.contains(where: { $0.id == selected })
    {
      filter.categoryID = displayedCategories.first?.id
    }
    let selectedIndex = displayedCategories.firstIndex { $0.id == filter.categoryID } ?? 0
    segmentedDataSource.titles = displayedCategories.map(\.name)
    segmentedView.defaultSelectedIndex = selectedIndex
    segmentedView.reloadData()
    listContainer.defaultSelectedIndex = selectedIndex
    listContainer.reloadData()
    renderFilterControls()
  }

  private func renderFilterControls() {
    let global = app.text("全球", "Global")
    let unrestricted = app.text("不限", "Any")
    filterButtons["country"]?.setValue(
      optionName(filter.countryID, in: options?.countries) ?? global,
      active: filter.countryID != nil)
    filterButtons["taste"]?.setValue(
      optionName(filter.tasteID, in: options?.tastes) ?? unrestricted,
      active: filter.tasteID != nil)
    filterButtons["cuisine"]?.setValue(
      optionName(filter.cuisineID, in: options?.cuisines) ?? app.text("全部", "All"),
      active: filter.cuisineID != nil)
    filterButtons["rating"]?.setValue(
      filter.minimumRating.map {
        app.format(
          "%@+", "%@+",
          QFRecipeFilterState.ratingDisplayString(
            $0, language: QFInterfaceLanguage.normalized(app.interfaceLanguage)))
      } ?? unrestricted,
      active: filter.minimumRating != nil)
    let hasFilters = filter.countryID != nil || filter.tasteID != nil
      || filter.cuisineID != nil || filter.minimumRating != nil
    clearButton?.isEnabled = hasFilters
    clearButton?.alpha = hasFilters ? 1 : 0.4
    sectionTitle.text = categoryName(filter.categoryID) ?? app.text("为你推荐", "For you")
  }

  private func optionName(_ id: String?, in values: [QFRecipeOption]?) -> String? {
    guard let id else { return nil }
    return values?.first(where: { $0.id == id })?.name
  }

  private func categoryName(_ id: String?) -> String? {
    guard let id else { return nil }
    let name = displayedCategories.first(where: { $0.id == id })?.name
    return QFRecipeFilterState.representsAll(id) ? app.text("为你推荐", "For you") : name
  }

  private func openSearch() {
    let controller = QFRecipeSearchViewController(app: app) { [weak self] item in
      self?.propagateRecipe(item)
    }
    qfPush(controller)
  }

  private func openFilter(_ key: String) {
    guard let options else {
      QFOperationHUD.toast(app.text("筛选项仍在加载", "Filters are still loading"), in: view)
      return
    }
    switch key {
    case "country":
      qfPush(
        QFRecipeCountryFilterViewController(
          app: app, options: options.countries, selectedID: filter.countryID
        ) { [weak self] id in self?.applyCountry(id) })
    case "taste":
      present(
        QFRecipeOptionSheetViewController(
          app: app, title: app.text("口味筛选", "Taste filter"),
          unrestrictedTitle: app.text("不限", "Any"), options: options.tastes,
          selectedID: filter.tasteID
        ) { [weak self] id in self?.applySecondaryFilter(key: "taste", id: id) },
        animated: true)
    case "cuisine":
      present(
        QFRecipeOptionSheetViewController(
          app: app, title: app.text("菜系筛选", "Cuisine filter"),
          unrestrictedTitle: app.text("全部", "All"), options: options.cuisines,
          selectedID: filter.cuisineID
        ) { [weak self] id in self?.applySecondaryFilter(key: "cuisine", id: id) },
        animated: true)
    case "rating":
      present(
        QFRecipeRatingFilterViewController(
          app: app, presets: options.ratingPresets, selected: filter.minimumRating
        ) { [weak self] value in self?.applyRating(value) }, animated: true)
    default:
      break
    }
  }

  private func applyCountry(_ id: String?) {
    guard filter.countryID != id else { return }
    filter.countryID = id
    filter.cuisineID = nil
    renderFilterControls()
    loadOptions(countryID: id)
    applyFilterToLoadedLists()
  }

  private func applySecondaryFilter(key: String, id: String?) {
    if key == "taste" {
      guard filter.tasteID != id else { return }
      filter.tasteID = id
    } else {
      guard filter.cuisineID != id else { return }
      filter.cuisineID = id
    }
    renderFilterControls()
    applyFilterToLoadedLists()
  }

  private func applyRating(_ value: Double?) {
    guard filter.minimumRating != value else { return }
    filter.minimumRating = value
    renderFilterControls()
    applyFilterToLoadedLists()
  }

  private func clearFilters() {
    guard filter.countryID != nil || filter.tasteID != nil || filter.cuisineID != nil
      || filter.minimumRating != nil
    else { return }
    filter.clearSecondaryFilters()
    renderFilterControls()
    loadOptions(countryID: nil)
    applyFilterToLoadedLists()
  }

  private func loadedLists() -> [QFRecipeCategoryListViewController] {
    listContainer.validListDict.values.compactMap { $0 as? QFRecipeCategoryListViewController }
  }

  private func applyFilterToLoadedLists() {
    for controller in loadedLists() { controller.apply(filter: filter, force: false) }
    renderFilterControls()
  }

  private func refreshLoadedLists(force: Bool) {
    for controller in loadedLists() { controller.apply(filter: filter, force: force) }
  }

  private func propagateRecipe(_ item: QFRecipeHomeItem, source: QFRecipeCategoryListViewController? = nil) {
    for controller in loadedLists() where controller !== source {
      controller.applyExternalRecipe(item)
    }
  }

  func numberOfLists(in listContainerView: JXSegmentedListContainerView) -> Int {
    displayedCategories.count
  }

  func listContainerView(
    _ listContainerView: JXSegmentedListContainerView, initListAt index: Int
  ) -> JXSegmentedListContainerViewListDelegate {
    let option = displayedCategories[index]
    let controller = QFRecipeCategoryListViewController(
      app: app, categoryID: option.id, filter: filter)
    controller.onRecipeChange = { [weak self, weak controller] item in
      self?.propagateRecipe(item, source: controller)
    }
    return controller
  }

  func segmentedView(_ segmentedView: JXSegmentedView, didSelectedItemAt index: Int) {
    guard displayedCategories.indices.contains(index) else { return }
    filter.categoryID = displayedCategories[index].id
    renderFilterControls()
  }
}

@MainActor
final class QFRecipeSearchViewController: QFRecipeFeedViewController, UISearchBarDelegate {
  private let chrome = UIView()
  private let searchBar = UISearchBar()
  private let recentStack = UIStackView()
  private let recentScroll = UIScrollView()
  private let resultLabel = QFTabUI.label("", size: 13, color: QFUI.secondary)
  private let externalChange: (QFRecipeHomeItem) -> Void
  private var searchTask: Task<Void, Never>?
  private var activeQuery = ""
  private var renderedQuery = ""
  private var recentQueries: [String] = []

  init(app: QFAppSession, onRecipeChanged: @escaping (QFRecipeHomeItem) -> Void) {
    externalChange = onRecipeChanged
    super.init(app: app)
  }

  required init?(coder: NSCoder) { nil }
  deinit { searchTask?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "recipe.search.screen"
    buildChrome()
    installFeed(below: chrome)
    loadRecentQueries()
    renderRecentQueries()
    requestSearch(resetScroll: false)
    DispatchQueue.main.async { [weak self] in self?.searchBar.becomeFirstResponder() }
  }

  private var recentKey: String {
    "qf.recipe.search.recent.\(app.api.environment.name).\(app.interfaceLanguage)"
  }

  private func buildChrome() {
    chrome.backgroundColor = QFUI.background
    view.addSubview(chrome)
    chrome.snp.makeConstraints { $0.top.leading.trailing.equalTo(view.safeAreaLayoutGuide) }
    let header = QFSettingsPageUI.header(
      app.text("搜索菜谱", "Search recipes"), backLabel: app.text("返回", "Back")
    ) { [weak self] in self?.qfClose() }
    chrome.addSubview(header)
    header.snp.makeConstraints { $0.top.leading.trailing.equalToSuperview(); $0.height.greaterThanOrEqualTo(52) }
    searchBar.searchBarStyle = .minimal
    searchBar.placeholder = app.text("搜索具体菜品", "Search dishes")
    searchBar.returnKeyType = .search
    searchBar.delegate = self
    chrome.addSubview(searchBar)
    searchBar.snp.makeConstraints { $0.top.equalTo(header.snp.bottom); $0.leading.trailing.equalToSuperview().inset(12); $0.height.equalTo(50) }
    let recentTitle = QFTabUI.label(app.text("最近搜索", "Recent searches"), size: 12, weight: .medium, color: QFUI.secondary)
    recentStack.axis = .horizontal
    recentStack.spacing = 8
    recentScroll.showsHorizontalScrollIndicator = false
    recentScroll.addSubview(recentStack)
    recentStack.snp.makeConstraints { $0.edges.equalTo(recentScroll.contentLayoutGuide); $0.height.equalTo(recentScroll.frameLayoutGuide) }
    let recentRow = QFTabUI.stack([recentTitle, recentScroll], axis: .horizontal, spacing: 10)
    recentRow.alignment = .center
    chrome.addSubview(recentRow)
    recentRow.snp.makeConstraints { $0.top.equalTo(searchBar.snp.bottom); $0.leading.trailing.equalToSuperview().inset(20); $0.height.equalTo(42) }
    chrome.addSubview(resultLabel)
    resultLabel.snp.makeConstraints { $0.top.equalTo(recentRow.snp.bottom); $0.leading.trailing.equalToSuperview().inset(20); $0.bottom.equalToSuperview().inset(4); $0.height.equalTo(30) }
  }

  private func loadRecentQueries() {
    recentQueries = (UserDefaults.standard.array(forKey: recentKey) as? [String] ?? []).filter { !$0.isEmpty }
  }

  private func renderRecentQueries() {
    QFTabUI.clear(recentStack)
    if recentQueries.isEmpty {
      let label = QFTabUI.label(app.text("暂无", "None"), size: 12, color: QFUI.secondary)
      recentStack.addArrangedSubview(label)
      return
    }
    for query in recentQueries {
      let button = QFTabUI.button(
        query, size: 12.5, weight: .medium, color: QFUI.text, background: QFUI.surface
      ) { [weak self] in self?.selectRecent(query) }
      button.layer.cornerRadius = 13
      button.layer.borderWidth = 0.7
      button.layer.borderColor = QFUI.border.cgColor
      button.configuration?.contentInsets = NSDirectionalEdgeInsets(
        top: 6, leading: 12, bottom: 6, trailing: 12)
      button.snp.makeConstraints { $0.height.equalTo(30) }
      recentStack.addArrangedSubview(button)
    }
  }

  private func saveRecent(_ query: String) {
    guard !query.isEmpty else { return }
    recentQueries.removeAll { $0.localizedCaseInsensitiveCompare(query) == .orderedSame }
    recentQueries.insert(query, at: 0)
    if recentQueries.count > 10 { recentQueries.removeLast(recentQueries.count - 10) }
    UserDefaults.standard.set(recentQueries, forKey: recentKey)
    renderRecentQueries()
  }

  private func selectRecent(_ query: String) {
    searchTask?.cancel()
    searchBar.text = query
    activeQuery = query
    saveRecent(query)
    searchBar.resignFirstResponder()
    requestSearch(resetScroll: true)
  }

  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchTask?.cancel()
    activeQuery = (searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    saveRecent(activeQuery)
    searchBar.resignFirstResponder()
    requestSearch(resetScroll: true)
  }

  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    searchTask?.cancel()
    let value = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value != activeQuery else { return }
    searchTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: value.isEmpty ? 80_000_000 : 350_000_000) }
      catch { return }
      guard let self, !Task.isCancelled, self.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) == value else { return }
      self.activeQuery = value
      self.requestSearch(resetScroll: true)
    }
  }

  private func requestSearch(resetScroll: Bool) {
    var query: [String: String] = [:]
    if !activeQuery.isEmpty { query["q"] = activeQuery }
    resultLabel.text = app.text("搜索中…", "Searching…")
    requestRecipes(query: query, resetScroll: resetScroll)
  }

  override func emptyText(for query: [String: String]) -> String {
    query["q"] == nil
      ? app.text("暂无可用菜谱", "No recipes available")
      : app.text("没有找到相关菜谱", "No matching recipes")
  }

  override func recipeRequestDidSucceed(query: [String: String]) {
    renderedQuery = query["q"] ?? ""
    resultLabel.text = renderedQuery.isEmpty
      ? app.format("全部菜谱 · %d", "All recipes · %d", total)
      : app.format("找到 %d 道菜", "%d recipes found", total)
  }

  override func recipeRequestDidFail(
    query: [String: String], previousQuery: [String: String], error: Error
  ) {
    activeQuery = renderedQuery
    searchBar.text = renderedQuery
    resultLabel.text = recipes.isEmpty ? "" : app.format("找到 %d 道菜", "%d recipes found", total)
  }

  override func recipeDidChange(_ item: QFRecipeHomeItem) { externalChange(item) }
}
