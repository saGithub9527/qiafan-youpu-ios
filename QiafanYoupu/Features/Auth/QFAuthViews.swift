import CoreFoundation
import Foundation
import Combine
import SnapKit
import UIKit

/// The same local UI choice used by the previous Objective-C screens, never an authentication record.
enum QFAuthConsentStore {
  private static let key = "qfyp.login.consent"

  static func isAgreementChecked(
    revision: String = "ui-placeholder-v1", defaults: UserDefaults = .standard
  ) -> Bool {
    guard let record = defaults.object(forKey: key) as? [String: Any] else {
      return false
    }
    guard let schema = record["schemaVersion"] as? NSNumber, schema.intValue == 1,
      let value = record["loginAgreementChecked"] as? NSNumber,
      CFGetTypeID(value) == CFBooleanGetTypeID(),
      let timestamp = record["updatedAt"] as? String,
      ISO8601DateFormatter().date(from: timestamp) != nil,
      record["uiDocumentRevision"] as? String == revision
    else {
      setAgreementChecked(false, revision: revision, defaults: defaults)
      return false
    }
    return value.boolValue
  }

  static func setAgreementChecked(
    _ checked: Bool, revision: String = "ui-placeholder-v1", defaults: UserDefaults = .standard
  ) {
    let record: [String: Any] = [
      "schemaVersion": 1,
      "loginAgreementChecked": checked,
      "updatedAt": ISO8601DateFormatter().string(from: Date()),
      "uiDocumentRevision": revision,
      "uiOnly": true,
    ]
    // Formal document versions remain absent: no real agreement text has been supplied.
    defaults.set(record, forKey: key)
  }
}

enum QFAuthDocument: String, Identifiable {
  case privacy
  case terms

  var id: String { rawValue }
  var title: String { self == .privacy ? "隐私政策" : "用户协议" }
}

// UIKit-only components shared by the welcome, login and agreement controllers.
enum QFAuthPalette {
  static func color(_ hex: UInt) -> UIColor {
    UIColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
  }
}

@MainActor
final class QFAuthLoadingButton: UIButton {
  private let copy: UILabel
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let normalBackground: UIColor
  private let normalTextColor: UIColor
  private var loading = false

  init(_ title: String, background: UIColor = QFUI.orange, textColor: UIColor = .white,
       size: CGFloat = 17, symbol: String? = nil, cornerRadius: CGFloat = 17) {
    copy = QFUI.label(title, size: size, weight: .semibold, color: textColor, lines: 1)
    normalBackground = background
    normalTextColor = textColor
    super.init(frame: .zero)
    accessibilityLabel = title
    isAccessibilityElement = true
    accessibilityTraits = .button
    layer.cornerRadius = cornerRadius
    copy.minimumScaleFactor = 0.8
    copy.adjustsFontSizeToFitWidth = true
    spinner.color = textColor
    spinner.isHidden = true
    spinner.isAccessibilityElement = false
    let content = UIStackView()
    content.axis = .horizontal
    content.alignment = .center
    content.spacing = 9
    content.isUserInteractionEnabled = false
    content.isAccessibilityElement = false
    content.accessibilityElementsHidden = true
    content.addArrangedSubview(spinner)
    spinner.snp.makeConstraints { $0.width.height.equalTo(20).priority(999) }
    if let symbol {
      let icon = UIImageView(image: UIImage(systemName: symbol))
      icon.tintColor = textColor
      icon.contentMode = .scaleAspectFit
      content.addArrangedSubview(icon)
      icon.snp.makeConstraints { $0.width.height.equalTo(24) }
    }
    content.addArrangedSubview(copy)
    addSubview(content)
    content.snp.makeConstraints {
      $0.center.equalToSuperview()
      $0.leading.greaterThanOrEqualToSuperview().offset(10)
      $0.trailing.lessThanOrEqualToSuperview().offset(-10)
      $0.top.greaterThanOrEqualToSuperview().offset(8).priority(.high)
      $0.bottom.lessThanOrEqualToSuperview().offset(-8).priority(.high)
    }
    refreshAppearance()
  }

  required init?(coder: NSCoder) { return nil }
  override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 55) }
  override var isEnabled: Bool { didSet { refreshAppearance() } }
  override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.82 : 1 } }

  func setLoading(_ value: Bool) {
    guard loading != value else { return }
    loading = value
    spinner.isHidden = !value
    if value { spinner.startAnimating() } else { spinner.stopAnimating() }
    refreshAppearance()
  }

  private func refreshAppearance() {
    // This custom accessibility element owns its traits; mirror UIControl's disabled state too.
    accessibilityTraits = isEnabled ? [.button] : [.button, .notEnabled]
    backgroundColor = isEnabled || loading ? normalBackground : normalBackground.withAlphaComponent(0.45)
    copy.textColor = normalTextColor
  }
}

@MainActor
final class QFAuthAgreementControl: UIView, UITextViewDelegate {
  private let checkbox = UIButton(type: .system)
  private let textView = UITextView()
  private var textHeight: Constraint?
  private var measuredHeight: CGFloat = 36
  var onCheckedChange: ((Bool) -> Void)?
  var onReadDocument: ((QFAuthDocument) -> Void)?
  var checked = false { didSet { renderCheckmark() } }

  init(identifier: String, noticeStyle: Bool) {
    super.init(frame: .zero)
    checkbox.accessibilityIdentifier = identifier
    checkbox.accessibilityLabel = "我已阅读并同意隐私政策和用户协议"
    checkbox.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.checked.toggle()
      self.onCheckedChange?(self.checked)
    }, for: .touchUpInside)
    addSubview(checkbox)
    textView.backgroundColor = .clear
    textView.isEditable = false
    textView.isScrollEnabled = false
    textView.isSelectable = true
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.delegate = self
    textView.accessibilityIdentifier = "\(identifier).text"
    textView.accessibilityTraits = .staticText
    let copy = noticeStyle
      ? "我已阅读并同意 《用户协议》\n和《隐私政策》"
      : "我已阅读并同意《隐私政策》和《用户协议》"
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 4
    let attributed = NSMutableAttributedString(string: copy, attributes: [
      .font: UIFont.systemFont(ofSize: 13), .foregroundColor: QFUI.secondary,
      .paragraphStyle: paragraph,
    ])
    for document in [QFAuthDocument.privacy, .terms] {
      let range = (copy as NSString).range(of: "《\(document.title)》")
      if range.location != NSNotFound {
        attributed.addAttribute(.link, value: "qfyp-document://\(document.rawValue)", range: range)
      }
    }
    textView.attributedText = attributed
    textView.linkTextAttributes = [
      .foregroundColor: noticeStyle ? QFAuthPalette.color(0xA83212) : QFUI.green
    ]
    addSubview(textView)
    checkbox.snp.makeConstraints {
      $0.leading.equalToSuperview()
      $0.width.height.equalTo(44)
      $0.centerY.equalTo(textView)
      $0.top.greaterThanOrEqualToSuperview()
      $0.bottom.lessThanOrEqualToSuperview()
    }
    textView.snp.makeConstraints {
      $0.leading.equalTo(checkbox.snp.trailing).offset(3)
      $0.trailing.equalToSuperview()
      $0.centerY.equalToSuperview()
      $0.top.greaterThanOrEqualToSuperview()
      $0.bottom.lessThanOrEqualToSuperview()
      textHeight = $0.height.equalTo(measuredHeight).constraint
    }
    snp.makeConstraints { $0.height.greaterThanOrEqualTo(55) }
    renderCheckmark()
  }

  required init?(coder: NSCoder) { return nil }
  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: max(55, measuredHeight))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = max(1, bounds.width - 47)
    let height = ceil(textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    if abs(height - measuredHeight) > 0.5 {
      measuredHeight = height
      textHeight?.update(offset: height)
      invalidateIntrinsicContentSize()
    }
  }

  func setEnabled(_ enabled: Bool) {
    isUserInteractionEnabled = enabled
    checkbox.isEnabled = enabled
    renderCheckmark()
  }

  func textView(_ textView: UITextView, shouldInteractWith URL: URL,
                in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
    if URL.scheme == "qfyp-document", let host = URL.host, let document = QFAuthDocument(rawValue: host) {
      onReadDocument?(document)
    }
    return false
  }

  private func renderCheckmark() {
    let configuration = UIImage.SymbolConfiguration(pointSize: 21)
    checkbox.backgroundColor = .clear
    checkbox.setImage(UIImage(systemName: checked ? "checkmark.square" : "square",
                             withConfiguration: configuration), for: .normal)
    checkbox.tintColor = checked ? QFUI.green : QFAuthPalette.color(0x93A18B)
    checkbox.isSelected = checked
    checkbox.accessibilityValue = checked ? "已勾选" : "未勾选"
    var traits: UIAccessibilityTraits = checked ? [.button, .selected] : [.button]
    if !checkbox.isEnabled { traits.insert(.notEnabled) }
    checkbox.accessibilityTraits = traits
  }
}

@MainActor
final class QFAuthAgreementViewController: UIViewController {
  private let app: QFAppSession
  private let document: QFAuthDocument
  private let bodyLabel = QFUI.label("", size: 17)
  private var subscriptions = Set<AnyCancellable>()

  init(app: QFAppSession, document: QFAuthDocument) {
    self.app = app
    self.document = document
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { return nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    let header = UIView()
    view.addSubview(header)
    header.snp.makeConstraints {
      $0.top.equalTo(view.safeAreaLayoutGuide.snp.top)
      $0.centerX.equalToSuperview()
      $0.width.equalTo(view.safeAreaLayoutGuide.snp.width).priority(.high)
      $0.width.lessThanOrEqualTo(760)
      $0.leading.greaterThanOrEqualTo(view.safeAreaLayoutGuide.snp.leading)
      $0.trailing.lessThanOrEqualTo(view.safeAreaLayoutGuide.snp.trailing)
      $0.height.equalTo(52)
    }
    let back = UIButton(type: .system)
    back.setTitle("返回", for: .normal)
    back.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    back.tintColor = QFUI.green
    back.accessibilityIdentifier = "agreement.back"
    back.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
    header.addSubview(back)
    back.snp.makeConstraints { $0.leading.equalToSuperview().offset(20); $0.centerY.equalToSuperview(); $0.height.equalTo(44) }
    let title = QFUI.label(document.title, size: 17, weight: .semibold, lines: 1)
    header.addSubview(title)
    title.snp.makeConstraints { $0.center.equalToSuperview(); $0.leading.greaterThanOrEqualTo(back.snp.trailing).offset(8) }
    let divider = UIView()
    divider.backgroundColor = QFUI.border
    view.addSubview(divider)
    divider.snp.makeConstraints { $0.top.equalTo(header.snp.bottom); $0.leading.trailing.equalToSuperview(); $0.height.equalTo(1) }
    let scroll = UIScrollView()
    scroll.accessibilityIdentifier = "agreement.document"
    view.addSubview(scroll)
    scroll.snp.makeConstraints {
      $0.top.equalTo(divider.snp.bottom); $0.bottom.equalTo(view.safeAreaLayoutGuide.snp.bottom)
      $0.centerX.equalToSuperview()
      $0.width.equalTo(view.safeAreaLayoutGuide.snp.width).priority(.high)
      $0.width.lessThanOrEqualTo(760)
      $0.leading.greaterThanOrEqualTo(view.safeAreaLayoutGuide.snp.leading)
      $0.trailing.lessThanOrEqualTo(view.safeAreaLayoutGuide.snp.trailing)
    }
    let heading = QFUI.label(document.title, size: 26, weight: .bold)
    heading.accessibilityTraits.insert(.header)
    let stack = QFUI.stack([heading, bodyLabel], spacing: 24)
    scroll.addSubview(stack)
    stack.snp.makeConstraints {
      $0.edges.equalTo(scroll.contentLayoutGuide).inset(UIEdgeInsets(top: 28, left: 24, bottom: 28, right: 24))
      $0.width.equalTo(scroll.frameLayoutGuide.snp.width).offset(-48)
    }
    render(app.configuration)
    app.$configuration.receive(on: DispatchQueue.main).sink { [weak self] configuration in
      self?.render(configuration)
    }.store(in: &subscriptions)
  }

  private func render(_ configuration: QFServerConfig?) {
    let text = document == .privacy ? configuration?.agreements.privacyPolicy : configuration?.agreements.userAgreement
    bodyLabel.text = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? text : "协议暂未配置，请稍后重试。"
  }
}
