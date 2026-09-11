import Combine
import SafariServices
import SnapKit
import UIKit

enum QFLocalSettingsStore {
  private struct Persisted: Codable {
    let schemaVersion: Int
    let interfaceLanguage: String
    let planReminders: Bool
    let workAndContributionUpdates: Bool
  }

  private static let key = "qfyp.user.settings.v1"

  static var hasSavedSettings: Bool { UserDefaults.standard.data(forKey: key) != nil }

  static func current(defaults: UserDefaults = .standard) -> QFUserSettings {
    let fallback = Persisted(
      schemaVersion: 1, interfaceLanguage: "zh-Hans", planReminders: true,
      workAndContributionUpdates: true)
    let persisted = defaults.data(forKey: key)
      .flatMap { try? JSONDecoder().decode(Persisted.self, from: $0) }
      .flatMap { $0.schemaVersion == 1 ? $0 : nil } ?? fallback
    return QFUserSettings(
      theme: QFThemeManager.shared.current.rawValue,
      interfaceLanguage: persisted.interfaceLanguage,
      planReminders: persisted.planReminders,
      workAndContributionUpdates: persisted.workAndContributionUpdates)
  }

  static func save(_ settings: QFUserSettings, defaults: UserDefaults = .standard) {
    let value = Persisted(
      schemaVersion: 1, interfaceLanguage: settings.interfaceLanguage,
      planReminders: settings.planReminders,
      workAndContributionUpdates: settings.workAndContributionUpdates)
    if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
  }
}

@MainActor
final class QFSettingsViewController: UIViewController {
  private let app: QFAppSession
  private let onClose: () -> Void
  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()
  private let themeRow = QFSettingsActionRow(title: "主题设置", detail: QFThemeManager.shared.current.title)
  private let languageRow = QFSettingsActionRow(title: "界面语言", detail: "简体中文")
  private let planReminderRow = QFSettingsSwitchRow(title: "计划提醒")
  private let progressRow = QFSettingsSwitchRow(title: "作品与图片进度")
  private let cacheRow = QFSettingsActionRow(title: "清理缓存")
  private let logoutButton = QFAuthLoadingButton(
    "退出登录", background: QFUI.surface, textColor: QFUI.danger, size: 17, cornerRadius: 17)
  private var preferences = QFLocalSettingsStore.current()
  private var didReconcileServer = false
  private var syncTask: Task<Void, Never>?
  private var cacheTask: Task<Void, Never>?
  private var logoutTask: Task<Void, Never>?
  private var subscriptions = Set<AnyCancellable>()

  init(app: QFAppSession, onClose: @escaping () -> Void) {
    self.app = app
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    syncTask?.cancel()
    cacheTask?.cancel()
    logoutTask?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.accessibilityIdentifier = "settings.screen"
    buildLayout()
    wireActions()
    render()
    app.$user.receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.renderAccountState()
    }.store(in: &subscriptions)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    reconcileServerOnce()
  }

  private func buildLayout() {
    let back = QFTabUI.iconButton("chevron.left", label: "返回", size: 22) { [weak self] in
      self?.onClose()
    }
    back.tintColor = QFUI.text
    let title = QFTabUI.label("设置", size: 23, weight: .semibold)
    title.textAlignment = .center
    title.accessibilityTraits.insert(.header)
    let trailing = UIView()
    trailing.snp.makeConstraints { $0.width.height.equalTo(40) }
    let header = QFTabUI.stack([back, title, trailing], axis: .horizontal, spacing: 4)
    header.alignment = .center

    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = false
    view.addSubview(scrollView)
    scrollView.snp.makeConstraints { $0.edges.equalTo(view.safeAreaLayoutGuide) }
    let content = UIView()
    scrollView.addSubview(content)
    content.snp.makeConstraints {
      $0.edges.equalTo(scrollView.contentLayoutGuide)
      $0.width.equalTo(scrollView.frameLayoutGuide)
    }
    contentStack.axis = .vertical
    contentStack.spacing = 14
    content.addSubview(contentStack)
    contentStack.snp.makeConstraints {
      $0.top.equalToSuperview().offset(10)
      $0.bottom.equalToSuperview().inset(24)
      $0.centerX.equalToSuperview()
      $0.leading.greaterThanOrEqualToSuperview().offset(20)
      $0.trailing.lessThanOrEqualToSuperview().inset(20)
      $0.width.equalToSuperview().offset(-40).priority(999)
      $0.width.lessThanOrEqualTo(600)
    }
    contentStack.addArrangedSubview(header)
    contentStack.setCustomSpacing(20, after: header)
    contentStack.addArrangedSubview(section(
      title: "外观与显示", rows: [themeRow, languageRow]))
    contentStack.addArrangedSubview(section(
      title: "通知", rows: [planReminderRow, progressRow]))
    contentStack.addArrangedSubview(section(
      title: "账号与数据",
      rows: [
        QFSettingsActionRow(title: "编辑资料", action: { [weak self] in
          self?.openProtected("编辑资料")
        }),
        QFSettingsActionRow(
          title: "账号与隐私", subtitle: "管理账号、权限与注销", action: { [weak self] in
            self?.openProtected("账号与隐私")
          }),
        cacheRow,
      ]))
    let legalPair = QFSettingsLegalPair(
      leftTitle: "用户协议", rightTitle: "隐私政策",
      onLeft: { [weak self] in self?.openLegal(.userAgreement) },
      onRight: { [weak self] in self?.openLegal(.privacyPolicy) })
    contentStack.addArrangedSubview(section(
      title: "帮助与协议",
      rows: [
        QFSettingsActionRow(title: "帮助与反馈", action: { [weak self] in self?.openHelp() }),
        legalPair,
        QFSettingsActionRow(title: "图片使用授权", action: { [weak self] in
          self?.openLegal(.imageLicense)
        }),
        QFSettingsActionRow(title: "图片侵权保护", action: { [weak self] in
          self?.openLegal(.imageRights)
        }),
      ]))
    logoutButton.accessibilityIdentifier = "settings.logout"
    logoutButton.snp.makeConstraints { $0.height.equalTo(54) }
    contentStack.addArrangedSubview(logoutButton)
  }

  private func section(title: String, rows: [UIView]) -> UIView {
    let heading = QFTabUI.label(title, size: 14, weight: .medium, color: QFUI.secondary)
    let card = UIView()
    card.backgroundColor = QFUI.surface
    card.layer.cornerRadius = 18
    let rowsStack = QFTabUI.stack([], spacing: 0)
    for (index, row) in rows.enumerated() {
      if index > 0 {
        let divider = UIView()
        divider.backgroundColor = QFUI.border
        divider.snp.makeConstraints { $0.height.equalTo(0.5) }
        rowsStack.addArrangedSubview(divider)
      }
      rowsStack.addArrangedSubview(row)
    }
    card.addSubview(rowsStack)
    rowsStack.snp.makeConstraints {
      $0.top.bottom.equalToSuperview()
      $0.leading.trailing.equalToSuperview().inset(15)
    }
    return QFTabUI.stack([heading, card], spacing: 9)
  }

  private func wireActions() {
    themeRow.action = { [weak self] in self?.openThemeSettings() }
    languageRow.action = { [weak self] in self?.chooseLanguage() }
    planReminderRow.onChange = { [weak self] enabled in
      self?.replacePreferences(planReminders: enabled)
    }
    progressRow.onChange = { [weak self] enabled in
      self?.replacePreferences(workAndContributionUpdates: enabled)
    }
    cacheRow.action = { [weak self] in self?.confirmClearCache() }
    logoutButton.addAction(UIAction { [weak self] _ in self?.confirmLogout() }, for: .touchUpInside)
  }

  private func render() {
    themeRow.detail = QFThemeKind(rawValue: preferences.theme)?.title
      ?? QFThemeManager.shared.current.title
    languageRow.detail = preferences.interfaceLanguage == "zh-Hans"
      ? "简体中文" : preferences.interfaceLanguage
    planReminderRow.setOn(preferences.planReminders, animated: false)
    progressRow.setOn(preferences.workAndContributionUpdates, animated: false)
    renderAccountState()
  }

  private func renderAccountState() {
    logoutButton.isHidden = app.user == nil
  }

  private func replacePreferences(
    planReminders: Bool? = nil, workAndContributionUpdates: Bool? = nil
  ) {
    preferences = QFUserSettings(
      theme: preferences.theme,
      interfaceLanguage: preferences.interfaceLanguage,
      planReminders: planReminders ?? preferences.planReminders,
      workAndContributionUpdates: workAndContributionUpdates
        ?? preferences.workAndContributionUpdates)
    QFLocalSettingsStore.save(preferences)
    scheduleServerSync(preferences)
  }

  private func scheduleServerSync(_ value: QFUserSettings) {
    syncTask?.cancel()
    guard app.user != nil else { return }
    syncTask = Task { [weak self, app] in
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled else { return }
      do {
        let saved = try await app.updateUserSettings(value)
        guard !Task.isCancelled else { return }
        QFLocalSettingsStore.save(saved)
        self?.preferences = saved
      } catch is CancellationError {
        return
      } catch {
        // The device value remains usable offline and is retried when this page is opened again.
      }
    }
  }

  private func reconcileServerOnce() {
    guard !didReconcileServer, app.user != nil else { return }
    didReconcileServer = true
    let hadLocalSettings = QFLocalSettingsStore.hasSavedSettings
    let local = preferences
    syncTask = Task { [weak self, app] in
      do {
        if hadLocalSettings {
          let saved = try await app.updateUserSettings(local)
          guard !Task.isCancelled else { return }
          QFLocalSettingsStore.save(saved)
          self?.preferences = saved
          self?.render()
        } else {
          let remote = try await app.loadUserSettings()
          guard !Task.isCancelled else { return }
          QFLocalSettingsStore.save(remote)
          self?.preferences = remote
          self?.render()
          if let theme = QFThemeKind(rawValue: remote.theme), theme != QFThemeManager.shared.current {
            QFThemeManager.shared.apply(theme)
          }
        }
      } catch {
        // Local settings remain available when the server cannot be reached.
      }
    }
  }

  private func openThemeSettings() {
    guard presentedViewController == nil else { return }
    let controller = QFThemeSettingsViewController(app: app) { [weak self] in
      guard let self else { return }
      self.preferences = QFLocalSettingsStore.current()
      self.render()
    }
    controller.modalPresentationStyle = .fullScreen
    present(controller, animated: true)
  }

  private func chooseLanguage() {
    let sheet = UIAlertController(title: "界面语言", message: "当前版本支持简体中文", preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: "简体中文", style: .default) { [weak self] _ in
      guard let self else { return }
      self.preferences = QFUserSettings(
        theme: self.preferences.theme, interfaceLanguage: "zh-Hans",
        planReminders: self.preferences.planReminders,
        workAndContributionUpdates: self.preferences.workAndContributionUpdates)
      QFLocalSettingsStore.save(self.preferences)
      self.scheduleServerSync(self.preferences)
      self.render()
    })
    sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
    sheet.popoverPresentationController?.sourceView = languageRow
    sheet.popoverPresentationController?.sourceRect = languageRow.bounds
    present(sheet, animated: true)
  }

  private func openProtected(_ title: String) {
    guard app.user != nil else {
      showMessage(title: "需要登录", message: "登录后可以使用\(title)功能。")
      return
    }
    showMessage(title: title, message: "该功能暂未开放。")
  }

  private func openHelp() {
    showMessage(title: "帮助与反馈", message: "帮助与反馈暂未开放。")
  }

  private func openLegal(_ destination: QFSettingsLegalDestination) {
    let agreements = app.configuration?.agreements
    let rawURL: String?
    switch destination {
    case .userAgreement: rawURL = agreements?.userAgreementUrl
    case .privacyPolicy: rawURL = agreements?.privacyPolicyUrl
    case .imageLicense: rawURL = agreements?.imageLicenseUrl
    case .imageRights: rawURL = agreements?.imageRightsUrl
    }
    if let rawURL, let url = URL(string: rawURL), url.scheme?.lowercased() == "https",
      url.host?.isEmpty == false
    {
      let browser = SFSafariViewController(url: url)
      browser.preferredControlTintColor = QFUI.primary
      present(browser, animated: true)
      return
    }
    switch destination {
    case .userAgreement:
      present(QFAuthAgreementViewController(app: app, document: .terms), animated: true)
    case .privacyPolicy:
      present(QFAuthAgreementViewController(app: app, document: .privacy), animated: true)
    case .imageLicense, .imageRights:
      showMessage(title: destination.title, message: "内容暂时不可用，请稍后重试。")
    }
  }

  private func confirmClearCache() {
    let alert = UIAlertController(
      title: "清理缓存？", message: "清理可重新获取的临时图片，保留账号资料与未发布草稿。",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "清理", style: .destructive) { [weak self] _ in
      self?.clearCache()
    })
    present(alert, animated: true)
  }

  private func clearCache() {
    guard cacheTask == nil else { return }
    cacheRow.setLoading(true)
    cacheTask = Task { [weak self] in
      QFRemoteImagePipeline.cache.clearMemoryCache()
      URLCache.shared.removeAllCachedResponses()
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        QFRemoteImagePipeline.cache.clearDiskCache { continuation.resume() }
      }
      guard let self, !Task.isCancelled else { return }
      self.cacheRow.setLoading(false)
      self.cacheTask = nil
      self.showMessage(title: "已清理", message: "可重新获取的图片缓存已清理。")
    }
  }

  private func confirmLogout() {
    let alert = UIAlertController(title: "退出当前账号？", message: nil, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "继续使用", style: .cancel))
    alert.addAction(UIAlertAction(title: "退出登录", style: .destructive) { [weak self] _ in
      self?.logout()
    })
    present(alert, animated: true)
  }

  private func logout() {
    guard logoutTask == nil else { return }
    logoutButton.setLoading(true)
    logoutTask = Task { [weak self, app] in
      defer {
        self?.logoutButton.setLoading(false)
        self?.logoutTask = nil
      }
      do {
        try await app.logout()
        guard !Task.isCancelled else { return }
        self?.onClose()
      } catch is CancellationError {
        return
      } catch {
        self?.showMessage(title: "退出失败", message: error.localizedDescription)
      }
    }
  }

  private func showMessage(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "知道了", style: .default))
    present(alert, animated: true)
  }
}

private enum QFSettingsLegalDestination {
  case userAgreement
  case privacyPolicy
  case imageLicense
  case imageRights

  var title: String {
    switch self {
    case .userAgreement: return "用户协议"
    case .privacyPolicy: return "隐私政策"
    case .imageLicense: return "图片使用授权"
    case .imageRights: return "图片侵权保护"
    }
  }
}

@MainActor
private final class QFSettingsActionRow: UIControl {
  private let titleLabel: UILabel
  private let subtitleLabel: UILabel?
  private let detailLabel = QFTabUI.label("", size: 14, color: QFUI.secondary)
  private let chevron = QFTabUI.symbol("chevron.right", size: 14, color: QFUI.secondary)
  private let spinner = UIActivityIndicatorView(style: .medium)
  var action: (() -> Void)?

  var detail: String? {
    didSet {
      detailLabel.text = detail
      detailLabel.isHidden = detail?.isEmpty != false
    }
  }

  init(title: String, detail: String? = nil, subtitle: String? = nil, action: (() -> Void)? = nil) {
    titleLabel = QFTabUI.label(title, size: 16, weight: .medium, lines: 0)
    subtitleLabel = subtitle.map { QFTabUI.label($0, size: 11, color: QFUI.secondary, lines: 0) }
    self.action = action
    super.init(frame: .zero)
    accessibilityLabel = title
    accessibilityTraits = .button
    self.detail = detail
    detailLabel.text = detail
    detailLabel.isHidden = detail?.isEmpty != false
    let labels = QFTabUI.stack([titleLabel] + (subtitleLabel.map { [$0] } ?? []), spacing: 3)
    spinner.color = QFUI.primary
    spinner.hidesWhenStopped = true
    let row = QFTabUI.stack([labels, UIView(), detailLabel, spinner, chevron], axis: .horizontal, spacing: 8)
    row.alignment = .center
    row.isUserInteractionEnabled = false
    addSubview(row)
    row.snp.makeConstraints { $0.edges.equalToSuperview() }
    snp.makeConstraints { $0.height.greaterThanOrEqualTo(subtitle == nil ? 48 : 62) }
    addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)
  }

  required init?(coder: NSCoder) { nil }

  override var isHighlighted: Bool {
    didSet { alpha = isHighlighted ? 0.55 : 1 }
  }

  func setLoading(_ loading: Bool) {
    isEnabled = !loading
    chevron.isHidden = loading
    if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
    accessibilityValue = loading ? "处理中" : detail
  }
}

@MainActor
private final class QFSettingsSwitchRow: UIView {
  private let toggle = UISwitch()
  var onChange: ((Bool) -> Void)?

  init(title: String) {
    super.init(frame: .zero)
    let label = QFTabUI.label(title, size: 16, weight: .medium, lines: 0)
    toggle.onTintColor = QFUI.success
    toggle.accessibilityLabel = title
    toggle.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.onChange?(self.toggle.isOn)
    }, for: .valueChanged)
    let row = QFTabUI.stack([label, UIView(), toggle], axis: .horizontal, spacing: 8)
    row.alignment = .center
    addSubview(row)
    row.snp.makeConstraints { $0.edges.equalToSuperview() }
    snp.makeConstraints { $0.height.greaterThanOrEqualTo(48) }
  }

  required init?(coder: NSCoder) { nil }
  func setOn(_ value: Bool, animated: Bool) { toggle.setOn(value, animated: animated) }
}

@MainActor
private final class QFSettingsLegalPair: UIView {
  init(leftTitle: String, rightTitle: String, onLeft: @escaping () -> Void, onRight: @escaping () -> Void) {
    super.init(frame: .zero)
    let left = QFSettingsActionRow(title: leftTitle, action: onLeft)
    let right = QFSettingsActionRow(title: rightTitle, action: onRight)
    let divider = UIView()
    divider.backgroundColor = QFUI.border
    divider.snp.makeConstraints { $0.width.equalTo(0.5); $0.height.equalTo(28) }
    let row = QFTabUI.stack([left, divider, right], axis: .horizontal, spacing: 14)
    row.alignment = .center
    row.distribution = .fill
    left.snp.makeConstraints { $0.width.equalTo(right) }
    addSubview(row)
    row.snp.makeConstraints { $0.edges.equalToSuperview() }
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class QFThemeSettingsViewController: UIViewController {
  private let app: QFAppSession
  private let onApplied: () -> Void
  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()
  private let optionsStack = UIStackView()
  private let applyButton = QFAuthLoadingButton("应用主题", size: 18)
  private var selected = QFThemeManager.shared.current
  private var optionViews: [QFThemeKind: QFThemeOptionView] = [:]
  private var applyTask: Task<Void, Never>?

  init(app: QFAppSession, onApplied: @escaping () -> Void) {
    self.app = app
    self.onApplied = onApplied
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }
  deinit { applyTask?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.accessibilityIdentifier = "settings.theme.screen"
    buildLayout()
    renderSelection()
  }

  private func buildLayout() {
    let back = QFTabUI.iconButton("chevron.left", label: "返回", size: 22) { [weak self] in
      self?.dismiss(animated: true)
    }
    back.tintColor = QFUI.text
    let title = QFTabUI.label("主题设置", size: 23, weight: .semibold)
    title.textAlignment = .center
    title.accessibilityTraits.insert(.header)
    let trailing = UIView()
    trailing.snp.makeConstraints { $0.width.height.equalTo(40) }
    let header = QFTabUI.stack([back, title, trailing], axis: .horizontal, spacing: 4)
    header.alignment = .center

    let heading = QFTabUI.label("选择你喜欢的配色", size: 24, weight: .bold, lines: 0)
    let subtitle = QFTabUI.label("应用到所有页面和操作控件", size: 15, color: QFUI.secondary, lines: 0)
    optionsStack.axis = .vertical
    optionsStack.spacing = 14
    for theme in QFThemeKind.allCases {
      let option = QFThemeOptionView(theme: theme) { [weak self] in
        self?.selected = theme
        self?.renderSelection()
      }
      optionViews[theme] = option
      optionsStack.addArrangedSubview(option)
    }

    view.addSubview(applyButton)
    applyButton.accessibilityIdentifier = "settings.theme.apply"
    applyButton.snp.makeConstraints {
      $0.centerX.equalTo(view.safeAreaLayoutGuide)
      $0.leading.greaterThanOrEqualTo(view.safeAreaLayoutGuide).offset(20)
      $0.trailing.lessThanOrEqualTo(view.safeAreaLayoutGuide).inset(20)
      $0.width.equalTo(view.safeAreaLayoutGuide).offset(-40).priority(999)
      $0.width.lessThanOrEqualTo(620)
      $0.bottom.equalTo(view.safeAreaLayoutGuide).inset(10)
      $0.height.equalTo(54)
    }
    applyButton.addAction(UIAction { [weak self] _ in self?.applySelection() }, for: .touchUpInside)

    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = false
    view.addSubview(scrollView)
    scrollView.snp.makeConstraints {
      $0.top.leading.trailing.equalTo(view.safeAreaLayoutGuide)
      $0.bottom.equalTo(applyButton.snp.top).offset(-12)
    }
    let content = UIView()
    scrollView.addSubview(content)
    content.snp.makeConstraints {
      $0.edges.equalTo(scrollView.contentLayoutGuide)
      $0.width.equalTo(scrollView.frameLayoutGuide)
    }
    contentStack.axis = .vertical
    contentStack.spacing = 9
    content.addSubview(contentStack)
    contentStack.snp.makeConstraints {
      $0.top.equalToSuperview().offset(10)
      $0.bottom.equalToSuperview().inset(22)
      $0.centerX.equalToSuperview()
      $0.leading.greaterThanOrEqualToSuperview().offset(20)
      $0.trailing.lessThanOrEqualToSuperview().inset(20)
      $0.width.equalToSuperview().offset(-40).priority(999)
      $0.width.lessThanOrEqualTo(620)
    }
    contentStack.addArrangedSubview(header)
    contentStack.setCustomSpacing(22, after: header)
    contentStack.addArrangedSubview(heading)
    contentStack.addArrangedSubview(subtitle)
    contentStack.setCustomSpacing(20, after: subtitle)
    contentStack.addArrangedSubview(optionsStack)
  }

  private func renderSelection() {
    optionViews.forEach { theme, option in option.setSelected(theme == selected) }
    applyButton.accessibilityValue = selected == QFThemeManager.shared.current
      ? "当前主题" : "待应用\(selected.title)"
  }

  private func applySelection() {
    guard applyTask == nil else { return }
    let current = QFLocalSettingsStore.current()
    let next = QFUserSettings(
      theme: selected.rawValue, interfaceLanguage: current.interfaceLanguage,
      planReminders: current.planReminders,
      workAndContributionUpdates: current.workAndContributionUpdates)
    if app.user == nil {
      finishApply(next)
      return
    }
    applyButton.setLoading(true)
    applyTask = Task { [weak self, app] in
      guard let self else { return }
      do {
        let saved = try await app.updateUserSettings(next)
        guard !Task.isCancelled else { return }
        self.applyTask = nil
        self.applyButton.setLoading(false)
        self.finishApply(saved)
      } catch is CancellationError {
        self.applyTask = nil
        self.applyButton.setLoading(false)
      } catch {
        self.applyTask = nil
        self.applyButton.setLoading(false)
        self.offerDeviceOnlyFallback(next)
      }
    }
  }

  private func offerDeviceOnlyFallback(_ settings: QFUserSettings) {
    let alert = UIAlertController(
      title: "暂时无法同步", message: "服务器同步失败。你仍可只在这台设备上应用主题。",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "仅应用到此设备", style: .default) { [weak self] _ in
      self?.finishApply(settings)
    })
    present(alert, animated: true)
  }

  private func finishApply(_ settings: QFUserSettings) {
    guard let theme = QFThemeKind(rawValue: settings.theme) else { return }
    QFLocalSettingsStore.save(settings)
    dismiss(animated: false) { [onApplied] in
      onApplied()
      QFThemeManager.shared.apply(theme)
    }
  }
}

@MainActor
private final class QFThemeOptionView: UIControl {
  private let theme: QFThemeKind
  private let check = UIImageView()

  init(theme: QFThemeKind, action: @escaping () -> Void) {
    self.theme = theme
    super.init(frame: .zero)
    backgroundColor = theme.previewSurface
    layer.cornerRadius = 20
    layer.borderWidth = 1
    layer.borderColor = theme.previewBorder.cgColor
    accessibilityLabel = theme.title
    accessibilityHint = theme.subtitle
    accessibilityTraits = .button

    let sample = UIView()
    sample.backgroundColor = theme.previewBackground
    sample.layer.cornerRadius = 14
    sample.snp.makeConstraints { $0.width.equalTo(104); $0.height.equalTo(96) }
    let lineOne = UIView()
    let lineTwo = UIView()
    let field = UIView()
    let sampleButton = UIView()
    lineOne.backgroundColor = theme.previewText
    lineTwo.backgroundColor = theme.previewText.withAlphaComponent(0.62)
    field.backgroundColor = theme.previewSurface
    field.layer.cornerRadius = 8
    field.layer.borderWidth = 1
    field.layer.borderColor = theme.previewBorder.cgColor
    sampleButton.backgroundColor = theme.previewPrimary
    sampleButton.layer.cornerRadius = 8
    [lineOne, lineTwo, field, sampleButton].forEach { sample.addSubview($0) }
    lineOne.snp.makeConstraints {
      $0.top.leading.equalToSuperview().offset(12)
      $0.width.equalTo(34)
      $0.height.equalTo(5)
    }
    lineTwo.snp.makeConstraints {
      $0.top.equalTo(lineOne.snp.bottom).offset(8)
      $0.leading.equalTo(lineOne)
      $0.width.equalTo(58)
      $0.height.equalTo(4)
    }
    field.snp.makeConstraints {
      $0.top.equalTo(lineTwo.snp.bottom).offset(10)
      $0.leading.trailing.equalToSuperview().inset(12)
      $0.height.equalTo(25)
    }
    sampleButton.snp.makeConstraints {
      $0.top.equalTo(field.snp.bottom).offset(8)
      $0.leading.trailing.equalTo(field)
      $0.height.equalTo(22)
    }

    check.contentMode = .scaleAspectFit
    check.layer.cornerRadius = 13
    check.clipsToBounds = true
    check.snp.makeConstraints { $0.width.height.equalTo(24) }
    let title = QFTabUI.label(theme.title, size: 22, weight: .bold, color: theme.previewText)
    let subtitle = QFTabUI.label(
      theme.subtitle, size: 14, color: theme.previewText.withAlphaComponent(0.72))
    let colors = QFTabUI.stack(theme.previewColors.map { color -> UIView in
      let swatch = UIView()
      swatch.backgroundColor = color
      swatch.layer.cornerRadius = 7
      swatch.layer.borderWidth = 0.5
      swatch.layer.borderColor = theme.previewBorder.cgColor
      swatch.snp.makeConstraints { $0.width.height.equalTo(14) }
      return swatch
    }, axis: .horizontal, spacing: 5)
    let copy = QFTabUI.stack([title, subtitle, colors], spacing: 8)
    let row = QFTabUI.stack([sample, copy, UIView(), check], axis: .horizontal, spacing: 10)
    row.alignment = .center
    row.isUserInteractionEnabled = false
    addSubview(row)
    row.snp.makeConstraints { $0.edges.equalToSuperview().inset(14) }
    snp.makeConstraints { $0.height.greaterThanOrEqualTo(133) }
    addAction(UIAction { _ in action() }, for: .touchUpInside)
  }

  required init?(coder: NSCoder) { nil }

  override var isHighlighted: Bool {
    didSet { alpha = isHighlighted ? 0.72 : 1 }
  }

  func setSelected(_ selected: Bool) {
    accessibilityTraits = selected ? [.button, .selected] : [.button]
    layer.borderWidth = selected ? 2 : 1
    layer.borderColor = (selected ? theme.previewPrimary : theme.previewBorder).cgColor
    check.backgroundColor = selected ? theme.previewPrimary : .clear
    check.tintColor = selected ? theme.previewOnPrimary : theme.previewBorder
    check.image = selected ? UIImage(systemName: "checkmark") : UIImage(systemName: "circle")
  }
}
