import Combine
import SnapKit
import UIKit

enum QFThemeKind: String, Codable, CaseIterable, Hashable {
  case classic
  case forest
  case dark

  var title: String {
    title(language: .simplifiedChinese)
  }

  func title(language: QFInterfaceLanguage) -> String {
    switch self {
    case .classic: return language.text(chinese: "经典橙", english: "Classic orange")
    case .forest: return language.text(chinese: "自然绿", english: "Natural green")
    case .dark: return language.text(chinese: "深色", english: "Dark")
    }
  }

  var subtitle: String {
    subtitle(language: .simplifiedChinese)
  }

  func subtitle(language: QFInterfaceLanguage) -> String {
    switch self {
    case .classic: return language.text(chinese: "温暖、明快", english: "Warm and bright")
    case .forest: return language.text(chinese: "自然、舒缓", english: "Natural and calm")
    case .dark: return language.text(chinese: "适合暗光环境", english: "Comfortable in low light")
    }
  }

  var previewColors: [UIColor] {
    let value = palette
    return [value.background, value.text, value.primary, value.tint, value.border].map { UIColor(hex: $0) }
  }

  var previewBackground: UIColor { UIColor(hex: palette.background) }
  var previewSurface: UIColor { UIColor(hex: palette.surface) }
  var previewText: UIColor { UIColor(hex: palette.text) }
  var previewPrimary: UIColor { UIColor(hex: palette.primary) }
  var previewOnPrimary: UIColor { UIColor(hex: palette.onPrimary) }
  var previewBorder: UIColor { UIColor(hex: palette.border) }

  fileprivate var palette: QFThemePalette {
    switch self {
    case .classic:
      return QFThemePalette(
        background: 0xF8F8F3, surface: 0xFFFFFF, surfaceAlt: 0xECEFE7,
        text: 0x29342D, secondary: 0x687368, border: 0xDDE3D5,
        primary: 0xC44928, onPrimary: 0xFFFFFF, accent: 0xD74F29,
        tint: 0xFFF0E7, onTint: 0xA33F24, success: 0x536F44,
        successBackground: 0xEDF2E6, warning: 0x936920, warningBackground: 0xFFF4DD,
        danger: 0xB24235, dangerBackground: 0xFDECE8,
        disabledBackground: 0xE6EADF, disabledText: 0x8B9385, overlay: 0x000000)
    case .forest:
      return QFThemePalette(
        background: 0xEDF4EC, surface: 0xF9FCF7, surfaceAlt: 0xE1ECDD,
        text: 0x203A2B, secondary: 0x536A58, border: 0xCADDCB,
        primary: 0x2F6949, onPrimary: 0xFFFFFF, accent: 0x2E6949,
        tint: 0xDAECDD, onTint: 0x2D5B3B, success: 0x386A41,
        successBackground: 0xE0EED7, warning: 0x825C21, warningBackground: 0xF5ECD7,
        danger: 0xA13F35, dangerBackground: 0xF8E6E0,
        disabledBackground: 0xD9E4D5, disabledText: 0x7B8C79, overlay: 0x0C2114)
    case .dark:
      return QFThemePalette(
        background: 0x151C27, surface: 0x232E40, surfaceAlt: 0x2C3A4E,
        text: 0xF1F5FC, secondary: 0xB6C3D7, border: 0x42536B,
        primary: 0xB1CBFA, onPrimary: 0x183253, accent: 0xB1CBFA,
        tint: 0x30496C, onTint: 0xD7E5FF, success: 0xB5D6BD,
        successBackground: 0x2E453C, warning: 0xF4D398, warningBackground: 0x4A412F,
        danger: 0xFFB9B0, dangerBackground: 0x563B39,
        disabledBackground: 0x354359, disabledText: 0x95A5BC, overlay: 0x000000)
    }
  }
}

private struct QFThemePalette {
  let background: UInt
  let surface: UInt
  let surfaceAlt: UInt
  let text: UInt
  let secondary: UInt
  let border: UInt
  let primary: UInt
  let onPrimary: UInt
  let accent: UInt
  let tint: UInt
  let onTint: UInt
  let success: UInt
  let successBackground: UInt
  let warning: UInt
  let warningBackground: UInt
  let danger: UInt
  let dangerBackground: UInt
  let disabledBackground: UInt
  let disabledText: UInt
  let overlay: UInt
}

final class QFThemeManager {
  static let shared = QFThemeManager()
  static let defaultsKey = "qfyp.appearance.theme"

  private(set) var current: QFThemeKind
  var onChange: ((QFThemeKind) -> Void)?

  private init(defaults: UserDefaults = .standard) {
    current = QFThemeKind(rawValue: defaults.string(forKey: Self.defaultsKey) ?? "") ?? .classic
  }

  func apply(_ theme: QFThemeKind, defaults: UserDefaults = .standard) {
    guard current != theme else {
      defaults.set(theme.rawValue, forKey: Self.defaultsKey)
      return
    }
    current = theme
    defaults.set(theme.rawValue, forKey: Self.defaultsKey)
    onChange?(theme)
  }
}

enum QFUI {
  private static var palette: QFThemePalette { QFThemeManager.shared.current.palette }
  static var background: UIColor { UIColor(hex: palette.background) }
  static var surface: UIColor { UIColor(hex: palette.surface) }
  static var surfaceAlt: UIColor { UIColor(hex: palette.surfaceAlt) }
  static var text: UIColor { UIColor(hex: palette.text) }
  static var secondary: UIColor { UIColor(hex: palette.secondary) }
  static var border: UIColor { UIColor(hex: palette.border) }
  static var primary: UIColor { UIColor(hex: palette.primary) }
  static var onPrimary: UIColor { UIColor(hex: palette.onPrimary) }
  static var accent: UIColor { UIColor(hex: palette.accent) }
  static var tint: UIColor { UIColor(hex: palette.tint) }
  static var onTint: UIColor { UIColor(hex: palette.onTint) }
  static var success: UIColor { UIColor(hex: palette.success) }
  static var successBackground: UIColor { UIColor(hex: palette.successBackground) }
  static var warning: UIColor { UIColor(hex: palette.warning) }
  static var warningBackground: UIColor { UIColor(hex: palette.warningBackground) }
  static var danger: UIColor { UIColor(hex: palette.danger) }
  static var dangerBackground: UIColor { UIColor(hex: palette.dangerBackground) }
  static var disabledBackground: UIColor { UIColor(hex: palette.disabledBackground) }
  static var disabledText: UIColor { UIColor(hex: palette.disabledText) }
  static var overlay: UIColor { UIColor(hex: palette.overlay) }

  // Compatibility aliases used by the already implemented first-level pages.
  static var orange: UIColor { primary }
  static var green: UIColor { success }
  static var paleGreen: UIColor { successBackground }

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
    _ title: String, background: UIColor = QFUI.primary, textColor: UIColor = QFUI.onPrimary
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
    let alert = UIAlertController(
      title: title, message: app.text("该功能暂未开放", "This feature is not available yet."),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: app.text("知道了", "OK"), style: .default))
    present(alert, animated: true)
  }
}
