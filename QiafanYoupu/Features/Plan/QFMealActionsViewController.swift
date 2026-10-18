import SnapKit
import UIKit

/// Approved screen 05 is a contextual bottom sheet, not a page navigation.
enum QFMealAdjustmentLayout {
  static let pageInset: CGFloat = 20
  static let rowHeight: CGFloat = 44
  static let rowRadius: CGFloat = 12
  static let rowGap: CGFloat = 6
  static let sheetRadius: CGFloat = 26
}

@MainActor
final class QFMealActionsViewController: UIViewController {
  enum Action { case replace, move, toggleSkipped, remove }
  private let app: QFAppSession
  private let items: [QFPlannedMeal]
  private let chosen: (QFPlannedMeal, Action) -> Void
  private let stack = UIStackView()
  private var selected: QFPlannedMeal?

  init(app: QFAppSession, items: [QFPlannedMeal], chosen: @escaping (QFPlannedMeal, Action) -> Void) {
    self.app = app; self.items = items; self.chosen = chosen
    selected = items.count == 1 ? items.first : nil
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
    if let sheet = sheetPresentationController {
      if #available(iOS 16.0, *) {
        sheet.detents = [.custom(identifier: .init("meal-actions")) { context in
          min(440, context.maximumDetentValue)
        }, .large()]
      } else { sheet.detents = [.large()] }
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = QFMealAdjustmentLayout.sheetRadius
    }
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.accessibilityIdentifier = "plan.adjust.sheet"
    let scroll = UIScrollView()
    scroll.alwaysBounceVertical = false
    view.addSubview(scroll)
    scroll.snp.makeConstraints { $0.edges.equalTo(view.safeAreaLayoutGuide) }
    stack.axis = .vertical; stack.spacing = 12
    scroll.addSubview(stack)
    stack.snp.makeConstraints {
      $0.edges.equalTo(scroll.contentLayoutGuide).inset(UIEdgeInsets(top: 22, left: 20, bottom: 24, right: 20))
      $0.width.equalTo(scroll.frameLayoutGuide).offset(-40)
    }
    render()
  }
  private func render() {
    QFTabUI.clear(stack)
    let title = QFContentUI.label(app.text("调整当餐计划", "Edit meal plan"), size: 21, bold: true)
    let close = QFTabUI.iconButton("xmark", label: app.text("关闭", "Close"), size: 20) { [weak self] in self?.dismiss(animated: true) }
    close.accessibilityIdentifier = "plan.adjust.close"
    let heading = QFTabUI.stack([title, UIView(), close], axis: .horizontal, spacing: 8)
    heading.alignment = .center; stack.addArrangedSubview(heading)
    guard let item = selected else {
      for dish in items {
        let row = actionRow(title: displayTitle(dish), icon: dish.completed ? "checkmark.circle" : dish.skipped ? "minus.circle" : "circle", id: "select.\(dish.id)") { [weak self] in
          self?.selected = dish; self?.render()
        }
        stack.addArrangedSubview(row)
      }
      return
    }
    let context = "\(item.date) · \(QFCookingMeal(rawValue: item.meal)?.title(app: app) ?? item.meal)"
    stack.addArrangedSubview(QFContentUI.label(context, size: 13, color: QFUI.secondary))
    let name = QFContentUI.label(displayTitle(item), size: 18, bold: true)
    name.numberOfLines = 0
    let status = QFContentUI.label(item.completed ? app.text("已完成", "Completed") : item.skipped ? app.text("已跳过", "Skipped") : app.text("待完成", "Pending"), size: 13, color: QFUI.green)
    status.setContentCompressionResistancePriority(.required, for: .horizontal)
    let detail = QFTabUI.stack([name, status], axis: .horizontal, spacing: 12)
    detail.alignment = .center; stack.addArrangedSubview(detail)
    stack.setCustomSpacing(18, after: detail)
    let actions = QFTabUI.stack([], spacing: QFMealAdjustmentLayout.rowGap)
    let replace = actionRow(title: app.text("换菜", "Replace recipe"), icon: "pencil", id: "replace") { [weak self] in self?.choose(.replace) }
    replace.isEnabled = !item.completed; replace.alpha = item.completed ? 0.4 : 1
    actions.addArrangedSubview(replace)
    actions.addArrangedSubview(actionRow(title: app.text("移动日期 / 餐次", "Move date / meal"), icon: "chevron.right", id: "move") { [weak self] in self?.choose(.move) })
    let skip = actionRow(title: item.skipped ? app.text("恢复本次计划", "Restore this plan") : app.text("跳过本次", "Skip this occurrence"), icon: item.skipped ? "arrow.uturn.backward" : "xmark", id: "skip") { [weak self] in self?.choose(.toggleSkipped) }
    skip.isEnabled = !item.completed; skip.alpha = item.completed ? 0.4 : 1
    actions.addArrangedSubview(skip)
    actions.addArrangedSubview(actionRow(title: app.text("移出计划", "Remove from plan"), icon: "trash", id: "remove", destructive: true) { [weak self] in self?.choose(.remove) })
    stack.addArrangedSubview(actions)
    if items.count > 1 {
      stack.addArrangedSubview(QFTabUI.button(app.text("选择其他菜品", "Choose another dish"), size: 13, color: QFUI.secondary) { [weak self] in
        self?.selected = nil; self?.render()
      })
    }
  }
  private func displayTitle(_ item: QFPlannedMeal) -> String {
    item.contentAvailable ? (item.title ?? app.text("未命名菜谱", "Untitled recipe")) : app.text("当前语言内容不可用", "Content unavailable in this language")
  }
  private func actionRow(title: String, icon: String, id: String, destructive: Bool = false, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    var config = UIButton.Configuration.plain()
    config.title = title; config.image = UIImage(systemName: icon)
    config.imagePadding = 14
    config.baseForegroundColor = destructive ? QFUI.orange : QFUI.text
    config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 32)
    button.configuration = config; button.contentHorizontalAlignment = .leading
    button.backgroundColor = QFUI.surface; button.layer.cornerRadius = QFMealAdjustmentLayout.rowRadius
    button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(QFMealAdjustmentLayout.rowHeight) }
    let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    chevron.tintColor = QFUI.secondary; chevron.contentMode = .scaleAspectFit
    button.addSubview(chevron)
    chevron.snp.makeConstraints { $0.trailing.equalToSuperview().inset(16); $0.centerY.equalToSuperview(); $0.width.equalTo(9); $0.height.equalTo(14) }
    button.accessibilityIdentifier = "plan.adjust.\(id)"
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }
  private func choose(_ action: Action) {
    guard let selected else { return }
    let completion = chosen
    dismiss(animated: true) { completion(selected, action) }
  }
}
