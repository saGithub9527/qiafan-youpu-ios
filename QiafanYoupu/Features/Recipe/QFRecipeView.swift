import SnapKit
import UIKit

/// Small UIKit composition helpers shared by the first-level and content pages.
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
    _ name: String, label: String, size: CGFloat = 20,
    weight: UIImage.SymbolWeight = .regular, action: @escaping () -> Void
  ) -> UIButton {
    let button = UIButton(type: .system)
    button.setImage(
      UIImage(
        systemName: name,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight)),
      for: .normal)
    button.tintColor = QFUI.secondary
    button.imageView?.contentMode = .scaleAspectFit
    button.contentHorizontalAlignment = .center
    button.contentVerticalAlignment = .center
    button.accessibilityLabel = label
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    button.snp.makeConstraints { $0.size.equalTo(44) }
    return button
  }
  static func card(
    _ content: UIView, padding: CGFloat = 14, background: UIColor = QFUI.surface, border: Bool = false
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
