import Combine
import SnapKit
import UIKit

// DESIGN_BASELINE: ingredient-discovery-r1. Sidebar and search are fixed; only cards refresh.
enum QFIngredientCategory: String, CaseIterable {
  case vegetable = "VEGETABLE", meat = "MEAT_EGG", seafood = "SEAFOOD", grain = "GRAIN", dairy = "DAIRY", fruit = "FRUIT", fungi = "FUNGI_ALGAE", seasoning = "SEASONING", other = "OTHER"
  @MainActor func title(_ app: QFAppSession) -> String {
    switch self {
    case .vegetable: return app.text("蔬菜", "Vegetables")
    case .meat: return app.text("肉蛋", "Meat & eggs")
    case .seafood: return app.text("水产", "Seafood")
    case .grain: return app.text("谷物", "Grains")
    case .dairy: return app.text("奶制品", "Dairy")
    case .fruit: return app.text("水果", "Fruit")
    case .fungi: return app.text("菌藻", "Fungi & algae")
    case .seasoning: return app.text("调味", "Seasonings")
    case .other: return app.text("其他", "Other")
    }
  }
}

@MainActor final class QFIngredientCatalogViewController: QFProfileContentController, UICollectionViewDelegateFlowLayout, UISearchBarDelegate {
  private let inventoryOnly: Bool
  private let selection: ((QFCatalogItem) -> Void)?
  private let collection = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
  private let search = UISearchBar()
  private let sidebar = UIScrollView()
  private let categoryStack = QFTabUI.stack([], spacing: 8)
  private let categoryHeading = QFTabUI.label("", size: 20, weight: .semibold)
  private let categoryCaption = QFTabUI.label("", size: 14, color: QFUI.secondary)
  private let state = QFTabUI.label("", size: 15, color: QFUI.secondary, lines: 0)
  private var source: UICollectionViewDiffableDataSource<Int, String>!
  private var category = QFIngredientCategory.vegetable
  private var query = ""
  private var items: [QFCatalogItem] = []
  private var nextPage = 0
  private var total = 0
  private var fetchedCount = 0
  private var hasMore = false
  private var loaded = false
  private var errorMessage: String?
  private var debounce: Task<Void, Never>?
  override var reloadsOnAppearance: Bool { false }
  init(app: QFAppSession, inventoryOnly: Bool = false, selection: ((QFCatalogItem) -> Void)? = nil) {
    self.inventoryOnly = inventoryOnly; self.selection = selection
    super.init(app: app, title: selection == nil ? app.text("食材大全", "Ingredient catalog") : app.text("选择食材", "Choose ingredient"))
  }
  required init?(coder: NSCoder) { nil }
  deinit { debounce?.cancel() }
  override func viewDidLoad() {
    super.viewDidLoad(); view.accessibilityIdentifier = "ingredient.catalog"
    search.searchBarStyle = .minimal; search.delegate = self; search.placeholder = app.text("搜索食材名称或别名", "Search ingredient names or aliases"); search.snp.makeConstraints { $0.height.equalTo(52) }
    let subtitle = QFTabUI.stack([categoryCaption, categoryHeading], axis: .horizontal, spacing: 12)
    subtitle.arrangedSubviews[0].snp.makeConstraints { $0.width.equalTo(74) }; subtitle.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
    let controls = QFTabUI.stack([search, subtitle], spacing: 14)
    collection.backgroundColor = .clear; collection.delegate = self; collection.register(QFIngredientCatalogCell.self, forCellWithReuseIdentifier: "ingredient")
    installList(collection, controls: controls)
    collection.snp.remakeConstraints { $0.top.equalTo(controls.snp.bottom).offset(8); $0.leading.equalTo(view.safeAreaLayoutGuide).offset(100); $0.trailing.equalTo(view.safeAreaLayoutGuide).inset(20); $0.bottom.equalTo(scrollView) }
    view.addSubview(sidebar); sidebar.showsVerticalScrollIndicator = false
    sidebar.snp.makeConstraints { $0.top.bottom.equalTo(collection); $0.leading.equalTo(view.safeAreaLayoutGuide).offset(20); $0.width.equalTo(68) }
    sidebar.addSubview(categoryStack); categoryStack.snp.makeConstraints { $0.edges.equalTo(sidebar.contentLayoutGuide); $0.width.equalTo(sidebar.frameLayoutGuide) }
    state.textAlignment = .center
    source = UICollectionViewDiffableDataSource<Int, String>(collectionView: collection) { [weak self] collection, index, id in
      guard let self, let item = self.items.first(where: { $0.id == id }), let cell = collection.dequeueReusableCell(withReuseIdentifier: "ingredient", for: index) as? QFIngredientCatalogCell else { return nil }
      cell.configure(item, app: self.app); return cell
    }
    setReloadAction { [weak self] in self?.load(force: true) }
    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reset() }.store(in: &cancellables)
    app.$planningScope.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reset() }.store(in: &cancellables)
    renderCategories(); render(); load()
  }
  private func renderCategories() {
    categoryCaption.text = app.text("分类", "Categories")
    categoryHeading.text = category.title(app); QFTabUI.clear(categoryStack)
    for value in QFIngredientCategory.allCases {
      let selected = value == category
      let button = QFTabUI.button(value.title(app), size: 15, weight: selected ? .semibold : .regular, color: selected ? QFUI.orange : QFUI.secondary, background: selected ? QFUI.warningBackground : .clear) { [weak self] in
        guard let self, self.category != value else { return }; self.category = value; self.reset()
      }
      button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 5, bottom: 10, right: 5)
      // Keep the approved narrow sidebar; fit complete words before wrapping long compounds.
      let title = value.title(app), weight: UIFont.Weight = selected ? .semibold : .regular
      let words = title.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      var font = UIFont.systemFont(ofSize: 15, weight: weight)
      while font.pointSize > 12 && words.contains(where: { ($0 as NSString).size(withAttributes: [.font: font]).width > 58 }) {
        font = .systemFont(ofSize: font.pointSize - 0.5, weight: weight)
      }
      let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.hyphenationFactor = 1; paragraph.lineBreakMode = .byWordWrapping
      let caption = UILabel(); caption.numberOfLines = 0; caption.font = font
      caption.textColor = selected ? QFUI.orange : QFUI.secondary
      caption.attributedText = NSAttributedString(string: title, attributes: [.font: font, .paragraphStyle: paragraph])
      caption.isUserInteractionEnabled = false; caption.isAccessibilityElement = false
      button.setTitle(nil, for: .normal); button.accessibilityLabel = title
      button.addSubview(caption); caption.snp.makeConstraints { $0.top.bottom.equalToSuperview().inset(10); $0.leading.trailing.equalToSuperview().inset(5) }
      button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(48) }; button.accessibilityIdentifier = "catalog.category." + value.rawValue
      button.accessibilityTraits = selected ? [.button, .selected] : .button; categoryStack.addArrangedSubview(button)
    }
  }
  private func reset() {
    items = []; nextPage = 0; total = 0; fetchedCount = 0; loaded = false; hasMore = false; errorMessage = nil
    updateHeading(selection == nil ? app.text("食材大全", "Ingredient catalog") : app.text("选择食材", "Choose ingredient"))
    search.placeholder = app.text("搜索食材名称或别名", "Search ingredient names or aliases")
    renderCategories(); render(); collection.setContentOffset(.zero, animated: false); load()
  }
  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    debounce?.cancel(); debounce = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 300_000_000); try Task.checkCancellation(); guard let self else { return }; self.query = searchText.trimmingCharacters(in: .whitespacesAndNewlines); self.reset() } catch {}
    }
  }
  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { debounce?.cancel(); query = (searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines); searchBar.resignFirstResponder(); reset() }
  private func load(append: Bool = false, force: Bool = false) {
    let requestedCategory = category, requestedQuery = query, household = app.planningHouseholdID, language = app.interfaceLanguage
    let page = append ? nextPage : 0
    var parameters = ["category": category.rawValue, "q": query, "page": String(page)]
    parameters["householdId"] = household
    if !inventoryOnly { parameters["type"] = "INGREDIENT"; parameters["inventoryScope"] = household == nil ? "personal" : "household" }
    execute(reloadOnFailure: true, loadingMore: append, showsInitialReadProgress: false) { [self] in
      do {
        var rows: [QFCatalogItem], count: Int, received: Int
        if inventoryOnly {
          let response: QFContentPage<QFInventoryLot> = try await QFContentLoadingContext.$forceRefresh.withValue(force) { try await app.contentRequest(path: "me/inventory", query: parameters) }
          rows = response.items.filter { $0.contentAvailable && (Decimal(string: $0.currentQuantity) ?? 0) > 0 }.map { lot in
            QFCatalogItem(id: lot.ingredientId, type: "INGREDIENT", title: lot.ingredientName ?? "", subtitle: "", mediaId: nil, materials: [], steps: [], minutes: nil, sourceName: nil, sourceUrl: nil, license: nil, licenseUrl: nil, attribution: nil, categoryCode: lot.categoryCode, iconKey: lot.iconKey, inStock: true)
          }; count = response.total; received = response.items.count
        } else {
          let response: QFContentPage<QFCatalogItem> = try await QFContentLoadingContext.$forceRefresh.withValue(force) { try await app.contentRequest(path: "catalog", query: parameters) }
          rows = response.items; count = response.total; received = response.items.count
        }
        try Task.checkCancellation(); guard requestedCategory == category, requestedQuery == query, language == app.interfaceLanguage, household == app.planningHouseholdID else { throw CancellationError() }
        if !append { items = []; fetchedCount = 0 }
        var ids = Set(items.map(\.id)); items.append(contentsOf: rows.filter { ids.insert($0.id).inserted }); fetchedCount += received
        total = count; nextPage = page + 1; hasMore = received > 0 && fetchedCount < total; loaded = true; errorMessage = nil; render()
      } catch is CancellationError { throw CancellationError() }
      catch { if append { throw error }; errorMessage = Self.errorText(error, app: app); render() }
    }
  }
  private func render() {
    var snapshot = NSDiffableDataSourceSnapshot<Int, String>(); snapshot.appendSections([0]); snapshot.appendItems(items.map(\.id))
    snapshot.reconfigureItems(items.map(\.id).filter { source.snapshot().itemIdentifiers.contains($0) }); source.apply(snapshot, animatingDifferences: false, completion: nil)
    state.text = errorMessage ?? (loaded ? app.text("没有找到符合条件的条目", "No matching items") : app.text("正在加载", "Loading")); collection.backgroundView = items.isEmpty ? state : nil
    setLoadMoreAction(hasMore ? { [weak self] in self?.load(append: true) } : nil)
  }
  func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
    CGSize(width: max(90, floor((collection.bounds.width - 12) / 2)), height: 190)
  }
  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard let id = source.itemIdentifier(for: indexPath), let item = items.first(where: { $0.id == id }) else { return }
    if let selection { qfClose { selection(item) } }
    else { open(QFCatalogDetailViewController(app: app, type: "INGREDIENT", id: item.id)) }
  }
}

@MainActor private final class QFIngredientCatalogCell: UICollectionViewCell {
  func configure(_ item: QFCatalogItem, app: QFAppSession) {
    contentView.subviews.forEach { $0.removeFromSuperview() }; contentView.backgroundColor = QFUI.surface; contentView.layer.cornerRadius = 20
    let name = QFTabUI.label(item.title, size: 17, weight: .semibold, lines: 2); name.textAlignment = .center
    let category = QFIngredientCategory(rawValue: item.categoryCode ?? "")?.title(app) ?? item.subtitle
    let caption = QFTabUI.label(category, size: 12, color: QFUI.secondary, lines: 2); caption.textAlignment = .center
    let stock = QFTabUI.label(item.inStock == true ? app.text("家里有", "In stock") : "", size: 12, color: QFUI.green, lines: 2); stock.textAlignment = .center
    stock.backgroundColor = item.inStock == true ? QFUI.paleGreen : .clear; stock.layer.cornerRadius = 12; stock.clipsToBounds = true; stock.snp.makeConstraints { $0.height.greaterThanOrEqualTo(24) }
    let stack = QFTabUI.stack([QFInventoryArtwork.make(ingredientID: item.id, category: item.categoryCode, iconKey: item.iconKey), name, caption, stock], spacing: 8); stack.alignment = .center
    contentView.addSubview(stack); stack.snp.makeConstraints { $0.center.equalToSuperview(); $0.leading.trailing.equalToSuperview().inset(8); $0.top.greaterThanOrEqualToSuperview().offset(12); $0.bottom.lessThanOrEqualToSuperview().inset(12) }
    [name,caption,stock].forEach { $0.snp.makeConstraints { $0.width.lessThanOrEqualTo(stack) } }
    accessibilityIdentifier = "ingredient.card." + item.id; isAccessibilityElement = true; accessibilityLabel = [item.title, category, stock.text ?? ""].joined(separator: ", "); accessibilityTraits = .button
  }
}
