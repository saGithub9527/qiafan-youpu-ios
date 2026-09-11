import SnapKit
import UIKit

@MainActor
final class QFRecipeViewController: QFPageViewController {
  private var selectedCategory = "推荐"
  private let categories = ["推荐", "早餐", "家常菜", "快手菜", "肉类", "素菜", "海鲜", "小吃", "烘焙", "甜品", "饮品"]
  private var categoryButtons: [String: UIButton] = [:]
  private var categoryIndicators: [String: UIView] = [:]
  private var categoryScroll: UIScrollView!
  private var filters: UIStackView!
  private let list = QFTabUI.stack([], spacing: 12)
  private let sectionTitle = QFTabUI.label("为你推荐", size: 17, weight: .semibold)
  private let countLabel = QFTabUI.label("", size: 12, color: QFUI.secondary)
  private var cards: [QFRecipeCard] = []
  private var compact = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFTabUI.color(0xF5F6F8)
    contentStack.spacing = 8
    contentStack.addArrangedSubview(makeHeader())
    filters = makeFilters()
    contentStack.addArrangedSubview(filters)
    let clear = QFTabUI.button("清空筛选", size: 12, color: QFUI.secondary) { [weak self] in
      self?.selectCategory("推荐")
      self?.categoryScroll.setContentOffset(.zero, animated: true)
    }
    clear.accessibilityIdentifier = "recipe.clearFilters"
    clear.snp.makeConstraints { $0.height.greaterThanOrEqualTo(32) }
    let section = QFTabUI.stack(
      [sectionTitle, countLabel, UIView(), clear], axis: .horizontal, spacing: 10)
    section.alignment = .center
    contentStack.addArrangedSubview(section)
    list.accessibilityIdentifier = "recipe.list"
    contentStack.addArrangedSubview(list)
    selectCategory("推荐")
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let next = view.bounds.width < 360
    guard next != compact else { return }
    compact = next
    filters.axis = compact ? .vertical : .horizontal
    cards.forEach { $0.setCompact(compact) }
  }

  private func makeHeader() -> UIView {
    let row = QFTabUI.stack([], axis: .horizontal, spacing: 24)
    for name in categories {
      let button = QFTabUI.button(name, size: 17, weight: .semibold, color: QFUI.secondary) {
        [weak self] in
        self?.selectCategory(name)
      }
      button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 9, right: 0)
      button.accessibilityIdentifier = "recipe.category.\(name)"
      button.snp.makeConstraints {
        $0.width.greaterThanOrEqualTo(42)
        $0.height.equalTo(40)
      }
      let mark = UIView()
      mark.backgroundColor = QFUI.orange
      mark.layer.cornerRadius = 1.5
      mark.isUserInteractionEnabled = false
      button.addSubview(mark)
      mark.snp.makeConstraints {
        $0.centerX.equalToSuperview()
        $0.bottom.equalToSuperview().inset(6)
        $0.width.equalTo(32)
        $0.height.equalTo(3)
      }
      row.addArrangedSubview(button)
      categoryButtons[name] = button
      categoryIndicators[name] = mark
    }
    categoryScroll = QFTabUI.horizontalScroll(row, height: 40, identifier: "recipe.categories")
    let arrow = QFTabUI.symbol("chevron.right", size: 12, color: QFUI.secondary)
    let search = QFTabUI.iconButton("magnifyingglass", label: "搜索菜谱", size: 20) { [weak self] in
      self?.showUnavailable("搜索菜谱")
    }
    search.accessibilityIdentifier = "recipe.search"
    let header = QFTabUI.stack([categoryScroll, arrow, search], axis: .horizontal, spacing: 8)
    header.alignment = .center
    return header
  }

  private func makeFilters() -> UIStackView {
    let values = [("国家", "全球"), ("口味", "不限"), ("菜系", "全部"), ("评分", "不限")]
    let buttons = values.map { name, value -> UIView in
      let control = QFTabUI.button("", background: .white) { [weak self] in
        self?.showUnavailable("\(name)筛选")
      }
      control.layer.cornerRadius = 12
      control.layer.borderWidth = 1
      control.layer.borderColor = QFUI.border.cgColor
      control.accessibilityLabel = "\(name)，\(value)"
      control.accessibilityIdentifier = "recipe.filter.\(name)"
      let labels = QFTabUI.stack(
        [
          QFTabUI.label(name, size: 10.5, color: QFUI.secondary),
          QFTabUI.label(value, size: 12, weight: .medium),
        ], spacing: 4)
      let row = QFTabUI.stack(
        [labels, UIView(), QFTabUI.symbol("chevron.down", size: 9, color: QFUI.secondary)],
        axis: .horizontal, spacing: 3)
      row.alignment = .bottom
      row.isUserInteractionEnabled = false
      control.addSubview(row)
      row.snp.makeConstraints {
        $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 7, left: 11, bottom: 7, right: 10))
      }
      control.snp.makeConstraints { $0.height.greaterThanOrEqualTo(48) }
      return control
    }
    let first = QFTabUI.stack(Array(buttons.prefix(2)), axis: .horizontal, spacing: 6)
    let second = QFTabUI.stack(Array(buttons.suffix(2)), axis: .horizontal, spacing: 6)
    first.distribution = .fillEqually
    second.distribution = .fillEqually
    let outer = QFTabUI.stack([first, second], axis: .horizontal, spacing: 6)
    outer.distribution = .fillEqually
    return outer
  }

  private func selectCategory(_ name: String) {
    selectedCategory = name
    for (category, button) in categoryButtons {
      let selected = category == name
      // Selection is drawn by our text and underline, without UIButton's system selection fill.
      button.accessibilityTraits = selected ? [.button, .selected] : [.button]
      button.setTitleColor(selected ? QFUI.text : QFUI.secondary, for: .normal)
      button.titleLabel?.font = .systemFont(
        ofSize: selected ? 20 : 17, weight: selected ? .bold : .semibold)
      categoryIndicators[category]?.isHidden = !selected
    }
    let recipes = QFRecipeSample.all.filter { name == "推荐" || $0.categories.contains(name) }
    sectionTitle.text = name == "推荐" ? "为你推荐" : name
    countLabel.text = "\(recipes.count) 道菜"
    QFTabUI.clear(list)
    cards = recipes.map { recipe in
      QFRecipeCard(
        recipe: recipe, compact: compact,
        onOpen: { [weak self] in self?.showUnavailable(recipe.name) },
        onBookmark: { [weak self] in self?.showUnavailable("收藏菜谱") })
    }
    cards.forEach { list.addArrangedSubview($0) }
    if recipes.isEmpty {
      list.addArrangedSubview(QFTabUI.empty("还没有找到相关菜谱", detail: "换个分类，发现更多好味道"))
    }
  }
}

@MainActor
private final class QFRecipeCard: UIView {
  private let artwork = UIImageView()
  private let row: UIStackView

  init(
    recipe: QFRecipeSample, compact: Bool, onOpen: @escaping () -> Void,
    onBookmark: @escaping () -> Void
  ) {
    row = QFTabUI.stack([], axis: .horizontal, spacing: compact ? 10 : 14)
    super.init(frame: .zero)
    backgroundColor = .white
    layer.cornerRadius = 18
    let open = QFTabUI.button("", action: onOpen)
    open.accessibilityLabel =
      "\(recipe.name)，\(recipe.origin)，\(recipe.time)，评分\(recipe.rating)，\(recipe.saves)"
    open.accessibilityHint = "查看菜谱详情"
    addSubview(open)
    open.snp.makeConstraints { $0.edges.equalToSuperview() }
    artwork.image = UIImage(named: recipe.asset)
    artwork.contentMode = .scaleAspectFill
    artwork.backgroundColor = QFTabUI.color(0xFCF6EB)
    artwork.clipsToBounds = true
    artwork.layer.cornerRadius = 12
    artwork.snp.makeConstraints { $0.size.equalTo(compact ? 84 : 108) }
    let name = QFTabUI.label(recipe.name, size: 16, weight: .semibold, lines: 2)
    let title = UIView()
    title.addSubview(name)
    name.snp.makeConstraints {
      $0.top.leading.bottom.equalToSuperview()
      $0.trailing.equalToSuperview().inset(32)
    }
    let rating = QFTabUI.stack(
      [
        QFTabUI.label("★", size: 15, color: QFTabUI.color(0xE99A22)),
        QFTabUI.label(recipe.rating, size: 13, weight: .medium), UIView(),
        QFTabUI.label(recipe.saves, size: 11, color: QFUI.secondary),
      ], axis: .horizontal, spacing: 5)
    let details = QFTabUI.stack(
      [
        title, QFTabUI.label(recipe.origin, size: 12, color: QFUI.secondary, lines: 0),
        QFTabUI.label(recipe.time, size: 12, color: QFUI.secondary, lines: 0), rating,
      ], spacing: 7)
    row.addArrangedSubview(artwork)
    row.addArrangedSubview(details)
    row.alignment = .center
    row.isUserInteractionEnabled = false
    row.accessibilityElementsHidden = true
    addSubview(row)
    row.snp.makeConstraints {
      $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 14))
    }
    let bookmark = QFTabUI.iconButton(
      "bookmark", label: "收藏\(recipe.name)", size: 17, action: onBookmark)
    addSubview(bookmark)
    bookmark.snp.makeConstraints { $0.top.trailing.equalToSuperview().inset(6) }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func setCompact(_ compact: Bool) {
    artwork.snp.updateConstraints { $0.size.equalTo(compact ? 84 : 108) }
    row.spacing = compact ? 10 : 14
  }
}

/// Small UIKit composition helpers shared only by the four tab pages.
@MainActor
enum QFTabUI {
  static func color(_ hex: UInt) -> UIColor {
    UIColor(
      red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
      blue: CGFloat(hex & 255) / 255, alpha: 1)
  }
  static func label(
    _ text: String, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = QFUI.text,
    lines: Int = 1
  ) -> UILabel {
    let label = QFUI.label(text, size: size, weight: weight, color: color, lines: lines)
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
  }
  static func stack(
    _ views: [UIView], axis: NSLayoutConstraint.Axis = .vertical, spacing: CGFloat = 0
  ) -> UIStackView {
    QFUI.stack(views, axis: axis, spacing: spacing)
  }
  static func button(
    _ title: String, size: CGFloat = 14, weight: UIFont.Weight = .regular,
    color: UIColor = QFUI.text, background: UIColor = .clear, action: @escaping () -> Void
  ) -> UIButton {
    let button = QFUI.button(title, background: background, textColor: color)
    button.titleLabel?.font = .systemFont(ofSize: size, weight: weight)
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }
  static func symbol(_ name: String, size: CGFloat, color: UIColor = QFUI.text) -> UIImageView {
    let view = UIImageView(
      image: UIImage(
        systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size)))
    view.tintColor = color
    view.contentMode = .scaleAspectFit
    view.snp.makeConstraints { $0.size.equalTo(size + 2) }
    view.isAccessibilityElement = false
    return view
  }
  static func iconButton(
    _ name: String, label: String, size: CGFloat = 20, action: @escaping () -> Void
  ) -> UIButton {
    let button = self.button("", action: action)
    button.contentEdgeInsets = .zero
    button.setImage(
      UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size)),
      for: .normal)
    button.tintColor = QFUI.secondary
    button.accessibilityLabel = label
    button.snp.makeConstraints { $0.size.equalTo(40) }
    return button
  }
  static func card(
    _ content: UIView, padding: CGFloat = 14, background: UIColor = .white, border: Bool = false
  ) -> UIView {
    let card = UIView()
    card.backgroundColor = background
    card.layer.cornerRadius = 18
    if border {
      card.layer.borderWidth = 0.7
      card.layer.borderColor = QFUI.border.cgColor
    }
    card.addSubview(content)
    content.snp.makeConstraints { $0.edges.equalToSuperview().inset(padding) }
    return card
  }
  static func empty(_ title: String, detail: String) -> UIView {
    let titleLabel = label(title, size: 15, weight: .medium, color: QFUI.secondary, lines: 0)
    let detailLabel = label(detail, size: 12, color: QFUI.secondary, lines: 0)
    titleLabel.textAlignment = .center
    detailLabel.textAlignment = .center
    return card(stack([titleLabel, detailLabel], spacing: 8), padding: 28)
  }
  static func horizontalScroll(_ stack: UIStackView, height: CGFloat, identifier: String)
    -> UIScrollView
  {
    let scroll = UIScrollView()
    scroll.showsHorizontalScrollIndicator = false
    scroll.accessibilityIdentifier = identifier
    scroll.addSubview(stack)
    stack.snp.makeConstraints {
      $0.edges.equalTo(scroll.contentLayoutGuide)
      $0.height.equalTo(scroll.frameLayoutGuide)
    }
    scroll.snp.makeConstraints { $0.height.equalTo(height) }
    return scroll
  }
  static func clear(_ stack: UIStackView) {
    stack.arrangedSubviews.forEach {
      stack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
  }
}

private struct QFRecipeSample: Identifiable {

  var id: String { name }
  let name: String
  let origin: String
  let time: String
  let rating: String
  let saves: String
  let asset: String
  let categories: [String]

  static let all = [
    QFRecipeSample(
      name: "番茄炖牛腩", origin: "中国 · 家常菜", time: "90 分钟 · 2 人份",
      rating: "4.9", saves: "2,386 收藏", asset: "dish-stew", categories: ["家常菜", "肉类"]),
    QFRecipeSample(
      name: "番茄罗勒意面", origin: "意大利 · 意式料理", time: "25 分钟 · 2 人份",
      rating: "4.8", saves: "1,624 收藏", asset: "dish-noodles", categories: ["快手菜", "素菜"]),
    QFRecipeSample(
      name: "泰式打抛鸡", origin: "泰国 · 泰式料理", time: "20 分钟 · 2 人份",
      rating: "4.9", saves: "3,108 收藏", asset: "dish-rice", categories: ["家常菜", "快手菜", "肉类"]),
    QFRecipeSample(
      name: "照烧三文鱼饭", origin: "日本 · 日式料理", time: "25 分钟 · 2 人份",
      rating: "4.8", saves: "2,041 收藏", asset: "dish-seafood", categories: ["快手菜", "海鲜"]),
  ]
}
