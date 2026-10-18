import Combine
import SnapKit
import UIKit

@MainActor
final class QFPlanRecipePickerViewController: QFProfileContentController, UITableViewDelegate, UISearchBarDelegate {
  private let meal: String
  private let context: String
  private let date: String?
  private let householdID: String?
  private let existing: Set<String>
  private let capacity: Int
  private let replacing: Bool
  private let selection: ([QFManualPlanDraft.Recipe]) -> Void
  private let table = UITableView(frame: .zero, style: .plain)
  private let searchBar = UISearchBar()
  private let countLabel = QFContentUI.label("", size: 13, color: QFUI.secondary)
  private let emptyLabel = QFContentUI.label("", size: 15, color: QFUI.secondary)
  private var addButton: UIButton!
  private let sources = ["ALL", "FAVORITE", "FREQUENT"]
  private var source = "ALL"
  private var underlineViews: [UIView] = []
  private var query = ""
  private var renderedKey = ""
  private var pages: [String: QFContentPagination<QFCatalogItem>] = [:]
  private var offsets: [String: CGPoint] = [:]
  private var selected: [QFManualPlanDraft.Recipe] = []
  private var serverExisting = Set<String>()
  private var checkedExisting = false
  private var items: [String: QFCatalogItem] = [:]
  private var dataSource: UITableViewDiffableDataSource<Int, String>!
  private var debounce: Task<Void, Never>?
  private var key: String { "\(app.interfaceLanguage)|\(source)|\(query)" }
  override var reloadsOnAppearance: Bool { false }
  override var hasUnsavedChanges: Bool { !selected.isEmpty }

  init(app: QFAppSession, meal: String, context: String, date: String?, householdID: String?,
    existing: Set<String>, capacity: Int, replacing: Bool = false, selection: @escaping ([QFManualPlanDraft.Recipe]) -> Void) {
    self.meal = meal; self.context = context; self.date = date; self.householdID = householdID
    self.existing = existing; self.capacity = capacity; self.selection = selection
    self.replacing = replacing
    super.init(app: app, title: app.text("为计划选菜", "Choose recipes for plan"))
  }
  required init?(coder: NSCoder) { nil }
  deinit { debounce?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "plan.recipePicker"
    searchBar.searchBarStyle = .minimal
    searchBar.placeholder = app.text("搜菜名或食材", "Search recipes or ingredients")
    searchBar.delegate = self
    searchBar.accessibilityIdentifier = "plan.recipePicker.search"
    searchBar.snp.makeConstraints { $0.height.equalTo(52) }
    let contextLabel = QFContentUI.label("\(context) · \(Self.mealName(meal, app: app))", size: 13, color: QFUI.success)
    let tabs = categoryTabs([app.text("全部菜谱", "All recipes"), app.text("我的收藏", "My favorites"), app.text("经常做", "Frequently cooked")]) { [weak self] index in
      guard let self else { return }
      self.offsets[self.renderedKey] = self.table.contentOffset
      self.source = self.sources[index]
      for (i, line) in self.underlineViews.enumerated() { line.alpha = i == index ? 1 : 0 }
      self.search()
    }
    // Native segmented semantics, with the approved text-tab treatment.
    tabs.snp.remakeConstraints { $0.height.equalTo(44) }
    tabs.backgroundColor = .clear
    tabs.setBackgroundImage(UIImage(), for: .normal, barMetrics: .default)
    tabs.setBackgroundImage(UIImage(), for: .selected, barMetrics: .default)
    tabs.setDividerImage(UIImage(), forLeftSegmentState: .normal, rightSegmentState: .normal, barMetrics: .default)
    tabs.setTitleTextAttributes([.foregroundColor: QFUI.primary, .font: UIFont.systemFont(ofSize: 14, weight: .semibold)], for: .selected)
    tabs.setTitleTextAttributes([.foregroundColor: QFUI.secondary, .font: UIFont.systemFont(ofSize: 14)], for: .normal)
    tabs.accessibilityIdentifier = "plan.recipePicker.sources"
    let underlines = QFTabUI.stack([], axis: .horizontal)
    underlines.distribution = .fillEqually
    for index in 0..<3 {
      let host = UIView(), line = UIView()
      host.addSubview(line); line.backgroundColor = QFUI.primary
      line.alpha = index == 0 ? 1 : 0
      line.snp.makeConstraints { $0.width.equalTo(26); $0.height.equalTo(2); $0.centerX.top.bottom.equalToSuperview() }
      underlines.addArrangedSubview(host); underlineViews.append(line)
    }
    let controls = QFTabUI.stack([contextLabel, searchBar, tabs, underlines], spacing: 6)
    table.backgroundColor = QFUI.background; table.separatorStyle = .none
    table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 108
    table.delegate = self
    table.accessibilityIdentifier = "plan.recipePicker.list"
    table.register(QFPlanRecipeCell.self, forCellReuseIdentifier: "plan-recipe")
    emptyLabel.textAlignment = .center; emptyLabel.numberOfLines = 0
    installList(table, controls: controls)
    dataSource = UITableViewDiffableDataSource<Int, String>(tableView: table) { [weak self] table, index, id in
      guard let self, let item = self.items[id],
        let cell = table.dequeueReusableCell(withIdentifier: "plan-recipe", for: index) as? QFPlanRecipeCell else { return nil }
      cell.configure(item, app: self.app, selected: self.selected.contains { $0.id == id },
        existing: self.existing.contains(id) || self.serverExisting.contains(id))
      return cell
    }
    footer.axis = .vertical
    footer.distribution = .fill
    addButton = addFooter(app.text("加入计划", "Add to plan")) { [weak self] in
      guard let self, !self.selected.isEmpty else { return }
      let values = self.selected
      self.selected.removeAll()
      self.qfClose { [selection = self.selection] in selection(values) }
    }
    addButton.accessibilityIdentifier = "plan.recipePicker.add"
    let clear = QFContentUI.action(app.text("清空", "Clear")) { [weak self] in
      self?.selected.removeAll(); self?.render()
    }
    let countRow = QFTabUI.stack([countLabel, UIView(), clear], axis: .horizontal, spacing: 8)
    countRow.alignment = .center
    footer.insertArrangedSubview(countRow, at: 0)
    setReloadAction { [weak self] in self?.search(reset: true) }
    search(reset: true)
    app.$interfaceLanguage.dropFirst().removeDuplicates().sink { [weak self] _ in
      // Settings is outside this pushed flow. Close an externally changed language context
      // rather than mixing selected recipe text from two languages.
      self?.selected.removeAll(); self?.qfClose()
    }.store(in: &cancellables)
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isMovingFromParent || isBeingDismissed { debounce?.cancel() }
  }
  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    debounce?.cancel(); query = (searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    searchBar.resignFirstResponder(); search(reset: true)
  }
  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    debounce?.cancel()
    debounce = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 350_000_000); try Task.checkCancellation() } catch { return }
      guard let self else { return }
      self.query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
      self.search(reset: true)
    }
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard renderedKey == key, let id = dataSource.itemIdentifier(for: indexPath), let item = items[id],
      !existing.contains(id), !serverExisting.contains(id) else { return }
    if let index = selected.firstIndex(where: { $0.id == id }) { selected.remove(at: index) }
    else {
      if replacing { selected.removeAll() }
      guard selected.count < capacity - serverExisting.subtracting(existing).count else {
        message(app.text("每餐最多安排 30 道菜。", "Each meal can contain up to 30 recipes.")); return
      }
      selected.append(.init(id: item.id, title: item.title, subtitle: item.subtitle,
        mediaId: item.mediaId, minutes: item.minutes, language: app.interfaceLanguage))
    }
    render()
  }
  private func search(append: Bool = false, reset: Bool = false) {
    let requestedKey = key, requestedSource = source, requestedQuery = query
    let previous = pages[requestedKey] ?? QFContentPagination<QFCatalogItem>()
    if requestedKey != renderedKey {
      items = Dictionary(uniqueKeysWithValues: previous.items.map { ($0.id, $0) })
      renderedKey = requestedKey
      render()
      table.setContentOffset(offsets[requestedKey] ?? .zero, animated: false)
    }
    execute(reloadOnFailure: true, loadingMore: append) { [self] in
      do {
        let updated = try await previous.fetching(app: app, path: "catalog",
          query: ["type": "RECIPE", "source": requestedSource, "q": requestedQuery],
          append: append, reset: reset || isRefreshingContent, id: { $0.id })
        if !checkedExisting || isRefreshingContent, let date {
          let day = try await app.planDay(date: date, householdID: householdID)
          try Task.checkCancellation()
          serverExisting = Set(day.slots.first { $0.meal == meal }?.items.map(\.recipeId) ?? [])
          selected.removeAll { serverExisting.contains($0.id) }
          checkedExisting = true
        }
        guard key == requestedKey else { throw CancellationError() }
        pages[requestedKey] = updated
        items = Dictionary(uniqueKeysWithValues: updated.items.map { ($0.id, $0) })
        render()
      } catch {
        try Task.checkCancellation()
        guard key == requestedKey else { throw CancellationError() }
        if items.isEmpty {
          emptyLabel.text = app.text("加载失败，请下拉重试", "Could not load. Pull down to retry.")
          table.backgroundView = emptyLabel
        }
        throw error
      }
    }
  }
  private func render() {
    let pagination = pages[key] ?? QFContentPagination<QFCatalogItem>()
    let old = Set(dataSource.snapshot().itemIdentifiers)
    var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
    snapshot.appendSections([0]); snapshot.appendItems(pagination.items.map(\.id))
    snapshot.reconfigureItems(pagination.items.map(\.id).filter { old.contains($0) })
    dataSource.apply(snapshot, animatingDifferences: false, completion: nil)
    emptyLabel.text = app.text("没有找到符合条件的条目", "No matching items")
    table.backgroundView = pagination.items.isEmpty ? emptyLabel : nil
    setLoadMoreAction(pagination.hasMore ? { [weak self] in self?.search(append: true) } : nil)
    countLabel.text = app.format("已选 %d 道菜", "%d recipes selected", selected.count)
    let buttonTitle = replacing ? app.text("确认换菜", "Confirm replacement")
      : app.format("加入%@（%d）", "Add to %@ (%d)", Self.mealName(meal, app: app), selected.count)
    if addButton?.title(for: .normal) != buttonTitle {
      UIView.performWithoutAnimation {
        addButton?.setTitle(buttonTitle, for: .normal)
        addButton?.layoutIfNeeded()
      }
    }
    addButton?.isEnabled = !selected.isEmpty
    addButton?.alpha = selected.isEmpty ? 0.5 : 1
  }
  override func close() {
    guard !selected.isEmpty else { super.close(); return }
    confirm(app.text("放弃修改", "Discard changes"), detail: app.text("返回不会自动发布或提交。", "Going back will not publish or submit anything automatically."), destructive: true) { [weak self] in self?.qfClose() }
  }
  static func mealName(_ value: String, app: QFAppSession) -> String {
    switch value {
    case "BREAKFAST": return app.text("早餐", "Breakfast")
    case "LUNCH": return app.text("午餐", "Lunch")
    default: return app.text("晚餐", "Dinner")
    }
  }
}

@MainActor
private final class QFPlanRecipeCell: UITableViewCell {
  private let card = UIView()
  private let picture = QFContentImageView()
  private let title = QFContentUI.label("", size: 16, bold: true)
  private let detail = QFContentUI.label("", size: 12, color: QFUI.secondary)
  private let state = UIImageView()
  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear; selectionStyle = .none
    card.backgroundColor = QFUI.surface
    card.layer.cornerRadius = QFCreatePlanLayout.cardRadius
    card.layer.borderWidth = 1
    contentView.addSubview(card)
    card.snp.makeConstraints { $0.leading.trailing.equalToSuperview().inset(QFCreatePlanLayout.pageInset); $0.top.equalToSuperview().offset(4); $0.bottom.equalToSuperview().inset(8) }
    picture.layer.cornerRadius = 12; picture.clipsToBounds = true
    picture.backgroundColor = QFUI.paleGreen; picture.isUserInteractionEnabled = false
    picture.snp.makeConstraints { $0.size.equalTo(QFCreatePlanLayout.pickerImageSize) }
    title.numberOfLines = 2; detail.numberOfLines = 2
    state.contentMode = .scaleAspectFit
    state.snp.makeConstraints { $0.size.equalTo(24) }
    let row = QFTabUI.stack([picture, QFTabUI.stack([title, detail], spacing: 6), state], axis: .horizontal, spacing: 12)
    row.alignment = .center
    card.addSubview(row)
    row.snp.makeConstraints { $0.edges.equalToSuperview().inset(12) }
    isAccessibilityElement = true
  }
  required init?(coder: NSCoder) { nil }
  func configure(_ item: QFCatalogItem, app: QFAppSession, selected: Bool, existing: Bool) {
    title.text = item.title
    let facts = [item.subtitle, item.minutes.map { app.format("%d 分钟", "%d min", $0) } ?? ""]
      .filter { !$0.isEmpty }.joined(separator: " · ")
    detail.text = existing ? app.text("已在当餐计划中", "Already in this meal") : facts
    picture.load(item.mediaId, app: app)
    state.image = UIImage(systemName: selected || existing ? "checkmark.circle.fill" : "circle")
    state.tintColor = existing ? QFUI.secondary : selected ? QFUI.success : QFUI.border
    card.layer.borderColor = (selected ? QFUI.success : QFUI.surface).cgColor
    card.alpha = existing ? 0.6 : 1
    accessibilityLabel = [item.title, detail.text ?? ""].joined(separator: ", ")
    accessibilityTraits = existing ? [.button, .notEnabled] : selected ? [.button, .selected] : [.button]
    accessibilityIdentifier = "plan.recipePicker.recipe.\(item.id)"
  }
}
