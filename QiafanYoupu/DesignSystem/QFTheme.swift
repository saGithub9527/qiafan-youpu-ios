import Combine
import SnapKit
import UIKit

enum QFUI {
  static let background = UIColor(hex: 0xF8F8F3)
  static let text = UIColor(hex: 0x202A25)
  static let secondary = UIColor(hex: 0x788176)
  static let orange = UIColor(hex: 0xF46236)
  static let green = UIColor(hex: 0x5D754E)
  static let paleGreen = UIColor(hex: 0xEDF2E5)
  static let border = UIColor(hex: 0xE3E7DC)

  static func label(
    _ text: String, size: CGFloat = 15, weight: UIFont.Weight = .regular,
    color: UIColor = QFUI.text, lines: Int = 0
  ) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = UIFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.numberOfLines = lines
    return label
  }

  static func button(
    _ title: String, background: UIColor = QFUI.orange, textColor: UIColor = .white
  ) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.setTitleColor(textColor, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
    button.titleLabel?.numberOfLines = 0
    button.titleLabel?.textAlignment = .center
    button.backgroundColor = background
    button.layer.cornerRadius = 14
    button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    return button
  }

  static func stack(
    _ views: [UIView], axis: NSLayoutConstraint.Axis = .vertical, spacing: CGFloat = 12
  ) -> UIStackView {
    let stack = UIStackView(arrangedSubviews: views)
    stack.axis = axis
    stack.spacing = spacing
    return stack
  }
}

extension UIColor {
  convenience init(hex: UInt, alpha: CGFloat = 1) {
    self.init(
      red: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
  }
}

/// Shared page shell; UIKit owns the view hierarchy and SnapKit owns its constraints.
@MainActor
class QFPageViewController: UIViewController {
  let app: QFAppSession
  let scrollView = UIScrollView()
  let contentStack = UIStackView()
  var cancellables = Set<AnyCancellable>()

  init(app: QFAppSession) {
    self.app = app
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = false
    scrollView.keyboardDismissMode = .onDrag
    view.addSubview(scrollView)
    scrollView.snp.makeConstraints { $0.edges.equalTo(view.safeAreaLayoutGuide) }
    let content = UIView()
    scrollView.addSubview(content)
    content.snp.makeConstraints {
      $0.edges.equalTo(scrollView.contentLayoutGuide)
      $0.width.equalTo(scrollView.frameLayoutGuide)
    }
    contentStack.axis = .vertical
    contentStack.spacing = 16
    content.addSubview(contentStack)
    contentStack.snp.makeConstraints {
      $0.top.equalToSuperview().offset(14)
      $0.bottom.equalToSuperview().inset(24)
      $0.centerX.equalToSuperview()
      $0.leading.greaterThanOrEqualToSuperview().offset(20)
      $0.trailing.lessThanOrEqualToSuperview().inset(20)
      $0.width.equalToSuperview().offset(-40).priority(999)
      $0.width.lessThanOrEqualTo(QFAdaptiveLayout.contentMaxWidth - 40)
    }
  }

  func showUnavailable(_ title: String) {
    let alert = UIAlertController(title: title, message: "该功能暂未开放", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "知道了", style: .default))
    present(alert, animated: true)
  }
}
