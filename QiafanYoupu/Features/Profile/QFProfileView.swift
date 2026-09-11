import Combine
import SnapKit
import UIKit

@MainActor
final class QFProfileViewController: QFPageViewController {
  private let previewSignedIn: Bool
  private let onLogin: () -> Void
  private var user: QFUserProfile?
  private var signedIn: Bool { user != nil || previewSignedIn }
  private var compact = false
  private let identityRow = QFTabUI.stack([], axis: .horizontal, spacing: 14)
  private let identityText = QFTabUI.stack([], spacing: 6)
  private let nameLabel = QFTabUI.label("", size: 20, weight: .semibold)
  private let regionLabel = QFTabUI.label("", size: 12, color: QFUI.secondary, lines: 0)
  private let avatarImage = QFRemoteImageView()
  private var actionButton: UIButton!
  private var featureCards: UIStackView!
  private let menu = QFTabUI.stack([], spacing: 0)
  private var preference: UIButton!

  init(app: QFAppSession, previewSignedIn: Bool, onLogin: @escaping () -> Void) {
    self.previewSignedIn = previewSignedIn
    self.onLogin = onLogin
    super.init(app: app)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "profile.screen"
    let title = QFTabUI.label("我的", size: 30, weight: .semibold)
    title.accessibilityTraits.insert(.header)
    let settings = QFTabUI.iconButton("gearshape", label: "设置", size: 22) { [weak self] in
      self?.showUnavailable("设置")
    }
    let header = QFTabUI.stack([title, UIView(), settings], axis: .horizontal, spacing: 10)
    header.alignment = .center
    contentStack.addArrangedSubview(header)
    makeIdentity()
    contentStack.addArrangedSubview(identityRow)
    contentStack.addArrangedSubview(makeStats())
    featureCards = QFTabUI.stack(
      [
        feature(
          "发布作品", subtitle: "记录今天的拿手菜", symbol: "photo", color: QFUI.orange,
          background: QFTabUI.color(0xFFF0E7)),
        feature(
          "补充图片", subtitle: "为食材、菜谱补充实拍", symbol: "photo.badge.plus", color: QFUI.green,
          background: QFUI.paleGreen),
      ], axis: .horizontal, spacing: 14)
    featureCards.distribution = .fillEqually
    contentStack.addArrangedSubview(featureCards)
    let contentTitle = QFTabUI.label("我的内容", size: 20, weight: .semibold)
    contentTitle.accessibilityTraits.insert(.header)
    contentStack.addArrangedSubview(contentTitle)
    contentStack.addArrangedSubview(QFTabUI.card(menu, padding: 16))
    preference = menuButton("兴趣偏好", symbol: "slider.horizontal.3", detail: "登录后设置")
    contentStack.addArrangedSubview(QFTabUI.card(preference, padding: 16))
    app.$user.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] user in
      self?.user = user
      self?.refreshProfile()
    }.store(in: &cancellables)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let next = view.bounds.width < 360
    guard next != compact else { return }
    compact = next
    featureCards.axis = compact ? .vertical : .horizontal
    identityRow.removeArrangedSubview(actionButton)
    identityText.removeArrangedSubview(actionButton)
    actionButton.removeFromSuperview()
    identityText.alignment = compact ? .leading : .fill
    if compact {
      identityText.addArrangedSubview(actionButton)
    } else {
      identityRow.addArrangedSubview(actionButton)
    }
    nameLabel.numberOfLines = compact ? 2 : 1
  }

  private func makeIdentity() {
    let avatar = UIView()
    avatar.backgroundColor = QFUI.paleGreen
    avatar.layer.cornerRadius = 36
    avatar.snp.makeConstraints { $0.size.equalTo(72) }
    avatar.addSubview(avatarImage)
    avatarImage.clipsToBounds = true
    avatarImage.isAccessibilityElement = false
    avatarImage.snp.makeConstraints {
      $0.center.equalToSuperview()
      $0.size.equalTo(48)
    }
    nameLabel.adjustsFontSizeToFitWidth = true
    nameLabel.minimumScaleFactor = 0.8
    identityText.addArrangedSubview(nameLabel)
    identityText.addArrangedSubview(regionLabel)
    actionButton = QFTabUI.button(
      "去登录", size: 14, weight: .medium, color: .white, background: QFUI.orange
    ) { [weak self] in
      guard let self else { return }
      self.signedIn ? self.showUnavailable("编辑资料") : self.onLogin()
    }
    actionButton.contentEdgeInsets = .zero
    actionButton.layer.cornerRadius = 19
    actionButton.accessibilityIdentifier = "profile.login"
    actionButton.snp.makeConstraints {
      $0.width.equalTo(80)
      $0.height.equalTo(38)
    }
    identityRow.addArrangedSubview(avatar)
    identityRow.addArrangedSubview(identityText)
    identityRow.addArrangedSubview(actionButton)
    identityRow.alignment = .center
  }

  private func refreshProfile() {
    nameLabel.text = user?.nickname ?? (previewSignedIn ? "小满的厨房" : "登录恰饭有谱")
    if let user {
      let parts = [user.countryCode, user.regionCode].compactMap { $0 }.filter { !$0.isEmpty }
      regionLabel.text = parts.isEmpty ? "地区未设置" : parts.joined(separator: " · ")
    } else {
      regionLabel.text = previewSignedIn ? "中国 · 上海" : "收藏菜谱，记录下厨日常"
    }
    actionButton.setTitle(signedIn ? "编辑资料" : "去登录", for: .normal)
    let request = user.flatMap {
      QFRemoteImageRequest(
        urlString: $0.avatarUrl, environment: app.api.environment.name,
        apiBaseURL: app.api.environment.baseURL, userID: $0.userId)
    }
    let placeholder =
      signedIn ? UIImage(named: "default-avatar") : UIImage(systemName: "person.fill")
    let imageSize: CGFloat = request != nil ? 72 : (signedIn ? 48 : 36)
    avatarImage.snp.updateConstraints { $0.size.equalTo(imageSize) }
    avatarImage.layer.cornerRadius = request != nil ? 36 : 0
    avatarImage.tintColor = QFTabUI.color(0x9AA78C)
    avatarImage.load(request, placeholder: placeholder, size: CGSize(width: 72, height: 72))
    QFTabUI.clear(menu)
    for (index, item) in QFProfileMenuItem.items.enumerated() {
      if index > 0 {
        let divider = UIView()
        divider.backgroundColor = QFUI.border
        divider.snp.makeConstraints { $0.height.equalTo(0.5) }
        menu.addArrangedSubview(divider)
      }
      menu.addArrangedSubview(
        menuButton(item.title, symbol: item.symbol, detail: signedIn ? "" : "登录后查看"))
    }
    // Keep the preference card mounted while replacing only its label arrangement.
    configureMenuButton(
      preference, title: "兴趣偏好", symbol: "slider.horizontal.3", detail: signedIn ? "" : "登录后设置")
  }

  private func makeStats() -> UIView {
    let values = previewSignedIn ? ["128", "26", "12"] : ["—", "—", "—"]
    let row = QFTabUI.stack([], axis: .horizontal, spacing: 0)
    row.distribution = .fillEqually
    for (index, title) in ["收藏", "做菜天数", "作品"].enumerated() {
      let value = QFTabUI.label(
        values[index], size: 22, weight: .semibold,
        color: previewSignedIn ? QFUI.text : QFTabUI.color(0x99A08F))
      let name = QFTabUI.label(title, size: 13, color: QFUI.secondary)
      value.textAlignment = .center
      name.textAlignment = .center
      row.addArrangedSubview(QFTabUI.stack([value, name], spacing: 4))
    }
    return QFTabUI.card(row, padding: 14)
  }

  private func feature(
    _ title: String, subtitle: String, symbol: String, color: UIColor, background: UIColor
  ) -> UIButton {
    let button = QFTabUI.button("", background: background) { [weak self] in
      self?.openProtected(title)
    }
    button.accessibilityLabel = title
    let icons = QFTabUI.stack(
      [
        QFTabUI.symbol(symbol, size: 23, color: color), UIView(),
        QFTabUI.symbol("chevron.right", size: 15, color: color),
      ], axis: .horizontal, spacing: 8)
    icons.alignment = .center
    let spacer = UIView()
    spacer.snp.makeConstraints { $0.height.greaterThanOrEqualTo(16) }
    let labels = QFTabUI.stack(
      [
        icons, spacer, QFTabUI.label(title, size: 21, weight: .semibold, lines: 0),
        QFTabUI.label(subtitle, size: 12, color: color, lines: 0),
      ], spacing: 10)
    labels.isUserInteractionEnabled = false
    labels.accessibilityElementsHidden = true
    button.addSubview(labels)
    labels.snp.makeConstraints { $0.edges.equalToSuperview().inset(16) }
    button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(144) }
    return button
  }

  private func menuButton(_ title: String, symbol: String, detail: String) -> UIButton {
    let button = QFTabUI.button("") { [weak self] in self?.openProtected(title) }
    configureMenuButton(button, title: title, symbol: symbol, detail: detail)
    return button
  }

  private func configureMenuButton(
    _ button: UIButton, title: String, symbol: String, detail: String
  ) {
    button.subviews.filter { $0.tag == 2101 }.forEach { $0.removeFromSuperview() }
    button.accessibilityLabel = title
    button.accessibilityHint = detail
    let views: [UIView] = [
      QFTabUI.symbol(symbol, size: 21), QFTabUI.label(title, size: 16, weight: .medium, lines: 0),
      QFTabUI.label(detail, size: 12, color: QFUI.secondary),
      QFTabUI.symbol("chevron.right", size: 15, color: QFUI.secondary),
    ]
    views[2].setContentCompressionResistancePriority(.required, for: .horizontal)
    let row = QFTabUI.stack(views, axis: .horizontal, spacing: 12)
    row.tag = 2101
    row.alignment = .center
    row.isUserInteractionEnabled = false
    row.accessibilityElementsHidden = true
    button.addSubview(row)
    row.snp.makeConstraints {
      $0.leading.trailing.equalToSuperview()
      $0.top.bottom.equalToSuperview().inset(8)
      $0.height.greaterThanOrEqualTo(35)
    }
  }

  private func openProtected(_ title: String) {
    signedIn ? showUnavailable(title) : onLogin()
  }
}

private struct QFProfileMenuItem {
  let title: String
  let symbol: String
  static let items = [
    QFProfileMenuItem(title: "我的作品", symbol: "photo"),
    QFProfileMenuItem(title: "我的图片贡献", symbol: "photo.badge.plus"),
    QFProfileMenuItem(title: "我的收藏", symbol: "bookmark"),
    QFProfileMenuItem(title: "做菜记录与统计", symbol: "calendar.badge.checkmark"),
  ]
}
