import SnapKit
import UIKit

@MainActor
final class QFInterestPreferencesViewController: QFProfileContentController {
  private var options: QFInterestOptions?
  private var draft = QFInterests()
  private var initial = QFInterests()
  private var excludedNames: [String: String] = [:]
  private var loaded = false
  private var cuisineNotice = ""
  private var built = false
  private let countryChips = QFInterestChipGroup()
  private let cuisineChips = QFInterestChipGroup()
  private let tasteChips = QFInterestChipGroup()
  private let spiceChips = QFInterestChipGroup()
  private let excludedRows = QFInterestChipGroup()
  private lazy var excludedEmpty = QFContentUI.label(app.text("暂未设置", "Not set"), size: 14, color: QFUI.secondary)
  override var hasUnsavedChanges: Bool { draft != initial }
  override var reloadsOnAppearance: Bool { false }
  init(app: QFAppSession) { super.init(app: app, title: app.text("兴趣偏好", "Interests")) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    _ = addFooter(app.text("重置", "Reset"), primary: false) { [weak self] in
      self?.draft = QFInterests()
      self?.cuisineNotice = ""
      self?.render()
    }
    _ = addFooter(app.text("保存偏好", "Save interests")) { [weak self] in self?.save() }
    load()
  }
  private func load() {
    setReloadAction(allowsPullToRefresh: false) { [weak self] in self?.load() }
    execute(reloadOnFailure: true) { [self] in
      options = try await app.contentRequest(path: "profile/options")
      initial = try await app.contentRequest(path: "me/interests")
      draft = QFContentDraftStore.load(QFInterests.self, app: app, kind: "interests") ?? initial
      for id in draft.excludedIngredientIds {
        if let item: QFCatalogItem = try? await app.contentRequest(path: "catalog/INGREDIENT/\(id)")
        {
          excludedNames[id] = item.title
        }
      }
      loaded = true
      render()
    }
  }
  private func render() {
    guard let options else { return }
    if !built {
      built = true
      for (title, group) in [
        (app.text("感兴趣的国家", "Countries of interest"), countryChips),
        (app.text("菜系", "Cuisines"), cuisineChips),
        (app.text("口味", "Tastes"), tasteChips),
        (app.text("辣度", "Spice level"), spiceChips),
      ] {
        bodyStack.addArrangedSubview(QFContentUI.label(title, size: 18, bold: true))
        bodyStack.addArrangedSubview(group)
      }
      let heading = QFTabUI.stack(
        [
          QFContentUI.label(app.text("不吃的食材", "Excluded ingredients"), size: 18, bold: true), UIView(),
          QFContentUI.action(app.text("添加", "Add")) { [weak self] in self?.addIngredient() },
        ], axis: .horizontal, spacing: 10)
      bodyStack.addArrangedSubview(heading)
      excludedRows.axis = .vertical
      excludedRows.spacing = 8
      bodyStack.addArrangedSubview(excludedRows)
      bodyStack.addArrangedSubview(excludedEmpty)
    }
    countryChips.update(options.countries, selected: draft.countryIds) { [weak self] id in
      guard let self else { return }
      self.toggle(id, in: &self.draft.countryIds)
      let valid = self.availableCuisines.map(\.id)
      self.draft.cuisineIds.removeAll { !valid.contains($0) }
      self.render()
    }
    cuisineChips.update(availableCuisines, selected: draft.cuisineIds) { [weak self] id in
      guard let self else { return }
      self.toggle(id, in: &self.draft.cuisineIds)
      self.render()
    }
    tasteChips.update(options.tastes, selected: draft.tasteIds) { [weak self] id in
      guard let self else { return }
      self.toggle(id, in: &self.draft.tasteIds)
      self.render()
    }
    spiceChips.update(options.spiceLevels, selected: draft.spiceLevel.map { [$0] } ?? []) {
      [weak self] id in
      guard let self else { return }
      self.draft.spiceLevel = self.draft.spiceLevel == id ? nil : id
      self.render()
    }
    let excluded = draft.excludedIngredientIds.map {
      QFInterestOption(id: $0, name: (excludedNames[$0] ?? app.text("食材暂不可用", "Ingredient unavailable")) + " ×", countryIds: nil)
    }
    excludedEmpty.isHidden = !excluded.isEmpty
    excludedRows.isHidden = excluded.isEmpty
    excludedRows.update(excluded, selected: draft.excludedIngredientIds) { [weak self] id in
      self?.draft.excludedIngredientIds.removeAll { $0 == id }
      self?.render()
    }
  }
  private var availableCuisines: [QFInterestOption] {
    (options?.cuisines ?? []).filter {
      draft.countryIds.isEmpty || !Set($0.countryIds ?? []).isDisjoint(with: draft.countryIds)
    }
  }
  private func toggle(_ id: String, in values: inout [String]) {
    if values.contains(id) { values.removeAll { $0 == id } } else { values.append(id) }
  }
  private func addIngredient() {
    open(
      QFCatalogSearchViewController(app: app, type: "INGREDIENT") { [weak self] item in
        guard let self else { return }
        if !self.draft.excludedIngredientIds.contains(item.id) {
          self.draft.excludedIngredientIds.append(item.id)
        }
        self.excludedNames[item.id] = item.title
        self.render()
      })
  }
  private func save() {
    guard loaded else { return }
    QFContentDraftStore.save(draft, app: app, kind: "interests")
    execute { [self] in
      let _: QFInterests = try await app.contentRequest(
        path: "me/interests", method: "PUT", body: JSONEncoder().encode(draft))
      QFContentDraftStore.remove(app: app, kind: "interests")
      onChanged?()
      qfClose()
    }
  }
  override func close() {
    guard draft != initial else {
      super.close()
      return
    }
    preserveOrDiscard(
      { [self] in QFContentDraftStore.save(draft, app: app, kind: "interests") },
      discard: { [self] in QFContentDraftStore.remove(app: app, kind: "interests") })
  }
}

@MainActor
final class QFCatalogSearchViewController: QFProfileContentController, UITableViewDelegate,
  UISearchBarDelegate
{
  private let type: String
  private let selection: (QFCatalogItem) -> Void
  private var activeQuery = ""
  private var renderedQuery = ""
  private var pagination = QFContentPagination<QFCatalogItem>()
  private let table = UITableView(frame: .zero, style: .plain)
  private let searchBar = UISearchBar()
  private var dataSource: UITableViewDiffableDataSource<Int, String>!
  private var itemsByID: [String: QFCatalogItem] = [:]
  private let emptyLabel = QFContentUI.label("", color: QFUI.secondary)

  init(app: QFAppSession, type: String, selection: @escaping (QFCatalogItem) -> Void) {
    self.type = type
    self.selection = selection
    super.init(
      app: app,
      title: type == "INGREDIENT"
        ? app.text("选择食材", "Choose ingredient") : app.text("选择菜谱", "Choose recipe"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    searchBar.searchBarStyle = .minimal
    searchBar.placeholder =
      type == "INGREDIENT"
      ? app.text("搜索食材名称", "Search ingredients") : app.text("搜索菜谱名称", "Search recipes")
    searchBar.delegate = self
    searchBar.snp.makeConstraints { $0.height.equalTo(52) }
    table.backgroundColor = QFUI.background
    table.separatorColor = QFUI.border
    table.separatorInset = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
    table.rowHeight = UITableView.automaticDimension
    table.estimatedRowHeight = 76
    table.delegate = self
    table.register(UITableViewCell.self, forCellReuseIdentifier: "catalog")
    emptyLabel.textAlignment = .center
    emptyLabel.numberOfLines = 0
    installList(table, controls: searchBar)
    dataSource = UITableViewDiffableDataSource<Int, String>(tableView: table) {
      [weak self] table, index, id in
      guard let self, let item = self.itemsByID[id] else { return nil }
      let cell = table.dequeueReusableCell(withIdentifier: "catalog", for: index)
      var content = cell.defaultContentConfiguration()
      content.text = item.title
      content.secondaryText = item.subtitle.isEmpty ? nil : item.subtitle
      content.textProperties.font = .preferredFont(forTextStyle: .body)
      content.textProperties.color = QFUI.text
      content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
      content.secondaryTextProperties.color = QFUI.secondary
      content.directionalLayoutMargins = NSDirectionalEdgeInsets(
        top: 14, leading: 20, bottom: 14, trailing: 20)
      cell.contentConfiguration = content
      cell.backgroundColor = QFUI.background
      cell.accessoryType = .none
      cell.accessibilityTraits.insert(.button)
      return cell
    }
    search()
  }
  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    activeQuery = (searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    searchBar.resignFirstResponder()
    search(reset: true)
  }
  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    if searchText.isEmpty && !activeQuery.isEmpty {
      activeQuery = ""
      search(reset: true)
    }
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard activeQuery == renderedQuery,
      let id = dataSource.itemIdentifier(for: indexPath), let item = itemsByID[id]
    else {
      return
    }
    qfClose { [selection] in selection(item) }
  }
  private func search(append: Bool = false, reset: Bool = false) {
    setReloadAction { [weak self] in self?.search() }
    let previous = reset ? QFContentPagination<QFCatalogItem>() : pagination
    let requestedQuery = activeQuery
    let fromFirstPage = reset || isRefreshingContent
    if reset {
      setLoadMoreAction(nil)
    }
    execute(reloadOnFailure: true, loadingMore: append, showReadProgress: reset) { [self] in
      do {
        let updated = try await previous.fetching(
          app: app, path: "catalog", query: ["type": type, "q": requestedQuery],
          append: append, reset: fromFirstPage, id: { $0.id })
        guard activeQuery == requestedQuery else { throw CancellationError() }
        pagination = updated
        renderedQuery = requestedQuery
        render()
        if reset { table.setContentOffset(.zero, animated: false) }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try Task.checkCancellation()
        guard activeQuery == requestedQuery else { throw CancellationError() }
        if activeQuery != renderedQuery || pagination.items.isEmpty {
          // Keep the failed search text, but never offer results from a different query.
          pagination = QFContentPagination()
          itemsByID.removeAll()
          var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
          snapshot.appendSections([0])
          // Select the callback overload so failed-search rendering does not suspend.
          dataSource.apply(snapshot, animatingDifferences: false, completion: nil)
          emptyLabel.text = app.text("加载失败，请下拉重试", "Could not load. Pull down to retry.")
          table.backgroundView = emptyLabel
          setLoadMoreAction(nil)
        }
        throw error
      }
    }
  }
  private func render() {
    var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
    snapshot.appendSections([0])
    snapshot.appendItems(pagination.items.map(\.id))
    let oldIDs = Set(dataSource.snapshot().itemIdentifiers)
    let changed = pagination.items.filter { item in
      guard let previous = itemsByID[item.id] else { return false }
      return item.title != previous.title || item.subtitle != previous.subtitle
    }.map(\.id).filter { oldIDs.contains($0) }
    itemsByID = Dictionary(uniqueKeysWithValues: pagination.items.map { ($0.id, $0) })
    snapshot.reconfigureItems(changed)
    dataSource.apply(snapshot, animatingDifferences: false)
    emptyLabel.text =
      activeQuery.isEmpty
      ? app.text("暂无条目", "No items yet") : app.text("没有找到符合条件的条目", "No matching items")
    table.backgroundView = pagination.items.isEmpty ? emptyLabel : nil
    setLoadMoreAction(pagination.hasMore ? { [weak self] in self?.search(append: true) } : nil)
  }
}
