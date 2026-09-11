import SnapKit
import UIKit

@MainActor
final class QFIngredientViewController: QFPageViewController, UITextFieldDelegate {
  private var shopping = false
  private var selectedCategory = "全部"
  private var nearDateFirst = true
  private let categories = ["全部", "蔬菜", "肉蛋", "奶制品", "水果", "谷物", "水产", "菌藻", "调味"]
  private let searchField = UITextField()
  private let segment = UISegmentedControl(items: ["家里已有 · 12", "待采购 · 3"])
  private let list = QFTabUI.stack([], spacing: 10)
  private let listTitle = QFTabUI.label("我的食材", size: 17, weight: .semibold)
  private var sorting: UIButton!
  private var notice: UIButton!
  private var discovery: UIStackView!
  private var categoryButtons: [String: UIButton] = [:]
  private var compact = false

  override func viewDidLoad() {
    super.viewDidLoad()
    scrollView.keyboardDismissMode = .onDrag
    contentStack.addArrangedSubview(makeHeader())
    contentStack.addArrangedSubview(makeSearch())
    discovery = QFTabUI.stack(
      [
        discoveryButton(
          "食材大全", subtitle: "分类查找，认识食材", symbol: "book.closed", background: QFUI.paleGreen,
          accent: QFUI.green),
        discoveryButton(
          "食材组合推荐", subtitle: "选食材，看看能做什么", symbol: "circle", background: QFTabUI.color(0xFFF0E7),
          accent: QFUI.orange),
      ], axis: .horizontal, spacing: 12)
    discovery.distribution = .fillEqually
    contentStack.addArrangedSubview(discovery)
    segment.selectedSegmentIndex = 0
    segment.accessibilityIdentifier = "ingredient.segment"
    segment.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.shopping = self.segment.selectedSegmentIndex == 1
        self.refreshList()
      }, for: .valueChanged)
    segment.snp.makeConstraints { $0.height.equalTo(36) }
    contentStack.addArrangedSubview(
      QFTabUI.card(segment, padding: 4, background: QFTabUI.color(0xE9EDE2)))
    notice = QFTabUI.button("", background: QFTabUI.color(0xFFF4DC)) { [weak self] in
      self?.unavailable("临期食材")
    }
    notice.accessibilityLabel = "2 种食材临近标注日期，查看"
    let noticeText = QFTabUI.label(
      "2 种食材临近标注日期", size: 12, color: QFTabUI.color(0xA16A17), lines: 0)
    let noticeAction = QFTabUI.label(
      "查看  ›", size: 12, weight: .medium, color: QFTabUI.color(0xA16A17))
    noticeAction.setContentCompressionResistancePriority(.required, for: .horizontal)
    let noticeRow = QFTabUI.stack(
      [
        QFTabUI.symbol("clock", size: 17, color: QFTabUI.color(0xA16A17)), noticeText, UIView(),
        noticeAction,
      ], axis: .horizontal, spacing: 9)
    noticeRow.alignment = .center
    noticeRow.isUserInteractionEnabled = false
    noticeRow.accessibilityElementsHidden = true
    notice.addSubview(noticeRow)
    noticeRow.snp.makeConstraints {
      $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))
    }
    contentStack.addArrangedSubview(notice)
    contentStack.addArrangedSubview(makeCategories())
    sorting = QFTabUI.button("", size: 12, color: QFUI.secondary) { [weak self] in
      guard let self else { return }
      self.nearDateFirst.toggle()
      self.refreshList()
    }
    sorting.snp.makeConstraints { $0.height.greaterThanOrEqualTo(32) }
    let heading = QFTabUI.stack([listTitle, UIView(), sorting], axis: .horizontal, spacing: 8)
    heading.alignment = .center
    contentStack.addArrangedSubview(heading)
    list.accessibilityIdentifier = "ingredient.list"
    contentStack.addArrangedSubview(list)
    refreshCategories()
    refreshList()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let next = view.bounds.width < 360
    guard next != compact else { return }
    compact = next
    discovery.axis = compact ? .vertical : .horizontal
  }

  private func makeHeader() -> UIView {
    let heading = QFTabUI.stack(
      [
        QFTabUI.label("食材", size: 28, weight: .bold),
        QFTabUI.label("把家里的食材用起来", size: 12, color: QFUI.secondary, lines: 0),
      ], spacing: 6)
    let scan = QFTabUI.iconButton("qrcode.viewfinder", label: "扫描小票二维码") { [weak self] in
      self?.unavailable("扫描小票二维码")
    }
    scan.backgroundColor = .white
    scan.layer.cornerRadius = 14
    scan.accessibilityIdentifier = "ingredient.scan"
    let add = QFTabUI.button(
      "＋ 添加", size: 14, weight: .semibold, color: .white, background: QFUI.orange
    ) { [weak self] in self?.unavailable("添加食材") }
    add.accessibilityIdentifier = "ingredient.add"
    add.contentEdgeInsets = .zero
    add.snp.makeConstraints {
      $0.width.equalTo(72)
      $0.height.equalTo(40)
    }
    let row = QFTabUI.stack([heading, scan, add], axis: .horizontal, spacing: 10)
    row.alignment = .center
    return row
  }

  private func makeSearch() -> UIView {
    searchField.placeholder = "搜索食材名称"
    searchField.font = .systemFont(ofSize: 14)
    searchField.textColor = QFUI.text
    searchField.tintColor = QFUI.orange
    searchField.clearButtonMode = .whileEditing
    searchField.returnKeyType = .search
    searchField.delegate = self
    searchField.accessibilityLabel = "搜索食材名称"
    searchField.accessibilityIdentifier = "ingredient.search"
    searchField.addAction(UIAction { [weak self] _ in self?.refreshList() }, for: .editingChanged)
    let icon = QFTabUI.symbol("magnifyingglass", size: 19, color: QFUI.secondary)
    let row = QFTabUI.stack([icon, searchField], axis: .horizontal, spacing: 12)
    row.alignment = .center
    row.snp.makeConstraints { $0.height.equalTo(22) }
    return QFTabUI.card(row, padding: 11, border: true)
  }

  private func discoveryButton(
    _ title: String, subtitle: String, symbol: String, background: UIColor, accent: UIColor
  ) -> UIButton {
    let button = QFTabUI.button("", background: background) { [weak self] in
      self?.unavailable(title)
    }
    button.accessibilityLabel = title
    button.accessibilityHint = subtitle
    let icon = UIView()
    let first = QFTabUI.symbol(symbol, size: 21, color: accent)
    icon.addSubview(first)
    first.snp.makeConstraints { $0.top.leading.equalToSuperview() }
    icon.snp.makeConstraints {
      $0.width.equalTo(29)
      $0.height.equalTo(32)
    }
    if symbol == "circle" {
      let second = QFTabUI.symbol("circle", size: 19, color: accent)
      icon.addSubview(second)
      second.snp.makeConstraints {
        $0.leading.equalToSuperview().offset(7)
        $0.top.equalToSuperview().offset(9)
      }
    }
    let titleLabel = QFTabUI.label(title, size: 16, weight: .semibold, lines: 2)
    let heading = QFTabUI.stack([titleLabel, UIView(), icon], axis: .horizontal, spacing: 4)
    heading.alignment = .top
    let body = QFTabUI.stack(
      [heading, QFTabUI.label(subtitle, size: 11, color: accent, lines: 0)], spacing: 4)
    body.isUserInteractionEnabled = false
    body.accessibilityElementsHidden = true
    button.addSubview(body)
    body.snp.makeConstraints { $0.edges.equalToSuperview().inset(13) }
    button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(74) }
    return button
  }

  private func makeCategories() -> UIView {
    let row = QFTabUI.stack([], axis: .horizontal, spacing: 8)
    for category in categories {
      let button = QFTabUI.button(
        category, size: 13, weight: .semibold, color: QFUI.secondary, background: .white
      ) { [weak self] in
        self?.selectedCategory = category
        self?.refreshCategories()
        self?.refreshList()
      }
      button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 15, bottom: 0, right: 15)
      button.layer.cornerRadius = 16
      button.layer.borderWidth = 1
      button.accessibilityIdentifier = "ingredient.category.\(category)"
      row.addArrangedSubview(button)
      categoryButtons[category] = button
    }
    return QFTabUI.horizontalScroll(row, height: 32, identifier: "ingredient.categories")
  }

  private func refreshCategories() {
    for (category, button) in categoryButtons {
      let selected = selectedCategory == category
      // Keep the custom pill appearance and expose selection only through accessibility.
      button.accessibilityTraits = selected ? [.button, .selected] : [.button]
      button.backgroundColor = selected ? QFUI.paleGreen : .white
      button.layer.borderColor = (selected ? UIColor.clear : QFUI.border).cgColor
      button.setTitleColor(selected ? QFUI.green : QFUI.secondary, for: .normal)
    }
  }

  private func refreshList() {
    let query = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let source = shopping ? QFIngredientSample.shopping : QFIngredientSample.inventory
    let ordered =
      !shopping && !nearDateFirst
      ? source.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : source
    let ingredients = ordered.filter {
      (selectedCategory == "全部" || $0.category == selectedCategory)
        && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
    }
    if shopping, notice.superview != nil {
      contentStack.removeArrangedSubview(notice)
      notice.removeFromSuperview()
    } else if !shopping, notice.superview == nil {
      contentStack.insertArrangedSubview(notice, at: 4)
    }
    listTitle.text = shopping ? "待采购食材" : "我的食材"
    sorting.setTitle(shopping ? "预计 ¥16.20" : (nearDateFirst ? "临期优先  ﹀" : "默认排序  ﹀"), for: .normal)
    sorting.isEnabled = !shopping
    sorting.accessibilityLabel =
      shopping ? "预计花费16.20元" : (nearDateFirst ? "食材排序，临期优先" : "食材排序，默认排序")
    QFTabUI.clear(list)
    ingredients.forEach { list.addArrangedSubview(makeCard($0)) }
    if ingredients.isEmpty {
      list.addArrangedSubview(QFTabUI.empty("没有找到相关食材", detail: "换个名称或分类试试"))
    }
  }

  private func makeCard(_ ingredient: QFIngredientSample) -> UIView {
    let artwork = UIView()
    artwork.layer.cornerRadius = 12
    artwork.backgroundColor =
      ingredient.id == "milk"
      ? QFTabUI.color(0xE7F1F5)
      : (ingredient.id == "egg" ? QFTabUI.color(0xFFF0D9) : QFUI.paleGreen)
    artwork.snp.makeConstraints { $0.size.equalTo(48) }
    let fallbackByCategory = [
      "肉蛋": "meat", "蔬菜": "vegetable", "奶制品": "milk", "水果": "fruit", "谷物": "grain", "水产": "seafood",
      "菌藻": "mushroom", "调味": "seasoning",
    ]
    let fallback = fallbackByCategory[ingredient.category] ?? "generic"
    let image = UIImageView(
      image: UIImage(named: "ingredient-\(ingredient.id)") ?? UIImage(
        named: "ingredient-\(fallback)") ?? UIImage(named: "ingredient-generic"))
    image.contentMode = .scaleAspectFit
    artwork.addSubview(image)
    image.snp.makeConstraints {
      $0.center.equalToSuperview()
      $0.size.equalTo(36)
    }
    let details = QFTabUI.stack(
      [
        QFTabUI.label(ingredient.name, size: 17, weight: .semibold, lines: 2),
        QFTabUI.label(ingredient.amount, size: 12, lines: 0),
      ], spacing: 9)
    let more = QFTabUI.iconButton("ellipsis", label: "\(ingredient.name)，更多操作", size: 18) {
      [weak self] in self?.unavailable("\(ingredient.name)管理")
    }
    let top = QFTabUI.stack([], axis: .horizontal, spacing: 5)
    top.alignment = .center
    if !shopping {
      let storage = QFTabUI.label(ingredient.storage, size: 10.5, color: QFUI.green)
      storage.textAlignment = .center
      storage.backgroundColor = QFUI.paleGreen
      storage.clipsToBounds = true
      storage.layer.cornerRadius = 11
      storage.snp.makeConstraints {
        $0.width.equalTo(42)
        $0.height.equalTo(22)
      }
      top.addArrangedSubview(storage)
    }
    top.addArrangedSubview(more)
    let date = QFTabUI.label(
      shopping ? ingredient.price : ingredient.date, size: 10.5,
      color: shopping ? QFUI.orange : (ingredient.near ? QFTabUI.color(0xA66C1E) : QFUI.secondary))
    date.textAlignment = .right
    let status = QFTabUI.stack([top, date], spacing: 0)
    status.alignment = .trailing
    status.snp.makeConstraints { $0.width.equalTo(92) }
    let row = QFTabUI.stack([artwork, details, status], axis: .horizontal, spacing: 8)
    row.alignment = .center
    return QFTabUI.card(row, padding: 13, border: true)
  }

  private func unavailable(_ title: String) {
    view.endEditing(true)
    showUnavailable(title)
  }
  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder()
    return true
  }
}

private struct QFIngredientSample: Identifiable {

  let id: String
  let name: String
  let category: String
  let amount: String
  var storage = ""
  var date = ""
  var near = false
  var price = ""

  static let inventory = [
    QFIngredientSample(
      id: "broccoli", name: "西兰花", category: "蔬菜", amount: "1 棵 · 约 300 克",
      storage: "冷藏", date: "9月10日到期", near: true),
    QFIngredientSample(
      id: "milk", name: "鲜牛奶", category: "奶制品", amount: "1 盒 · 1 升",
      storage: "冷藏", date: "9月11日到期", near: true),
    QFIngredientSample(
      id: "egg", name: "鸡蛋", category: "肉蛋", amount: "6 个",
      storage: "冷藏", date: "9月18日到期"),
    QFIngredientSample(
      id: "tomato", name: "番茄", category: "蔬菜", amount: "500 克",
      storage: "冷藏", date: "9月15日到期"),
    QFIngredientSample(
      id: "chicken", name: "鸡胸肉", category: "肉蛋", amount: "400 克",
      storage: "冷冻", date: "10月9日到期"),
    QFIngredientSample(
      id: "beef", name: "牛腩", category: "肉蛋", amount: "500 克",
      storage: "冷冻", date: "10月9日到期"),
    QFIngredientSample(id: "rice", name: "大米", category: "谷物", amount: "2,000 克", storage: "常温"),
    QFIngredientSample(id: "flour", name: "面粉", category: "谷物", amount: "500 克", storage: "常温"),
    QFIngredientSample(id: "oil", name: "食用油", category: "调味", amount: "500 毫升", storage: "常温"),
    QFIngredientSample(id: "seaweed", name: "紫菜", category: "菌藻", amount: "20 克", storage: "常温"),
    QFIngredientSample(
      id: "carrot", name: "胡萝卜", category: "蔬菜", amount: "300 克",
      storage: "冷藏", date: "9月20日到期"),
    QFIngredientSample(
      id: "apple", name: "苹果", category: "水果", amount: "2 个",
      storage: "冷藏", date: "9月20日到期"),
  ]

  static let shopping = [
    QFIngredientSample(
      id: "tomato", name: "番茄", category: "蔬菜", amount: "500 克", price: "预计 ¥6.00"),
    QFIngredientSample(id: "egg", name: "鸡蛋", category: "肉蛋", amount: "6 个", price: "预计 ¥7.20"),
    QFIngredientSample(
      id: "salt", name: "盐", category: "调味", amount: "1 袋 · 500 克", price: "预计 ¥3.00"),
  ]
}
