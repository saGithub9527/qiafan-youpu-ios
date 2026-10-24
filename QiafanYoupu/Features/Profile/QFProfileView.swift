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
  private let contentAvatarImage = QFContentImageView()
  private let titleLabel = QFTabUI.label("", size: 30, weight: .semibold)
  private var languageButton: UIButton!
  private var settingsButton: UIButton!
  private let contentTitleLabel = QFTabUI.label("", size: 20, weight: .semibold)
  private var actionButton: UIButton!
  private var featureCards: UIStackView!
  private let menu = QFTabUI.stack([], spacing: 0)
  private var preference: UIButton!
  private var membership: UIButton!
  private var statisticLabels: [UILabel] = []
  private var statisticNameLabels: [UILabel] = []
  private var profileTask: Task<Void, Never>?
  private var summaryTask: Task<Void, Never>?
  private var renderedOwner: String?
  private var renderedSignedIn: Bool?
  private var renderedAvatarURL: String?
  private var lastSummary: QFContentSummary?
  private var viewIsActive = false
  private var renderedLanguage = ""

  init(app: QFAppSession, previewSignedIn: Bool, onLogin: @escaping () -> Void) {
    self.previewSignedIn = previewSignedIn
    self.onLogin = onLogin
    super.init(app: app)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit {
    profileTask?.cancel()
    summaryTask?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "profile.screen"
    titleLabel.accessibilityTraits.insert(.header)
    languageButton = QFTabUI.iconButton(
      "globe", label: app.text("切换语言", "Change language"), size: 20, weight: .medium
    ) { [weak self] in self?.openLanguageSettings() }
    settingsButton = QFTabUI.iconButton(
      "gearshape", label: app.text("设置", "Settings"), size: 22, weight: .medium
    ) {
      [weak self] in self?.openSettings()
    }
    let header = QFTabUI.stack(
      [titleLabel, UIView(), languageButton, settingsButton], axis: .horizontal, spacing: 2)
    header.alignment = .center
    contentStack.addArrangedSubview(header)
    makeIdentity()
    contentStack.addArrangedSubview(identityRow)
    contentStack.addArrangedSubview(makeStats())
    featureCards = QFTabUI.stack([], axis: .horizontal, spacing: 14)
    featureCards.distribution = .fillEqually
    contentStack.addArrangedSubview(featureCards)
    contentTitleLabel.accessibilityTraits.insert(.header)
    contentStack.addArrangedSubview(contentTitleLabel)
    contentStack.setCustomSpacing(10, after: contentTitleLabel)
    contentStack.addArrangedSubview(QFTabUI.card(menu, padding: 0))
    preference = menuButton(.preferences, symbol: "slider.horizontal.3", detail: "")
    contentStack.addArrangedSubview(QFTabUI.card(preference, padding: 0))
    membership = menuButton(.membership, symbol: "crown", detail: "")
    contentStack.addArrangedSubview(QFTabUI.card(membership, padding: 0))
    applyLanguage()
    app.$user.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] user in
      guard let self else { return }
      let ownerChanged = self.user?.userId != user?.userId
      self.user = user
      self.refreshProfile()
      if ownerChanged {
        self.profileTask?.cancel()
        // Startup restoration already fetched /me before publishing this account.
        // Login from the pushed login page is refreshed when the home page reappears.
        self.loadContentSummary()
      }
    }.store(in: &cancellables)
    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] _ in
      DispatchQueue.main.async { self?.applyLanguage() }
    }.store(in: &cancellables)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    viewIsActive = true
    user = app.user
    refreshProfile()
    refreshOnEntry()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    viewIsActive = false
    profileTask?.cancel()
    summaryTask?.cancel()
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

  private func applyLanguage() {
    guard isViewLoaded else { return }
    titleLabel.text = app.text("我的", "My profile")
    languageButton?.accessibilityLabel = app.text("切换语言", "Change language")
    settingsButton?.accessibilityLabel = app.text("设置", "Settings")
    contentTitleLabel.text = app.text("我的内容", "My content")
    for (label, value) in zip(
      statisticNameLabels,
      [
        app.text("收藏", "Favorites"), app.text("做菜天数", "Cooking days"),
        app.text("作品", "Posts"), app.text("贡献", "Contributions"),
      ])
    { label.text = value }

    QFTabUI.clear(featureCards)
    featureCards.addArrangedSubview(
      feature(
        .publishWork, subtitle: app.text("记录今天的拿手菜", "Share what you cooked today"),
        symbol: "photo", color: QFUI.onTint, background: QFUI.tint))
    featureCards.addArrangedSubview(
      feature(
        .contributeImage,
        subtitle: app.text("为食材、菜谱补充实拍", "Add real photos to ingredients and recipes"),
        symbol: "photo.badge.plus", color: QFUI.success,
        background: QFUI.successBackground))
    refreshProfile()
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
    avatar.addSubview(contentAvatarImage)
    contentAvatarImage.snp.makeConstraints { $0.edges.equalToSuperview() }
    contentAvatarImage.layer.cornerRadius = 36
    contentAvatarImage.clipsToBounds = true
    contentAvatarImage.isHidden = true
    nameLabel.adjustsFontSizeToFitWidth = true
    nameLabel.minimumScaleFactor = 0.8
    identityText.addArrangedSubview(nameLabel)
    identityText.addArrangedSubview(regionLabel)
    actionButton = QFTabUI.button(
      app.text("去登录", "Sign in"), size: 14, weight: .medium, color: QFUI.onPrimary,
      background: QFUI.primary
    ) { [weak self] in
      guard let self else { return }
      if let user = self.user { self.openEditProfile(user) } else { self.onLogin() }
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
    let ownerChanged = renderedOwner != user?.userId
    let languageChanged = renderedLanguage != app.interfaceLanguage
    let menuChanged = renderedSignedIn != signedIn || languageChanged
    if ownerChanged {
      summaryTask?.cancel()
      lastSummary = nil
      statisticLabels.forEach { $0.text = "—" }
      contentAvatarImage.load(nil, app: app)
      contentAvatarImage.isHidden = true
      avatarImage.isHidden = false
    }
    let name = user?.nickname
      ?? (previewSignedIn
        ? app.text("小满的厨房", "Xiaoman's kitchen")
        : app.text("登录恰饭有谱", "Sign in to Qiafan Youpu"))
    if nameLabel.text != name { nameLabel.text = name }
    let region: String
    if let user {
      let country = user.countryCode.flatMap {
        Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
          .localizedString(forRegionCode: $0)
      }
      let parts = [country, user.regionCode].compactMap { $0 }.filter { !$0.isEmpty }
      region = parts.isEmpty ? app.text("地区未设置", "Region not set") : parts.joined(separator: " · ")
    } else {
      region = previewSignedIn
        ? app.text("中国 · 上海", "China · Shanghai")
        : app.text("收藏菜谱，记录下厨日常", "Save recipes and keep a cooking journal")
    }
    if regionLabel.text != region { regionLabel.text = region }
    if menuChanged {
      actionButton.setTitle(
        signedIn ? app.text("编辑资料", "Edit profile") : app.text("去登录", "Sign in"),
        for: .normal)
    }
    let request = user.flatMap {
      QFRemoteImageRequest(
        urlString: $0.avatarUrl, environment: app.api.environment.name,
        apiBaseURL: app.api.environment.baseURL, userID: $0.userId)
    }
    let placeholder =
      signedIn ? UIImage(named: "default-avatar") : UIImage(systemName: "person.fill")
    let imageSize: CGFloat = request != nil ? 72 : (signedIn ? 48 : 36)
    if ownerChanged || menuChanged || renderedAvatarURL != user?.avatarUrl {
      avatarImage.snp.updateConstraints { $0.size.equalTo(imageSize) }
      avatarImage.layer.cornerRadius = request != nil ? 36 : 0
      avatarImage.tintColor = QFUI.disabledText
      avatarImage.load(request, placeholder: placeholder, size: CGSize(width: 72, height: 72))
    }
    if menuChanged {
      QFTabUI.clear(menu)
      for (index, item) in QFProfileMenuItem.items.enumerated() {
        if index > 0 {
          let divider = UIView()
          divider.backgroundColor = QFUI.border
          divider.snp.makeConstraints { $0.height.equalTo(0.5) }
          menu.addArrangedSubview(divider)
        }
        menu.addArrangedSubview(
          menuButton(
            item.destination, symbol: item.symbol,
            detail: signedIn ? "" : app.text("登录后查看", "Sign in to view")))
      }
      configureMenuButton(
        preference, destination: .preferences, symbol: "slider.horizontal.3",
        detail: signedIn ? "" : app.text("登录后设置", "Sign in to set"))
      configureMenuButton(
        membership, destination: .membership, symbol: "crown",
        detail: app.text("查看权益", "View benefits"))
    }
    renderedOwner = user?.userId
    renderedSignedIn = signedIn
    renderedAvatarURL = user?.avatarUrl
    renderedLanguage = app.interfaceLanguage
    if let cached = app.cachedContent(QFContentSummary.self, path: "me/content-summary") {
      renderSummary(cached)
    }
  }

  private func makeStats() -> UIView {
    let values = previewSignedIn ? ["128", "26", "12", "3"] : ["—", "—", "—", "—"]
    let row = QFTabUI.stack([], axis: .horizontal, spacing: 0)
    row.distribution = .fillEqually
    for (index, title) in [
      app.text("收藏", "Favorites"), app.text("做菜天数", "Cooking days"),
      app.text("作品", "Posts"), app.text("贡献", "Contributions"),
    ].enumerated() {
      let value = QFTabUI.label(
        values[index], size: 22, weight: .semibold,
        color: previewSignedIn ? QFUI.text : QFUI.disabledText)
      let name = QFTabUI.label(title, size: 13, color: QFUI.secondary)
      value.textAlignment = .center
      statisticLabels.append(value)
      statisticNameLabels.append(name)
      name.textAlignment = .center
      row.addArrangedSubview(QFTabUI.stack([value, name], spacing: 4))
    }
    return QFTabUI.card(row, padding: 14)
  }

  private func feature(
    _ destination: QFProfileDestination, subtitle: String, symbol: String, color: UIColor,
    background: UIColor
  ) -> UIButton {
    let title = destination.title(app: app)
    let button = QFTabUI.button("", background: background) { [weak self] in
      self?.openProtected(destination)
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

  private func menuButton(
    _ destination: QFProfileDestination, symbol: String, detail: String
  ) -> UIButton {
    let button = QFTabUI.button("") { [weak self] in self?.openProtected(destination) }
    configureMenuButton(button, destination: destination, symbol: symbol, detail: detail)
    return button
  }

  private func configureMenuButton(
    _ button: UIButton, destination: QFProfileDestination, symbol: String, detail: String
  ) {
    let title = destination.title(app: app)
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
      $0.leading.trailing.equalToSuperview().inset(16)
      $0.top.bottom.equalToSuperview().inset(14)
      $0.height.greaterThanOrEqualTo(28)
    }
  }

  private func openProtected(_ destination: QFProfileDestination) {
    guard user != nil else {
      onLogin()
      return
    }
    guard presentedViewController == nil else { return }
    let controller: QFProfileContentController
    switch destination {
    case .publishWork: controller = QFWorkEditorViewController(app: app)
    case .contributeImage: controller = QFContributionEditorViewController(app: app)
    case .works: controller = QFMyWorksViewController(app: app)
    case .contributions: controller = QFContributionsViewController(app: app)
    case .favorites: controller = QFFavoritesViewController(app: app)
    case .cookingHistory: controller = QFCookingHistoryViewController(app: app)
    case .preferences: controller = QFInterestPreferencesViewController(app: app)
    case .membership: controller = QFMembershipViewController(app: app)
    case .assistant: controller = QFAssistantIngredientViewController(app: app, householdID: app.planningHouseholdID)
    }
    controller.onChanged = { [weak self] in self?.loadContentSummary() }
    qfPush(controller)
  }

  private func renderSummary(_ summary: QFContentSummary) {
    guard lastSummary != summary else { return }
    for (label, value) in zip(
      statisticLabels,
      [summary.favorites, summary.cookingDays, summary.publishedWorks, summary.contributions])
    {
      let text = String(value)
      if label.text != text {
        label.text = text
        label.textColor = QFUI.text
      }
    }
    if lastSummary?.avatarMediaId != summary.avatarMediaId || lastSummary == nil {
      contentAvatarImage.load(summary.avatarMediaId, app: app)
      contentAvatarImage.isHidden = summary.avatarMediaId == nil
      avatarImage.isHidden = summary.avatarMediaId != nil
    }
    lastSummary = summary
  }
  private var isProfileVisible: Bool {
    viewIsActive && isViewLoaded && view.window != nil
      && navigationController?.topViewController === self
      && presentedViewController == nil
  }
  private func refreshOnEntry() {
    profileTask?.cancel()
    guard let owner = app.user?.userId, isProfileVisible else { return }
    profileTask = Task { [weak self, app] in
      do {
        // Every completed entry performs a real /me request; it does not use the response TTL.
        try await app.restoreUser()
      } catch is CancellationError {
        return
      } catch {
        // Keep the displayed profile during a failed background refresh.
      }
      guard let self, !Task.isCancelled, app.user?.userId == owner, self.isProfileVisible else {
        return
      }
      self.user = app.user
      self.refreshProfile()
      self.loadContentSummary()
    }
  }
  private func loadContentSummary() {
    guard isProfileVisible, let owner = user?.userId else { return }
    summaryTask?.cancel()
    summaryTask = Task { [weak self, app] in
      do {
        let summary: QFContentSummary = try await app.contentRequest(path: "me/content-summary")
        guard let self, !Task.isCancelled, self.user?.userId == owner, self.isProfileVisible else {
          return
        }
        self.renderSummary(summary)
      } catch {
        guard let self, !Task.isCancelled, self.user?.userId == owner, self.isProfileVisible else {
          return
        }
        if self.lastSummary == nil {
          QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self.view)
        }
      }
    }
  }

  private func openEditProfile(_ profile: QFUserProfile) {
    guard presentedViewController == nil else { return }
    let controller = QFPublicProfileEditorViewController(app: app)
    controller.onChanged = { [weak self] in self?.loadContentSummary() }
    qfPush(controller)
  }

  private func showProfileMessage(title: String, message: String) {
    guard presentedViewController == nil else { return }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: app.text("知道了", "OK"), style: .default))
    present(alert, animated: true)
  }

  private func openSettings() {
    guard presentedViewController == nil else { return }
    let controller = QFSettingsViewController(app: app) { [weak self] in
      self?.navigationController?.popViewController(animated: true)
    }
    qfPush(controller)
  }

  private func openLanguageSettings() {
    guard presentedViewController == nil else { return }
    let controller = QFLanguageSettingsViewController(
      app: app, selected: app.interfaceLanguage
    ) { [weak self] language in
      self?.selectLanguage(language)
    }
    qfPush(controller)
  }

  private func selectLanguage(_ value: String) {
    let language = QFInterfaceLanguage.normalized(value).rawValue
    QFLocalSettingsStore.saveInterfaceLanguage(language)
    app.setInterfaceLanguage(language)
  }
}

private enum QFProfileDestination {
  case publishWork
  case contributeImage
  case works
  case contributions
  case favorites
  case cookingHistory
  case preferences
  case membership
  case assistant

  @MainActor
  func title(app: QFAppSession) -> String {
    switch self {
    case .publishWork: return app.text("发布作品", "Publish post")
    case .contributeImage: return app.text("补充图片", "Contribute photos")
    case .works: return app.text("我的作品", "My posts")
    case .contributions: return app.text("我的图片贡献", "My photo contributions")
    case .favorites: return app.text("我的收藏", "My favorites")
    case .cookingHistory: return app.text("做菜记录与统计", "Cooking history and stats")
    case .preferences: return app.text("兴趣偏好", "Interests and preferences")
    case .membership: return app.text("会员订阅", "Membership")
    case .assistant: return app.text("AI 助手", "AI assistant")
    }
  }
}

private struct QFProfileMenuItem {
  let destination: QFProfileDestination
  let symbol: String
  static let items = [
    QFProfileMenuItem(destination: .works, symbol: "photo"),
    QFProfileMenuItem(destination: .contributions, symbol: "photo.badge.plus"),
    QFProfileMenuItem(destination: .favorites, symbol: "bookmark"),
    QFProfileMenuItem(destination: .cookingHistory, symbol: "calendar.badge.checkmark"),
    QFProfileMenuItem(destination: .assistant, symbol: "sparkles"),
  ]
}
