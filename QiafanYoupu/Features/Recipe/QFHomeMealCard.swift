import SnapKit
import UIKit

@MainActor
final class QFHomeMealCard: UIControl {
  private let caption = UILabel()
  private let title = UILabel()
  private let detail = UILabel()
  private let arrow = UIImageView(image: UIImage(systemName: "chevron.right"))
  private weak var app: QFAppSession?
  private var entry: QFMealSurfaceEntry?

  init(app: QFAppSession) {
    self.app = app
    super.init(frame: .zero)
    backgroundColor = QFUI.surface
    layer.cornerRadius = 16
    accessibilityIdentifier = "recipe.nextMeal"
    isAccessibilityElement = true
    accessibilityTraits = .button
    caption.font = .preferredFont(forTextStyle: .caption1)
    caption.textColor = QFUI.primary
    title.font = .preferredFont(forTextStyle: .headline)
    title.textColor = QFUI.text
    title.numberOfLines = 2
    detail.font = .preferredFont(forTextStyle: .caption1)
    detail.textColor = QFUI.secondary
    detail.numberOfLines = 2
    [caption, title, detail].forEach { $0.adjustsFontForContentSizeCategory = true }
    let stack = UIStackView(arrangedSubviews: [caption, title, detail])
    stack.axis = .vertical; stack.spacing = 5; stack.isUserInteractionEnabled = false
    addSubview(stack); addSubview(arrow)
    arrow.tintColor = QFUI.secondary
    stack.snp.makeConstraints { $0.leading.top.bottom.equalToSuperview().inset(13); $0.trailing.equalTo(arrow.snp.leading).offset(-10) }
    arrow.snp.makeConstraints { $0.trailing.equalToSuperview().inset(13); $0.centerY.equalToSuperview(); $0.width.equalTo(9); $0.height.equalTo(15) }
    addTarget(self, action: #selector(openPlan), for: .touchUpInside)
    render(nil, loading: false)
  }
  required init?(coder: NSCoder) { nil }

  func render(_ document: QFMealSurfaceDocument?, loading: Bool) {
    guard let app else { return }
    let status = QFMealSurfaceSelector.effectiveStatus(in: document, now: Date())
    entry = document.flatMap { QFMealSurfaceSelector.currentEntry(in: $0, now: Date()) }
    caption.text = app.text("下一餐", "Next meal")
    if let meal = entry {
      let formatter = DateFormatter(); formatter.locale = Locale(identifier: app.interfaceLanguage)
      formatter.timeZone = TimeZone(identifier: meal.timezone); formatter.setLocalizedDateFormatFromTemplate("MMM d EEE HH:mm")
      let mealName = QFCookingMeal(rawValue: meal.meal)?.title(app: app) ?? ""
      caption.text = mealName + " · " + formatter.string(from: meal.scheduledAt)
      title.text = meal.recipeTitles.isEmpty ? app.text("查看这一餐的计划", "View this meal plan") : meal.recipeTitles.joined(separator: " · ")
      let needs = meal.requiredIngredients.joined(separator: "、")
      if !meal.stockKnown {
        detail.text = needs.isEmpty ? app.text("打开计划核对食材", "Open the plan to check ingredients") : app.text("需要：", "Needed: ") + needs + " · " + app.text("库存待核对", "Check stock")
      } else if !meal.missingIngredients.isEmpty {
        detail.text = app.text("需要补购：", "To buy: ") + meal.missingIngredients.joined(separator: "、")
      } else {
        detail.text = app.text("家里已有：", "In stock: ") + meal.inStockIngredients.joined(separator: "、")
      }
    } else {
      switch status {
      case .signedOut:
        title.text = app.text("登录后查看下一餐", "Sign in to see your next meal")
        detail.text = app.text("计划、库存和餐前准备会同步显示在这里", "Your meal plan and ingredient preparation appear here")
      case .disabled:
        title.text = app.text("计划提醒已关闭", "Meal reminders are off")
        detail.text = app.text("前往计划页面调整提醒设置", "Manage reminders on the Plan page")
      case .empty:
        title.text = app.text("接下来还没有安排用餐", "No upcoming meals planned")
        detail.text = app.text("去制定计划，提前准备好下一餐", "Plan a meal and get the ingredients ready")
      case .ready, .unavailable:
        title.text = loading ? app.text("正在更新下一餐…", "Updating your next meal…") : app.text("下一餐暂未更新", "Next meal needs refreshing")
        detail.text = app.text("打开计划查看最新安排", "Open Plan to see the latest schedule")
      }
    }
    accessibilityLabel = [caption.text, title.text, detail.text].compactMap { $0 }.joined(separator: "，")
    accessibilityHint = app.text("打开计划", "Open Plan")
  }

  @objc private func openPlan() {
    let url = entry.flatMap { QFMealSurfaceSelector.deepLink(for: $0) } ?? URL(string: "qiafanyoupu://meal-plan")!
    QFMealSurfaceNavigation.shared.open(url)
  }
  override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.72 : 1 } }
}
