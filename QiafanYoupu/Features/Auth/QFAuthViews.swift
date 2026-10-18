import CoreFoundation
import Foundation
import Combine
import SnapKit
import UIKit

/// The same local UI choice used by the previous Objective-C screens, never an authentication record.
enum QFAuthConsentStore {
  private static let key = "qfyp.login.consent"
  static let fallbackRevision = "bundled-legal-1.3-2026-09-15"

  static func isAgreementChecked(
    revision: String = fallbackRevision, defaults: UserDefaults = .standard
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
    _ checked: Bool, revision: String = fallbackRevision, defaults: UserDefaults = .standard
  ) {
    let record: [String: Any] = [
      "schemaVersion": 1,
      "loginAgreementChecked": checked,
      "updatedAt": ISO8601DateFormatter().string(from: Date()),
      "uiDocumentRevision": revision,
      "uiOnly": true,
    ]
    // Callers combine this bundled document revision with the server's active consent revision.
    defaults.set(record, forKey: key)
  }
}

enum QFAuthDocument: String, Identifiable {
  case privacy
  case terms

  var id: String { rawValue }
  @MainActor
  func title(app: QFAppSession) -> String {
    self == .privacy ? app.text("隐私政策", "Privacy Policy") : app.text("用户协议", "Terms of Service")
  }
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

  func setLoading(_ value: Bool, accessibilityText: String? = nil) {
    accessibilityValue = value ? accessibilityText : nil
    guard loading != value else { return }
    loading = value
    spinner.isHidden = !value
    if value { spinner.startAnimating() } else { spinner.stopAnimating() }
    refreshAppearance()
  }

  func setTitle(_ title: String) {
    copy.text = title
    accessibilityLabel = title
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
  private let app: QFAppSession
  private let noticeStyle: Bool
  private let checkbox = UIButton(type: .custom)
  private let textView = UITextView()
  private var textHeight: Constraint?
  private var measuredHeight: CGFloat = 36
  private var languageSubscription: AnyCancellable?
  var onCheckedChange: ((Bool) -> Void)?
  var onReadDocument: ((QFAuthDocument) -> Void)?
  var checked = false { didSet { renderCheckmark() } }

  init(app: QFAppSession, identifier: String, noticeStyle: Bool) {
    self.app = app
    self.noticeStyle = noticeStyle
    super.init(frame: .zero)
    checkbox.accessibilityIdentifier = identifier
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
    renderText()
    languageSubscription = app.$interfaceLanguage.dropFirst().receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.renderText() }
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

  private func renderText() {
    checkbox.accessibilityLabel = app.text(
      "我已阅读并同意隐私政策和用户协议",
      "I have read and agree to the Privacy Policy and Terms of Service")
    let terms = QFAuthDocument.terms.title(app: app)
    let privacy = QFAuthDocument.privacy.title(app: app)
    let copy = noticeStyle
      ? app.format(
        "我已阅读并同意《%@》\n和《%@》", "I have read and agree to the %@\nand %@", terms,
        privacy)
      : app.format(
        "我已阅读并同意《%@》和《%@》", "I have read and agree to the %@ and %@", privacy,
        terms)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 4
    let attributed = NSMutableAttributedString(string: copy, attributes: [
      .font: UIFont.systemFont(ofSize: 13), .foregroundColor: QFUI.secondary,
      .paragraphStyle: paragraph,
    ])
    for document in [QFAuthDocument.privacy, .terms] {
      let title = document.title(app: app)
      let range = (copy as NSString).range(of: title)
      if range.location != NSNotFound {
        attributed.addAttribute(.link, value: "qfyp-document://\(document.rawValue)", range: range)
      }
    }
    textView.attributedText = attributed
    textView.linkTextAttributes = [
      .foregroundColor: noticeStyle ? QFAuthPalette.color(0xA83212) : QFUI.green
    ]
    measuredHeight = 36
    textHeight?.update(offset: measuredHeight)
    setNeedsLayout()
    invalidateIntrinsicContentSize()
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
    checkbox.configuration = nil
    checkbox.backgroundColor = .clear
    checkbox.setImage(UIImage(systemName: checked ? "checkmark.square" : "square",
                             withConfiguration: configuration), for: .normal)
    checkbox.tintColor = checked ? QFUI.green : QFAuthPalette.color(0x93A18B)
    checkbox.isSelected = checked
    checkbox.accessibilityValue = checked
      ? app.text("已勾选", "Checked") : app.text("未勾选", "Not checked")
    var traits: UIAccessibilityTraits = checked ? [.button, .selected] : [.button]
    if !checkbox.isEnabled { traits.insert(.notEnabled) }
    checkbox.accessibilityTraits = traits
  }
}
