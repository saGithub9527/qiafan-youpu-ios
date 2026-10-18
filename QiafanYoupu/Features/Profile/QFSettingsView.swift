import AuthenticationServices
import Combine
import Kingfisher
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

  static func current(defaults: UserDefaults = .standard, scope: String? = nil) -> QFUserSettings {
    let fallback = Persisted(
      schemaVersion: 1, interfaceLanguage: "zh-Hans", planReminders: true,
      workAndContributionUpdates: true)
    let persisted =
      defaults.data(forKey: scope.map { key + "." + $0 } ?? key)
      .flatMap { try? JSONDecoder().decode(Persisted.self, from: $0) }
      .flatMap { $0.schemaVersion == 1 ? $0 : nil } ?? fallback
    return QFUserSettings(
      theme: QFThemeManager.shared.current.rawValue,
      interfaceLanguage: QFInterfaceLanguage.normalized(persisted.interfaceLanguage).rawValue,
      planReminders: persisted.planReminders,
      workAndContributionUpdates: persisted.workAndContributionUpdates)
  }

  static func save(
    _ settings: QFUserSettings, defaults: UserDefaults = .standard, scope: String? = nil
  ) {
    let value = Persisted(
      schemaVersion: 1, interfaceLanguage: settings.interfaceLanguage,
      planReminders: settings.planReminders,
      workAndContributionUpdates: settings.workAndContributionUpdates)
    if let data = try? JSONEncoder().encode(value) {
      defaults.set(data, forKey: scope.map { key + "." + $0 } ?? key)
      if let scope {
        NotificationCenter.default.post(
          name: .qfLocalSettingsDidChange, object: nil,
          userInfo: ["scope": scope, "planReminders": settings.planReminders])
      }
    }
  }

  @discardableResult
  static func saveInterfaceLanguage(
    _ language: String, defaults: UserDefaults = .standard, scope: String? = nil
  ) -> QFUserSettings {
    let current = current(defaults: defaults, scope: scope)
    let value = QFUserSettings(
      theme: current.theme,
      interfaceLanguage: QFInterfaceLanguage.normalized(language).rawValue,
      planReminders: current.planReminders,
      workAndContributionUpdates: current.workAndContributionUpdates)
    save(value, defaults: defaults, scope: scope)
    return value
  }
}

@MainActor
final class QFSettingsViewController: UIViewController {
  private let app: QFAppSession
  private let onClose: () -> Void
  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()
  private let titleLabel = QFTabUI.label("", size: 23, weight: .semibold)
  private var backButton: UIButton!
  private var themeRow: QFSettingsActionRow!
  private var languageRow: QFSettingsActionRow!
  private var planReminderRow: QFSettingsSwitchRow!
  private var reminderDetailRow: QFSettingsActionRow!
  private var progressRow: QFSettingsSwitchRow!
  private var householdRow: QFSettingsActionRow!
  private var cacheRow: QFSettingsActionRow!
  private var logoutButton: QFAuthLoadingButton!
  private var preferences = QFLocalSettingsStore.current()
  private var didReconcileServer = false
  private var syncTask: Task<Void, Never>?
  private var cacheTask: Task<Void, Never>?
  private var cacheSizeTask: Task<Void, Never>?
  private var diskCacheBytes: UInt = 0
  private var memoryCacheBytes = 0
  private var logoutTask: Task<Void, Never>?
  private var subscriptions = Set<AnyCancellable>()

  init(app: QFAppSession, onClose: @escaping () -> Void) {
    self.app = app
    self.onClose = onClose
    let local = QFLocalSettingsStore.current(scope: app.contentScope)
    let restored = UserDefaults.standard.bool(forKey: "qf.settings.pending." + app.contentScope)
      ? local : app.userSettings ?? local
    preferences = QFUserSettings(
      theme: restored.theme, interfaceLanguage: app.interfaceLanguage,
      planReminders: restored.planReminders,
      workAndContributionUpdates: restored.workAndContributionUpdates)
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    syncTask?.cancel()
    cacheTask?.cancel()
    cacheSizeTask?.cancel()
    logoutTask?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.accessibilityIdentifier = "settings.screen"
    buildLayout()
    rebuildLocalizedContent()
    app.$user.receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.renderAccountState()
    }.store(in: &subscriptions)
    app.$userSettings.dropFirst().compactMap { $0 }.receive(on: DispatchQueue.main).sink {
      [weak self] value in
      guard let self else { return }
      let merged = QFUserSettings(
        theme: QFThemeManager.shared.current.rawValue,
        interfaceLanguage: self.preferences.interfaceLanguage,
        planReminders: value.planReminders,
        workAndContributionUpdates: value.workAndContributionUpdates)
      guard merged != self.preferences else { return }
      self.preferences = merged
      QFLocalSettingsStore.save(merged, scope: self.app.contentScope)
      self.render()
    }.store(in: &subscriptions)
    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] _ in
      DispatchQueue.main.async { self?.rebuildLocalizedContent() }
    }.store(in: &subscriptions)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    reconcileServerOnce()
    updateCacheSize()
  }

  private func buildLayout() {
    backButton = QFTabUI.iconButton(
      "chevron.left", label: app.text("返回", "Back"), size: 22
    ) { [weak self] in
      self?.onClose()
    }
    backButton.snp.remakeConstraints { $0.size.equalTo(44) }
    backButton.tintColor = QFUI.text
    titleLabel.textAlignment = .center
    titleLabel.accessibilityTraits.insert(.header)
    let trailing = UIView()
    trailing.snp.makeConstraints { $0.width.height.equalTo(44) }
    let header = QFTabUI.stack([backButton, titleLabel, trailing], axis: .horizontal, spacing: 4)
    header.alignment = .center
    QFSettingsPageUI.installHeader(header, in: view)

    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = false
    view.addSubview(scrollView)
    scrollView.snp.makeConstraints {
      $0.top.equalTo(header.snp.bottom)
      $0.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
    }
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
  }

  private func rebuildLocalizedContent() {
    guard isViewLoaded else { return }
    titleLabel.text = app.text("设置", "Settings")
    backButton.accessibilityLabel = app.text("返回", "Back")
    QFTabUI.clear(contentStack)

    themeRow = QFSettingsActionRow(
      title: app.text("主题设置", "Appearance"),
      detail: QFThemeManager.shared.current.title(
        language: QFInterfaceLanguage.normalized(app.interfaceLanguage)))
    languageRow = QFSettingsActionRow(
      title: app.text("界面语言", "App language"), detail: QFInterfaceLanguage.normalized(
        preferences.interfaceLanguage).autonym)
    planReminderRow = QFSettingsSwitchRow(title: app.text("计划提醒", "Plan reminders"))
    reminderDetailRow = QFSettingsActionRow(
      title: app.text("提醒时间与时区", "Reminder times and timezone"),
      subtitle: app.text("设置每餐提醒", "Set reminders for each meal"))
    progressRow = QFSettingsSwitchRow(
      title: app.text("作品与图片进度", "Post and photo updates"))
    householdRow = QFSettingsActionRow(
      title: app.text("家庭与共享", "Household and sharing"),
      subtitle: app.text("管理成员与邀请", "Manage members and invitations"))
    cacheRow = QFSettingsActionRow(title: app.text("清理缓存", "Clear cache"))

    contentStack.addArrangedSubview(
      section(
        title: app.text("外观与显示", "Appearance and language"),
        rows: [themeRow, languageRow]))
    contentStack.addArrangedSubview(
      section(
        title: app.text("通知", "Notifications"),
        rows: [planReminderRow, reminderDetailRow, progressRow]))
    contentStack.addArrangedSubview(
      section(
        title: app.text("账号与数据", "Account and data"),
        rows: [
          QFSettingsActionRow(
            title: app.text("编辑资料", "Edit profile"),
            action: { [weak self] in
              self?.openEditProfile()
            }),
          QFSettingsActionRow(
            title: app.text("账号与隐私", "Account and privacy"),
            subtitle: app.text("查看账号与登录安全", "Account and sign-in security"),
            action: { [weak self] in
              self?.openAccountPrivacy()
            }),
          householdRow,
          cacheRow,
        ]))
    let legalPair = QFSettingsLegalPair(
      leftTitle: app.text("用户协议", "Terms of service"),
      rightTitle: app.text("隐私政策", "Privacy policy"),
      onLeft: { [weak self] in self?.openLegal(.userAgreement) },
      onRight: { [weak self] in self?.openLegal(.privacyPolicy) })
    contentStack.addArrangedSubview(
      section(
        title: app.text("帮助与协议", "Help and policies"),
        rows: [
          QFSettingsActionRow(
            title: app.text("帮助与反馈", "Help and feedback"),
            action: { [weak self] in self?.openHelp() }),
          legalPair,
          QFSettingsActionRow(
            title: app.text("图片使用授权", "Image licence"),
            action: { [weak self] in
              self?.openLegal(.imageLicense)
            }),
          QFSettingsActionRow(
            title: app.text("图片侵权保护", "Image rights protection"),
            action: { [weak self] in
              self?.openLegal(.imageRights)
            }),
        ]))
    logoutButton = QFAuthLoadingButton(
      app.text("退出登录", "Sign out"), background: QFUI.surface, textColor: QFUI.danger,
      size: 17, cornerRadius: 17)
    logoutButton.accessibilityIdentifier = "settings.logout"
    logoutButton.snp.makeConstraints { $0.height.equalTo(54) }
    contentStack.addArrangedSubview(logoutButton)
    wireActions()
    render()
    if cacheSizeTask != nil { updateCacheSize() }
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
    languageRow.action = { [weak self] in self?.openLanguageSettings() }
    reminderDetailRow.action = { [weak self] in self?.openReminderSettings() }
    householdRow.action = { [weak self] in self?.openHouseholds() }
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
    themeRow.detail = QFThemeManager.shared.current.title(
      language: QFInterfaceLanguage.normalized(app.interfaceLanguage))
    languageRow.detail = QFInterfaceLanguage.normalized(preferences.interfaceLanguage).autonym
    planReminderRow.setOn(preferences.planReminders, animated: false)
    progressRow.setOn(preferences.workAndContributionUpdates, animated: false)
    renderAccountState()
  }

  private func renderAccountState() {
    logoutButton.isHidden = app.user == nil
  }

  private var pendingSettingsKey: String { "qf.settings.pending." + app.contentScope }
  private func replacePreferences(
    interfaceLanguage: String? = nil, planReminders: Bool? = nil,
    workAndContributionUpdates: Bool? = nil
  ) {
    let languageChanged = interfaceLanguage.map {
      QFInterfaceLanguage.normalized($0).rawValue != preferences.interfaceLanguage
    } ?? false
    let serverSettingsChanged = planReminders != nil || workAndContributionUpdates != nil
    let language = QFInterfaceLanguage.normalized(
      interfaceLanguage ?? preferences.interfaceLanguage).rawValue
    preferences = QFUserSettings(
      theme: QFThemeManager.shared.current.rawValue,
      interfaceLanguage: language,
      planReminders: planReminders ?? preferences.planReminders,
      workAndContributionUpdates: workAndContributionUpdates
        ?? preferences.workAndContributionUpdates)
    QFLocalSettingsStore.save(preferences, scope: app.contentScope)
    QFLocalSettingsStore.saveInterfaceLanguage(language)
    app.setInterfaceLanguage(language)
    if serverSettingsChanged {
      if app.user != nil { UserDefaults.standard.set(true, forKey: pendingSettingsKey) }
      scheduleServerSync(preferences)
    } else if languageChanged {
      // Interface language is deliberately device-local. Requests carry it through
      // Accept-Language; no user-settings request is made for a language change.
      render()
    }
  }
  private func scheduleServerSync(_ value: QFUserSettings) {
    syncTask?.cancel()
    guard app.user != nil else { return }
    let scope = app.contentScope
    let pendingKey = pendingSettingsKey
    syncTask = Task { [weak self, app] in
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled else { return }
      do {
        let saved = try await app.updateUserSettings(value)
        guard let self, !Task.isCancelled, app.contentScope == scope else { return }
        let local = self.keepingLocalPreferences(saved)
        QFLocalSettingsStore.save(local, scope: scope)
        UserDefaults.standard.removeObject(forKey: pendingKey)
        self.preferences = local
      } catch {
        // Keep the pending device value for the next explicit settings visit.
      }
    }
  }
  private func reconcileServerOnce() {
    guard !didReconcileServer, app.user != nil else { return }
    didReconcileServer = true
    if UserDefaults.standard.bool(forKey: pendingSettingsKey) {
      scheduleServerSync(preferences)
      return
    }
    let scope = app.contentScope
    syncTask = Task { [weak self, app] in
      do {
        let saved = try await app.loadUserSettings()
        guard let self, !Task.isCancelled, app.contentScope == scope else { return }
        let merged = self.keepingLocalPreferences(saved)
        QFLocalSettingsStore.save(merged, scope: scope)
        if self.preferences != merged {
          self.preferences = merged
          self.render()
        }
      } catch {
        // Cached settings remain usable while offline.
      }
    }
  }

  private func openThemeSettings() {
    guard presentedViewController == nil else { return }
    let controller = QFThemeSettingsViewController(app: app) { [weak self] in
      guard let self else { return }
      self.preferences = self.keepingLocalPreferences(self.preferences)
      self.render()
    }
    controller.modalPresentationStyle = .fullScreen
    qfPush(controller)
  }

  private func keepingLocalPreferences(_ settings: QFUserSettings) -> QFUserSettings {
    let local = QFLocalSettingsStore.current()
    return QFUserSettings(
      theme: QFThemeManager.shared.current.rawValue,
      interfaceLanguage: local.interfaceLanguage,
      planReminders: settings.planReminders,
      workAndContributionUpdates: settings.workAndContributionUpdates)
  }

  private func openLanguageSettings() {
    guard presentedViewController == nil else { return }
    let controller = QFLanguageSettingsViewController(
      app: app, selected: preferences.interfaceLanguage
    ) {
      [weak self] language in
      self?.replacePreferences(interfaceLanguage: language)
      self?.render()
    }
    controller.modalPresentationStyle = .fullScreen
    qfPush(controller)
  }

  private func openEditProfile() {
    guard presentedViewController == nil else { return }
    guard app.user != nil else {
      showMessage(
        title: app.text("需要登录", "Sign in required"),
        message: app.text("登录后可以使用编辑资料功能。", "Sign in to edit your profile."))
      return
    }
    let controller = QFPublicProfileEditorViewController(app: app)
    qfPush(controller)
  }

  private func openAccountPrivacy() {
    guard presentedViewController == nil else { return }
    guard let profile = app.user else {
      showMessage(
        title: app.text("需要登录", "Sign in required"),
        message: app.text("登录后可以使用账号与隐私功能。", "Sign in to manage your account and privacy."))
      return
    }
    let controller = QFAccountPrivacyViewController(app: app, initialProfile: profile) {
      [weak self] in
      guard let self else { return }
      self.showMessage(
        title: self.app.text("需要登录", "Sign in required"),
        message: self.app.text(
          "登录状态已失效，请重新登录。", "Your session expired. Please sign in again."))
    }
    qfPush(controller)
  }

  private func openReminderSettings() {
    guard presentedViewController == nil else { return }
    guard app.user != nil else {
      showMessage(
        title: app.text("需要登录", "Sign in required"),
        message: app.text("登录后可以设置计划提醒。", "Sign in to configure plan reminders."))
      return
    }
    qfPush(QFPlanReminderSettingsViewController(app: app))
  }

  private func openHouseholds() {
    guard presentedViewController == nil else { return }
    guard app.user != nil else {
      showMessage(
        title: app.text("需要登录", "Sign in required"),
        message: app.text("登录后可以管理家庭共享。", "Sign in to manage household sharing."))
      return
    }
    qfPush(QFHouseholdsViewController(app: app))
  }

  private func openHelp() {
    guard presentedViewController == nil else { return }
    qfPush(QFHelpFeedbackViewController(app: app))
  }

  private func openLegal(_ destination: QFSettingsLegalDestination) {
    guard presentedViewController == nil else { return }
    if destination == .imageRights, app.user != nil {
      qfPush(QFImageRightsViewController(app: app))
    } else {
      qfPush(
        QFLocalLegalViewController(
          document: destination.documentName, title: destination.title(app: app),
          language: app.interfaceLanguage))
    }
  }

  private func updateCacheSize() {
    cacheSizeTask?.cancel()
    cacheRow.detail = app.text("计算中", "Calculating")
    cacheSizeTask = Task { [weak self] in
      do {
        let remote = try await QFRemoteImagePipeline.cache.diskStorageSize
        let content = try await QFContentImageCache.shared.diskStorageSize
        guard let self, !Task.isCancelled else { return }
        self.diskCacheBytes = remote + content + UInt(URLCache.shared.currentDiskUsage + self.app.contentCache.persistentPayloadBytes)
        self.memoryCacheBytes = QFRemoteImagePipeline.cache.memoryStorageCacheCost
          + QFContentImageCache.shared.memoryStorageCacheCost + self.app.contentMediaCacheSize
          + URLCache.shared.currentMemoryUsage + self.app.contentCache.memoryPayloadBytes
        let total = Int64(self.diskCacheBytes) + Int64(self.memoryCacheBytes)
        self.cacheRow.detail = self.app.text("约 ", "About ")
          + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        self.cacheRow.accessibilityValue = self.cacheRow.detail
      } catch {
        guard let self, !Task.isCancelled else { return }
        self.cacheRow.detail = self.app.text("大小暂不可用", "Size unavailable")
      }
    }
  }
  private func confirmClearCache() {
    let alert = UIAlertController(
      title: app.text("清理缓存？", "Clear cache?"), message: app.text("图片与网络磁盘缓存 ", "Image and network disk cache: ")
        + ByteCountFormatter.string(fromByteCount: Int64(diskCacheBytes), countStyle: .file)
        + app.text("，内存缓存约 ", "; memory cache: about ")
        + ByteCountFormatter.string(fromByteCount: Int64(memoryCacheBytes), countStyle: .memory)
        + app.text("。保留账号资料、草稿和未提交图片视频。", ". Account data, drafts, and unsubmitted media are kept."),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    alert.addAction(
      UIAlertAction(title: app.text("清理", "Clear"), style: .destructive) { [weak self] _ in
        self?.clearCache()
      })
    present(alert, animated: true)
  }

  private func clearCache() {
    guard cacheTask == nil else { return }
    cacheSizeTask?.cancel()
    cacheRow.setLoading(true, accessibilityText: app.text("处理中", "In progress"))
    cacheTask = Task { [weak self] in
      self?.app.clearContentMediaCache()
      self?.app.contentCache.clearDisposableResponses()
      QFContentImageCache.shared.clearMemoryCache()
      QFRemoteImagePipeline.cache.clearMemoryCache()
      URLCache.shared.removeAllCachedResponses()
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        QFRemoteImagePipeline.cache.clearDiskCache { continuation.resume() }
      }
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        QFContentImageCache.shared.clearDiskCache { continuation.resume() }
      }
      guard let self, !Task.isCancelled else { return }
      self.cacheRow.setLoading(false)
      self.cacheTask = nil
      self.updateCacheSize()
      self.showMessage(
        title: self.app.text("已清理", "Cache cleared"),
        message: self.app.text("可重新获取的图片缓存已清理。", "Downloadable image cache has been cleared."))
    }
  }

  private func confirmLogout() {
    let alert = UIAlertController(
      title: app.text("退出当前账号？", "Sign out of this account?"), message: nil,
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: app.text("继续使用", "Stay signed in"), style: .cancel))
    alert.addAction(
      UIAlertAction(title: app.text("退出登录", "Sign out"), style: .destructive) { [weak self] _ in
        self?.logout()
      })
    present(alert, animated: true)
  }

  private func logout() {
    guard logoutTask == nil else { return }
    logoutButton.setLoading(true, accessibilityText: app.text("处理中", "In progress"))
    logoutTask = Task { [weak self, app] in
      defer {
        self?.logoutButton.setLoading(false)
        self?.logoutTask = nil
      }
      do {
        await QFGetuiPushService.shared.unregisterBeforeSignOut()
        try await app.logout()
        guard !Task.isCancelled else { return }
        self?.onClose()
      } catch is CancellationError {
        QFGetuiPushService.shared.signOutDidFail()
        return
      } catch {
        QFGetuiPushService.shared.signOutDidFail()
        self?.showMessage(
          title: app.text("退出失败", "Could not sign out"),
          message: QFProfileContentController.errorText(error, app: app))
      }
    }
  }

  private func showMessage(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: app.text("知道了", "OK"), style: .default))
    present(alert, animated: true)
  }
}

@MainActor
private final class QFAccountPrivacyViewController: UIViewController {
  private let app: QFAppSession
  private let initialProfile: QFUserProfile
  private let onSessionExpired: () -> Void
  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()
  private lazy var userIDRow = QFSettingsValueRow(title: app.text("用户编号", "User ID"), identifier: "account.userId")
  private lazy var boundAccountRow = QFSettingsActionRow(title: app.text("自定义账号", "Custom account"))
  private lazy var passwordRow = QFSettingsActionRow(title: app.text("登录密码", "Password"))
  private lazy var appleRow = QFSettingsActionRow(title: app.text("Apple 身份", "Apple ID"))
  private lazy var appleAuthorization = QFAppleAuthorization(app: app)
  private var appleBindingTask: Task<Void, Never>?
  private lazy var unavailableRow = QFSettingsValueRow(title: app.text("账号信息", "Account information"), identifier: "account.unavailable")
  private var accountDetailsSection: UIView?
  private var accountUnavailableSection: UIView?
  private var subscriptions = Set<AnyCancellable>()
  private var sessionExpired = false
  private var didCloseForExpiredSession = false

  init(app: QFAppSession, initialProfile: QFUserProfile, onSessionExpired: @escaping () -> Void) {
    self.app = app
    self.initialProfile = initialProfile
    self.onSessionExpired = onSessionExpired
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.accessibilityIdentifier = "account.screen"
    buildLayout()
    render(initialProfile)
    app.$user.receive(on: DispatchQueue.main).sink { [weak self] profile in
      self?.consume(profile)
    }.store(in: &subscriptions)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    closeForExpiredSessionIfPossible()
  }

  private func buildLayout() {
    let back = QFTabUI.iconButton("chevron.left", label: app.text("返回", "Back"), size: 22) { [weak self] in
      self?.qfClose()
    }
    back.snp.remakeConstraints { $0.size.equalTo(44) }
    back.tintColor = QFUI.text
    let title = QFAccountTypography.label(
      app.text("账号与隐私", "Account and privacy"), size: 23, weight: .semibold, textStyle: .title2)
    title.textAlignment = .center
    title.accessibilityTraits.insert(.header)
    let trailing = UIView()
    trailing.snp.makeConstraints { $0.width.height.equalTo(44) }
    let header = QFTabUI.stack([back, title, trailing], axis: .horizontal, spacing: 4)
    header.alignment = .center
    QFSettingsPageUI.installHeader(header, in: view)

    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = false
    view.addSubview(scrollView)
    scrollView.snp.makeConstraints {
      $0.top.equalTo(header.snp.bottom)
      $0.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
    }
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
    let accountDetailsSection = section(
      title: app.text("账号与登录安全", "Account and sign-in security"), rows: [userIDRow, boundAccountRow, passwordRow, appleRow])
    boundAccountRow.accessibilityIdentifier = "account.boundAccount"
    passwordRow.accessibilityIdentifier = "account.password"
    boundAccountRow.action = { [weak self] in
      guard let self, self.app.user?.accountNameBound == false else { return }
      self.qfPush(QFAccountEditorViewController(app: self.app, kind: .account))
    }
    passwordRow.action = { [weak self] in
      guard let self, self.app.user != nil else { return }
      self.qfPush(QFAccountEditorViewController(app: self.app, kind: .password))
    }
    appleRow.accessibilityIdentifier = "account.apple"
    appleRow.action = { [weak self] in self?.bindApple() }
    self.accountDetailsSection = accountDetailsSection
    contentStack.addArrangedSubview(accountDetailsSection)
    unavailableRow.value = app.text("暂时不可用", "Temporarily unavailable")
    let accountUnavailableSection = section(title: app.text("账号与登录安全", "Account and sign-in security"), rows: [unavailableRow])
    accountUnavailableSection.isHidden = true
    self.accountUnavailableSection = accountUnavailableSection
    contentStack.addArrangedSubview(accountUnavailableSection)

    let permissionsRow = QFSettingsActionRow(
      title: app.text("系统权限", "System permissions"),
      detail: app.text("前往系统设置", "Open Settings"))
    permissionsRow.accessibilityIdentifier = "account.systemPermissions"
    permissionsRow.action = {
      guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
      UIApplication.shared.open(url)
    }
    contentStack.addArrangedSubview(section(
      title: app.text("系统权限", "System permissions"), rows: [permissionsRow]))

    let deletionRow = QFSettingsActionRow(
      title: app.text("注销账号", "Delete account"),
      subtitle: app.text("永久删除个人记录", "Permanently delete personal records"),
      scalesForDynamicType: true)
    deletionRow.setDestructiveStyle()
    deletionRow.accessibilityIdentifier = "account.delete"
    deletionRow.action = { [weak self] in
      guard let self, self.app.user != nil else { return }
      self.qfPush(QFAccountDeletionViewController(app: self.app))
    }
    contentStack.addArrangedSubview(section(
      title: app.text("危险操作", "Danger zone"), rows: [deletionRow]))

  }

  private func section(title: String, rows: [UIView]) -> UIView {
    let heading = QFAccountTypography.label(
      title, size: 14, weight: .medium, color: QFUI.secondary, textStyle: .subheadline)
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

  private func consume(_ profile: QFUserProfile?) {
    guard let profile else {
      sessionExpired = true
      contentStack.isHidden = true
      view.accessibilityElementsHidden = true
      closeForExpiredSessionIfPossible()
      return
    }
    guard !sessionExpired else { return }
    render(profile)
  }

  private func render(_ profile: QFUserProfile) {
    guard isValidPublicUserID(profile.userId) else {
      userIDRow.value = nil; appleRow.detail = nil
      boundAccountRow.detail = nil; passwordRow.detail = nil
      accountDetailsSection?.isHidden = true
      accountUnavailableSection?.isHidden = false
      return
    }
    accountDetailsSection?.isHidden = false
    accountUnavailableSection?.isHidden = true
    userIDRow.value = profile.userId
    let account = profile.boundAccount?.trimmingCharacters(in: .whitespacesAndNewlines)
    switch (profile.accountNameBound, account?.isEmpty == false) {
    case (true, true): boundAccountRow.detail = account
    case (false, false): boundAccountRow.detail = app.text("去绑定", "Link account")
    default: boundAccountRow.detail = app.text("状态暂不可用", "Status unavailable")
    }
    boundAccountRow.isEnabled = !profile.accountNameBound
    passwordRow.detail = profile.passwordConfigured ? app.text("修改密码", "Change password") : app.text("设置密码", "Set password")
    appleRow.detail = profile.appleBound ? app.text("已绑定", "Linked") : app.text("去绑定", "Link account")
    appleRow.isEnabled = !profile.appleBound
  }

  private func bindApple() {
    guard appleBindingTask == nil, app.user?.appleBound == false else { return }
    appleRow.setLoading(true, accessibilityText: app.text("绑定中", "Linking"))
    appleBindingTask = Task { [weak self] in
      guard let self else { return }
      defer {
        appleBindingTask = nil
        appleRow.setLoading(false)
        appleRow.isEnabled = app.user?.appleBound == false
      }
      do {
        let code = try await appleAuthorization.authorize()
        try await app.bindApple(code, operationID: UUID())
      } catch is CancellationError {
        return
      } catch let error as ASAuthorizationError where error.code == .canceled {
        return
      } catch {
        let detail: String
        if let api = error as? QFAPIError {
          switch api.code {
          case 40903: detail = app.text("当前 Apple 身份与该账号归属冲突。", "This Apple ID belongs to a different account.")
          case 40302: detail = app.text("请退出并重新登录后再绑定 Apple 身份。", "Sign out and sign in again before linking your Apple ID.")
          case 40100: detail = app.text("Apple 授权已失效，请重新授权", "Apple authorization has expired. Please authorize again.")
          default: detail = app.text("暂时无法绑定 Apple 身份，请稍后重试。", "Could not link your Apple ID right now. Try again later.")
          }
        } else {
          detail = app.text("暂时无法绑定 Apple 身份，请稍后重试。", "Could not link your Apple ID right now. Try again later.")
        }
        let alert = UIAlertController(title: app.text("Apple 身份", "Apple ID"), message: detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: app.text("知道了", "OK"), style: .default))
        if view.window != nil { present(alert, animated: true) }
      }
    }
  }

  private func isValidPublicUserID(_ userID: String) -> Bool {
    userID.utf8.count == 9 && userID.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
  }

  private func closeForExpiredSessionIfPossible() {
    guard sessionExpired, !didCloseForExpiredSession, view.window != nil else { return }
    didCloseForExpiredSession = true
    qfClose(completion: onSessionExpired)
  }

  private func openLegal(_ destination: QFSettingsLegalDestination) {
    guard presentedViewController == nil else { return }
    if destination == .imageRights, app.user != nil {
      qfPush(QFImageRightsViewController(app: app))
    } else {
      qfPush(
        QFLocalLegalViewController(
          document: destination.documentName, title: destination.title(app: app),
          language: app.interfaceLanguage))
    }
  }
}

@MainActor
private enum QFAccountTypography {
  static func label(
    _ text: String, size: CGFloat, weight: UIFont.Weight = .regular,
    color: UIColor = QFUI.text, textStyle: UIFont.TextStyle
  ) -> UILabel {
    let label = QFTabUI.label(text, size: size, weight: weight, color: color, lines: 0)
    scale(label, size: size, weight: weight, textStyle: textStyle)
    return label
  }

  static func scale(
    _ label: UILabel, size: CGFloat, weight: UIFont.Weight, textStyle: UIFont.TextStyle
  ) {
    let baseFont = UIFont.systemFont(ofSize: size, weight: weight)
    label.font = UIFontMetrics(forTextStyle: textStyle).scaledFont(for: baseFont)
    label.adjustsFontForContentSizeCategory = true
    label.numberOfLines = 0
  }
}

@MainActor
private final class QFSettingsValueRow: UIView {
  private let valueLabel = QFAccountTypography.label(
    "", size: 16, weight: .medium, textStyle: .body)

  var value: String? {
    didSet {
      valueLabel.text = value
      accessibilityValue = value
    }
  }

  init(title: String, identifier: String) {
    super.init(frame: .zero)
    let titleLabel = QFAccountTypography.label(
      title, size: 13, color: QFUI.secondary, textStyle: .caption1)
    let stack = QFTabUI.stack([titleLabel, valueLabel], spacing: 4)
    addSubview(stack)
    stack.snp.makeConstraints {
      $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0))
    }
    snp.makeConstraints { $0.height.greaterThanOrEqualTo(58) }
    isAccessibilityElement = true
    accessibilityIdentifier = identifier
    accessibilityLabel = title
    accessibilityTraits = .staticText
  }

  required init?(coder: NSCoder) { nil }
}

private enum QFSettingsLegalDestination {
  var documentName: String {
    switch self {
    case .userAgreement: return "user-agreement"
    case .privacyPolicy: return "privacy-policy"
    case .imageLicense: return "image-license"
    case .imageRights: return "image-rights"
    }
  }
  case userAgreement
  case privacyPolicy
  case imageLicense
  case imageRights

  @MainActor
  func title(app: QFAppSession) -> String {
    switch self {
    case .userAgreement: return app.text("用户协议", "Terms of service")
    case .privacyPolicy: return app.text("隐私政策", "Privacy policy")
    case .imageLicense: return app.text("图片使用授权", "Image licence")
    case .imageRights: return app.text("图片侵权保护", "Image rights protection")
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

  init(
    title: String, detail: String? = nil, subtitle: String? = nil,
    scalesForDynamicType: Bool = false, action: (() -> Void)? = nil
  ) {
    titleLabel = QFTabUI.label(title, size: 16, weight: .medium, lines: 0)
    subtitleLabel = subtitle.map { QFTabUI.label($0, size: 11, color: QFUI.secondary, lines: 0) }
    self.action = action
    super.init(frame: .zero)
    if scalesForDynamicType {
      QFAccountTypography.scale(titleLabel, size: 16, weight: .medium, textStyle: .body)
      if let subtitleLabel {
        QFAccountTypography.scale(
          subtitleLabel, size: 11, weight: .regular, textStyle: .caption2)
      }
      QFAccountTypography.scale(detailLabel, size: 14, weight: .regular, textStyle: .subheadline)
    }
    accessibilityLabel = title
    accessibilityTraits = .button
    self.detail = detail
    detailLabel.text = detail
    detailLabel.isHidden = detail?.isEmpty != false
    let labels = QFTabUI.stack([titleLabel] + (subtitleLabel.map { [$0] } ?? []), spacing: 3)
    spinner.color = QFUI.primary
    spinner.hidesWhenStopped = true
    let row = QFTabUI.stack(
      [labels, UIView(), detailLabel, spinner, chevron], axis: .horizontal, spacing: 8)
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

  func setLoading(_ loading: Bool, accessibilityText: String? = nil) {
    isEnabled = !loading
    chevron.isHidden = loading
    if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
    accessibilityValue = loading ? accessibilityText : detail
  }

  func setDestructiveStyle() { titleLabel.textColor = QFUI.danger }
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
    toggle.addAction(
      UIAction { [weak self] _ in
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
  init(
    leftTitle: String, rightTitle: String, scalesForDynamicType: Bool = false,
    onLeft: @escaping () -> Void, onRight: @escaping () -> Void
  ) {
    super.init(frame: .zero)
    let left = QFSettingsActionRow(
      title: leftTitle, scalesForDynamicType: scalesForDynamicType, action: onLeft)
    let right = QFSettingsActionRow(
      title: rightTitle, scalesForDynamicType: scalesForDynamicType, action: onRight)
    let divider = UIView()
    divider.backgroundColor = QFUI.border
    divider.snp.makeConstraints {
      $0.width.equalTo(0.5)
      $0.height.equalTo(28)
    }
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
  private lazy var applyButton = QFAuthLoadingButton(
    app.text("应用主题", "Apply theme"), size: 18)
  private var selected = QFThemeManager.shared.current
  private var optionViews: [QFThemeKind: QFThemeOptionView] = [:]

  init(app: QFAppSession, onApplied: @escaping () -> Void) {
    self.app = app
    self.onApplied = onApplied
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.accessibilityIdentifier = "settings.theme.screen"
    buildLayout()
    renderSelection()
  }

  private func buildLayout() {
    let back = QFTabUI.iconButton(
      "chevron.left", label: app.text("返回", "Back"), size: 22
    ) { [weak self] in
      self?.qfClose()
    }
    back.snp.remakeConstraints { $0.size.equalTo(44) }
    back.tintColor = QFUI.text
    let title = QFTabUI.label(app.text("主题设置", "Appearance"), size: 23, weight: .semibold)
    title.textAlignment = .center
    title.accessibilityTraits.insert(.header)
    let trailing = UIView()
    trailing.snp.makeConstraints { $0.width.height.equalTo(44) }
    let header = QFTabUI.stack([back, title, trailing], axis: .horizontal, spacing: 4)
    header.alignment = .center
    QFSettingsPageUI.installHeader(header, in: view)

    let heading = QFTabUI.label(
      app.text("选择你喜欢的配色", "Choose a colour theme"), size: 24, weight: .bold,
      lines: 0)
    let subtitle = QFTabUI.label(
      app.text("应用到所有页面和操作控件", "Applied across pages and controls"), size: 15,
      color: QFUI.secondary, lines: 0)
    optionsStack.axis = .vertical
    optionsStack.spacing = 14
    for theme in QFThemeKind.allCases {
      let option = QFThemeOptionView(
        theme: theme, language: QFInterfaceLanguage.normalized(app.interfaceLanguage)
      ) { [weak self] in
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
      $0.top.equalTo(header.snp.bottom)
      $0.leading.trailing.equalTo(view.safeAreaLayoutGuide)
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
    contentStack.addArrangedSubview(heading)
    contentStack.addArrangedSubview(subtitle)
    contentStack.setCustomSpacing(20, after: subtitle)
    contentStack.addArrangedSubview(optionsStack)
  }

  private func renderSelection() {
    for (theme, option) in optionViews { option.setSelected(theme == selected) }
    applyButton.accessibilityValue =
      selected == QFThemeManager.shared.current
      ? app.text("当前主题", "Current theme")
      : app.text("待应用", "Apply ")
        + selected.title(language: QFInterfaceLanguage.normalized(app.interfaceLanguage))
  }

  private func applySelection() {
    let current = QFLocalSettingsStore.current()
    let next = QFUserSettings(
      theme: selected.rawValue, interfaceLanguage: current.interfaceLanguage,
      planReminders: current.planReminders,
      workAndContributionUpdates: current.workAndContributionUpdates)
    finishApply(next)
  }

  private func finishApply(_ settings: QFUserSettings) {
    guard let theme = QFThemeKind(rawValue: settings.theme) else { return }
    QFLocalSettingsStore.save(settings)
    qfClose(animated: false) { [onApplied] in
      QFThemeManager.shared.apply(theme)
      onApplied()
    }
  }
}

@MainActor
private final class QFThemeOptionView: UIControl {
  private let theme: QFThemeKind
  private let check = UIImageView()

  init(
    theme: QFThemeKind, language: QFInterfaceLanguage, action: @escaping () -> Void
  ) {
    self.theme = theme
    super.init(frame: .zero)
    backgroundColor = theme.previewSurface
    layer.cornerRadius = 20
    layer.borderWidth = 1
    layer.borderColor = theme.previewBorder.cgColor
    accessibilityLabel = theme.title(language: language)
    accessibilityHint = theme.subtitle(language: language)
    accessibilityTraits = .button

    let sample = UIView()
    sample.backgroundColor = theme.previewBackground
    sample.layer.cornerRadius = 14
    sample.snp.makeConstraints {
      $0.width.equalTo(104)
      $0.height.equalTo(96)
    }
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
    for element in [lineOne, lineTwo, field, sampleButton] { sample.addSubview(element) }
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
    check.layer.cornerRadius = 0
    check.clipsToBounds = true
    check.snp.makeConstraints { $0.size.equalTo(24) }
    check.setContentCompressionResistancePriority(.required, for: .horizontal)
    check.setContentHuggingPriority(.required, for: .horizontal)
    let title = QFTabUI.label(
      theme.title(language: language), size: 22, weight: .bold, color: theme.previewText)
    let subtitle = QFTabUI.label(
      theme.subtitle(language: language), size: 14,
      color: theme.previewText.withAlphaComponent(0.72))
    let colors = QFTabUI.stack(
      theme.previewColors.map { color -> UIView in
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
    check.backgroundColor = .clear
    check.tintColor = selected ? theme.previewPrimary : theme.previewBorder
    check.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
  }
}

@MainActor
private final class QFPlanReminderSettingsViewController: QFProfileContentController {
  private struct MealState: Equatable {
    let meal: String
    var enabled: Bool
    var localTime: String
    var advanceMinutes: Int
  }

  private struct Draft: Equatable {
    var timezone: String
    var enabled: Bool
    var meals: [MealState]
  }

  private var saved: QFReminderSettings?
  private let householdID: String?
  private var original: Draft?
  private var draft = Draft(
    timezone: TimeZone.current.identifier, enabled: false,
    meals: QFMealReminder.defaults.map {
      MealState(meal: $0.meal, enabled: $0.enabled, localTime: $0.localTime, advanceMinutes: $0.advanceMinutes)
    })
  private weak var timezoneButton: UIButton?

  init(app: QFAppSession) {
    householdID = app.planningHouseholdID
    let scopeName = app.planningScope.householdName ?? app.text("个人", "Personal")
    super.init(
      app: app,
      title: "\(app.text("提醒时间与时区", "Reminder times and timezone")) · \(scopeName)")
  }

  required init?(coder: NSCoder) { nil }
  override var reloadsOnAppearance: Bool { false }
  override var hasUnsavedChanges: Bool { original.map { $0 != draft } ?? false }

  override func viewDidLoad() {
    super.viewDidLoad()
    setReloadAction { [weak self] in self?.load() }
    _ = addFooter(app.text("保存提醒设置", "Save reminder settings")) { [weak self] in
      self?.save()
    }
    load()
  }

  override func close() {
    guard hasUnsavedChanges else {
      super.close()
      return
    }
    confirm(
      app.text("放弃未保存的提醒设置？", "Discard unsaved reminder settings?"),
      detail: app.text("返回后本次修改不会生效。", "These changes will not take effect."),
      actionTitle: app.text("放弃修改", "Discard changes"), destructive: true
    ) { [weak self] in self?.qfClose() }
  }

  private func load() {
    execute(reloadOnFailure: true, showReadProgress: saved == nil) { [self] in
      let value = try await app.reminderSettings(householdID: householdID)
      try Task.checkCancellation()
      saved = value
      let defaults = Dictionary(uniqueKeysWithValues: draft.meals.map { ($0.meal, $0) })
      let received = Dictionary(uniqueKeysWithValues: value.meals.map { ($0.meal, $0) })
      let meals = ["BREAKFAST", "LUNCH", "DINNER", "SNACK"].compactMap { meal -> MealState? in
        if let current = received[meal] {
          return MealState(
            meal: meal, enabled: current.enabled, localTime: current.localTime,
            advanceMinutes: current.advanceMinutes)
        }
        return defaults[meal]
      }
      draft = Draft(
        timezone: value.timezone ?? TimeZone.current.identifier,
        enabled: value.id == nil ? false : value.enabled, meals: meals)
      original = draft
      render()
    }
  }

  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row("master", version: "\(draft.enabled)|\(app.interfaceLanguage)") { [weak self] in
      guard let self else { return UIView() }
      let toggle = UISwitch()
      toggle.isOn = self.draft.enabled
      toggle.addAction(UIAction { [weak self, weak toggle] _ in
        self?.draft.enabled = toggle?.isOn == true
      }, for: .valueChanged)
      let labels = QFTabUI.stack(
        [
          QFTabUI.label(self.app.text("启用餐次提醒", "Enable meal reminders"), size: 17, weight: .semibold),
          QFTabUI.label(
            self.app.text("仅在已有计划时发送", "Sent only when a meal is planned"),
            size: 12, color: QFUI.secondary, lines: 0),
        ], spacing: 5)
      let row = QFTabUI.stack([labels, UIView(), toggle], axis: .horizontal, spacing: 12)
      row.alignment = .center
      return QFTabUI.card(row, padding: 14, border: true)
    }
    bodyStack.row("timezone", version: draft.timezone + app.interfaceLanguage) { [weak self] in
      guard let self else { return UIView() }
      let button = QFTabUI.button(
        self.draft.timezone, size: 14, weight: .medium, color: QFUI.primary,
        background: QFUI.surface
      ) { [weak self] in self?.chooseTimezone() }
      button.contentHorizontalAlignment = .right
      button.titleLabel?.numberOfLines = 2
      button.snp.makeConstraints {
        $0.height.greaterThanOrEqualTo(44)
        $0.width.lessThanOrEqualTo(220)
      }
      self.timezoneButton = button
      let row = QFTabUI.stack(
        [QFTabUI.label(self.app.text("时区", "Timezone"), size: 16), UIView(), button],
        axis: .horizontal, spacing: 10)
      row.alignment = .center
      return QFTabUI.card(row, padding: 10, border: true)
    }
    for index in draft.meals.indices {
      let state = draft.meals[index]
      bodyStack.row(
        "meal.\(state.meal)",
        version: "\(state.enabled)|\(state.localTime)|\(state.advanceMinutes)|\(app.interfaceLanguage)"
      ) { [weak self] in
        self?.mealRow(index: index) ?? UIView()
      }
    }
    bodyStack.endUpdates()
  }

  private func mealRow(index: Int) -> UIView {
    let state = draft.meals[index]
    let toggle = UISwitch()
    toggle.isOn = state.enabled
    let picker = UIDatePicker()
    picker.datePickerMode = .time
    picker.preferredDatePickerStyle = .compact
    picker.locale = Locale(
      identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    picker.timeZone = TimeZone(secondsFromGMT: 0)
    picker.date = Self.timeFormatter.date(from: state.localTime) ?? Date()
    picker.isEnabled = state.enabled
    let advance = UISegmentedControl(items: [
      app.text("准时", "On time"), app.text("提前15分", "15 min early"),
      app.text("提前30分", "30 min early"), app.text("提前1小时", "1 hour early"),
    ])
    advance.selectedSegmentIndex = [0, 15, 30, 60].firstIndex(of: state.advanceMinutes) ?? 0
    advance.selectedSegmentTintColor = QFUI.surface
    advance.backgroundColor = QFUI.paleGreen
    advance.isEnabled = state.enabled
    advance.snp.makeConstraints { $0.height.equalTo(36) }
    toggle.addAction(UIAction { [weak self, weak toggle, weak picker, weak advance] _ in
      guard let self, self.draft.meals.indices.contains(index) else { return }
      let enabled = toggle?.isOn == true
      self.draft.meals[index].enabled = enabled
      picker?.isEnabled = enabled
      advance?.isEnabled = enabled
    }, for: .valueChanged)
    picker.addAction(UIAction { [weak self, weak picker] _ in
      guard let self, let date = picker?.date, self.draft.meals.indices.contains(index) else { return }
      self.draft.meals[index].localTime = Self.timeFormatter.string(from: date)
    }, for: .valueChanged)
    advance.addAction(UIAction { [weak self, weak advance] _ in
      guard let self, self.draft.meals.indices.contains(index) else { return }
      let values = [0, 15, 30, 60]
      self.draft.meals[index].advanceMinutes = values[min(max(advance?.selectedSegmentIndex ?? 0, 0), 3)]
    }, for: .valueChanged)
    let heading = QFTabUI.stack(
      [QFTabUI.label(mealTitle(state.meal), size: 17, weight: .semibold), UIView(), picker, toggle],
      axis: .horizontal, spacing: 10)
    heading.alignment = .center
    return QFTabUI.card(QFTabUI.stack([heading, advance], spacing: 12), padding: 14, border: true)
  }

  private func chooseTimezone() {
    open(QFTimeZonePickerViewController(app: app, selected: draft.timezone) { [weak self] value in
      guard let self else { return }
      self.draft.timezone = value
      self.timezoneButton?.setTitle(value, for: .normal)
    })
  }

  private func save() {
    guard TimeZone(identifier: draft.timezone) != nil else {
      message(app.text("请选择有效时区。", "Choose a valid timezone."), error: true)
      return
    }
    let requested = draft
    execute(label: app.text("正在保存", "Saving")) { [self] in
      let value = try await app.saveReminderSettings(
        QFReminderSettingsDraft(
          householdId: householdID, timezone: requested.timezone, enabled: requested.enabled,
          expectedRevision: saved?.revision,
          meals: requested.meals.map {
            QFMealReminderDraft(
              meal: $0.meal, enabled: $0.enabled, localTime: $0.localTime,
              advanceMinutes: $0.advanceMinutes)
          }))
      try Task.checkCancellation()
      saved = value
      original = requested
      _ = try? await app.loadUserSettings()
      onChanged?()
      closeWithSuccess(app.text("提醒设置已保存", "Reminder settings saved"))
    }
  }

  private func mealTitle(_ meal: String) -> String {
    switch meal {
    case "BREAKFAST": return app.text("早餐", "Breakfast")
    case "LUNCH": return app.text("午餐", "Lunch")
    case "DINNER": return app.text("晚餐", "Dinner")
    case "SNACK": return app.text("加餐", "Snack")
    default: return meal
    }
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "HH:mm"
    return formatter
  }()
}

@MainActor
private final class QFTimeZonePickerViewController: QFProfileContentController,
  UITableViewDelegate, UISearchBarDelegate
{
  private let selection: (String) -> Void
  private var selected: String
  private var filtered: [String] = []
  private let zones = TimeZone.knownTimeZoneIdentifiers.sorted()
  private let searchBar = UISearchBar()
  private let table = UITableView(frame: .zero, style: .plain)
  private var dataSource: UITableViewDiffableDataSource<Int, String>!

  init(app: QFAppSession, selected: String, selection: @escaping (String) -> Void) {
    self.selected = selected
    self.selection = selection
    super.init(app: app, title: app.text("选择时区", "Choose timezone"))
  }

  required init?(coder: NSCoder) { nil }
  override var reloadsOnAppearance: Bool { false }

  override func viewDidLoad() {
    super.viewDidLoad()
    searchBar.searchBarStyle = .minimal
    searchBar.placeholder = app.text("搜索城市或时区", "Search city or timezone")
    searchBar.delegate = self
    table.backgroundColor = QFUI.background
    table.separatorColor = QFUI.border
    table.rowHeight = 58
    table.delegate = self
    table.register(UITableViewCell.self, forCellReuseIdentifier: "timezone")
    installList(table, controls: searchBar)
    dataSource = UITableViewDiffableDataSource<Int, String>(tableView: table) {
      [weak self] table, indexPath, identifier in
      guard let self else { return nil }
      let cell = table.dequeueReusableCell(withIdentifier: "timezone", for: indexPath)
      var content = cell.defaultContentConfiguration()
      content.text = identifier.replacingOccurrences(of: "_", with: " ")
      content.secondaryText = self.offsetText(identifier)
      content.textProperties.color = QFUI.text
      content.secondaryTextProperties.color = QFUI.secondary
      cell.contentConfiguration = content
      cell.backgroundColor = QFUI.background
      cell.accessoryType = identifier == self.selected ? .checkmark : .none
      return cell
    }
    applyFilter("")
  }

  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    applyFilter(searchText)
  }

  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard let value = dataSource.itemIdentifier(for: indexPath) else { return }
    selected = value
    selection(value)
    qfClose()
  }

  private func applyFilter(_ query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    filtered = trimmed.isEmpty
      ? zones
      : zones.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
    snapshot.appendSections([0])
    snapshot.appendItems(filtered)
    dataSource.apply(snapshot, animatingDifferences: false)
  }

  private func offsetText(_ identifier: String) -> String? {
    guard let zone = TimeZone(identifier: identifier) else { return nil }
    let seconds = zone.secondsFromGMT()
    let sign = seconds < 0 ? "−" : "+"
    let absolute = abs(seconds)
    return String(format: "UTC%@%02d:%02d", sign, absolute / 3600, absolute % 3600 / 60)
  }
}

@MainActor
private final class QFHouseholdsViewController: QFProfileContentController {
  private var households: [QFHousehold] = []
  private var loaded = false

  init(app: QFAppSession) {
    super.init(app: app, title: app.text("家庭与共享", "Household and sharing"))
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    setReloadAction { [weak self] in self?.load() }
    _ = addFooter(app.text("创建家庭", "Create household")) { [weak self] in
      self?.createHousehold()
    }
    _ = addFooter(app.text("加入家庭", "Join household"), primary: false) { [weak self] in
      self?.joinHousehold()
    }
    load()
  }

  private func load() {
    execute(reloadOnFailure: true, showReadProgress: !loaded) { [self] in
      let value = try await app.households()
      try Task.checkCancellation()
      households = value
      app.reconcilePlanningScope(availableHouseholds: value.map { ($0.id, $0.name) })
      loaded = true
      render()
    }
  }

  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row(
      "planning-scope",
      version: "\(app.planningScope.householdId ?? "personal")|\(app.planningScope.householdName ?? "")|\(app.interfaceLanguage)"
    ) { [weak self] in
      self?.planningScopeCard() ?? UIView()
    }
    if households.isEmpty {
      bodyStack.row("empty", version: app.interfaceLanguage) { [app] in
        QFTabUI.empty(
          app.text("还没有家庭", "No household yet"),
          detail: app.text(
            "创建家庭或使用邀请口令加入", "Create a household or join with an invitation token."))
      }
    }
    for household in households {
      let version = [
        household.name, household.timezone, household.role, String(household.memberCount),
        String(household.revision), app.interfaceLanguage,
      ].joined(separator: "|")
      bodyStack.row("household.\(household.id)", version: version) { [weak self] in
        self?.householdCard(household) ?? UIView()
      }
    }
    bodyStack.endUpdates()
  }

  private func planningScopeCard() -> UIView {
    let selected = app.planningScope.householdName ?? app.text("个人", "Personal")
    let button = UIButton(type: .system)
    button.backgroundColor = QFUI.paleGreen
    button.layer.cornerRadius = 17
    let labels = QFTabUI.stack(
      [
        QFTabUI.label(app.text("计划使用范围", "Planning scope"), size: 13, color: QFUI.secondary),
        QFTabUI.label(selected, size: 18, weight: .semibold, lines: 2),
      ], spacing: 5)
    let row = QFTabUI.stack(
      [labels, UIView(), QFTabUI.symbol("chevron.up.chevron.down", size: 15, color: QFUI.secondary)],
      axis: .horizontal, spacing: 10)
    row.alignment = .center
    row.isUserInteractionEnabled = false
    button.addSubview(row)
    row.snp.makeConstraints { $0.edges.equalToSuperview().inset(14) }
    button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(76) }
    button.accessibilityLabel = app.text("计划使用范围", "Planning scope")
    button.accessibilityValue = selected
    button.addAction(UIAction { [weak self, weak button] _ in
      guard let self, let button else { return }
      self.choosePlanningScope(source: button)
    }, for: .touchUpInside)
    return button
  }

  private func choosePlanningScope(source: UIView) {
    let sheet = UIAlertController(
      title: app.text("计划使用范围", "Planning scope"),
      message: app.text(
        "计划、库存、采购单、提醒和 AI 周计划会使用同一范围。",
        "Plans, inventory, shopping lists, reminders, and AI weekly plans use the same scope."),
      preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: app.text("个人", "Personal"), style: .default) {
      [weak self] _ in self?.selectPlanningScope(id: nil, name: nil)
    })
    for household in households {
      sheet.addAction(UIAlertAction(title: household.name, style: .default) { [weak self] _ in
        self?.selectPlanningScope(id: household.id, name: household.name)
      })
    }
    sheet.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    sheet.popoverPresentationController?.sourceView = source
    sheet.popoverPresentationController?.sourceRect = source.bounds
    open(sheet)
  }

  private func selectPlanningScope(id: String?, name: String?) {
    app.setPlanningScope(householdID: id, householdName: name)
    render()
    message(app.text("计划范围已更新", "Planning scope updated"))
  }

  private func householdCard(_ household: QFHousehold) -> UIView {
    let button = UIButton(type: .system)
    button.backgroundColor = QFUI.surface
    button.layer.cornerRadius = 17
    button.layer.borderWidth = 1
    button.layer.borderColor = QFUI.border.cgColor
    button.accessibilityLabel = household.name
    button.accessibilityValue = app.format(
      "%@，%d 位成员", "%@, %d members", roleTitle(household.role), household.memberCount)
    button.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      let controller = QFHouseholdDetailViewController(app: self.app, household: household)
      controller.onChanged = { [weak self] in self?.load() }
      self.open(controller)
    }, for: .touchUpInside)
    let labels = QFTabUI.stack(
      [
        QFTabUI.label(household.name, size: 18, weight: .semibold, lines: 2),
        QFTabUI.label(
          app.format(
            "%@ · %d 位成员", "%@ · %d members", roleTitle(household.role),
            household.memberCount), size: 12, color: QFUI.secondary, lines: 0),
        QFTabUI.label(household.timezone, size: 12, color: QFUI.secondary, lines: 0),
      ], spacing: 5)
    let row = QFTabUI.stack(
      [labels, UIView(), QFTabUI.symbol("chevron.right", size: 15, color: QFUI.secondary)],
      axis: .horizontal, spacing: 10)
    row.alignment = .center
    row.isUserInteractionEnabled = false
    button.addSubview(row)
    row.snp.makeConstraints { $0.edges.equalToSuperview().inset(14) }
    button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(84) }
    return button
  }

  private func createHousehold() {
    let controller = QFHouseholdEditorViewController(app: app, household: nil) { [weak self] saved in
      guard let self else { return }
      self.households.removeAll { $0.id == saved.id }
      self.households.insert(saved, at: 0)
      self.render()
      self.onChanged?()
    }
    open(controller)
  }

  private func joinHousehold() {
    let alert = UIAlertController(
      title: app.text("加入家庭", "Join household"),
      message: app.text("输入邀请人提供的口令", "Enter the invitation token you received."),
      preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = self.app.text("邀请口令", "Invitation token")
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
      field.clearButtonMode = .whileEditing
    }
    alert.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: app.text("加入", "Join"), style: .default) { [weak self, weak alert] _ in
      guard let self else { return }
      let token = (alert?.textFields?.first?.text ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard token.count >= 32 else {
        self.message(self.app.text("邀请口令不完整。", "The invitation token is incomplete."), error: true)
        return
      }
      self.execute(label: self.app.text("正在加入", "Joining")) { [self] in
        let joined = try await self.app.acceptHouseholdInvitation(token)
        try Task.checkCancellation()
        self.households.removeAll { $0.id == joined.id }
        self.households.insert(joined, at: 0)
        self.render()
        self.onChanged?()
        self.message(self.app.text("已加入家庭", "Household joined"))
      }
    })
    open(alert)
  }

  private func roleTitle(_ role: String) -> String {
    switch role {
    case "OWNER": return app.text("所有者", "Owner")
    case "ADMIN": return app.text("管理员", "Admin")
    case "EDITOR": return app.text("可编辑", "Editor")
    case "VIEWER": return app.text("仅查看", "Viewer")
    default: return role
    }
  }
}

@MainActor
private final class QFHouseholdEditorViewController: QFProfileContentController {
  private struct Draft: Equatable {
    var name: String
    var timezone: String
  }

  private let household: QFHousehold?
  private let onSaved: (QFHousehold) -> Void
  private let onDissolved: (() -> Void)?
  private let householdID: String
  private var original: Draft
  private var draft: Draft
  private weak var timezoneButton: UIButton?

  init(
    app: QFAppSession, household: QFHousehold?, onDissolved: (() -> Void)? = nil,
    onSaved: @escaping (QFHousehold) -> Void
  ) {
    self.household = household
    self.onSaved = onSaved
    self.onDissolved = onDissolved
    householdID = household?.id ?? UUID().uuidString.lowercased()
    let value = Draft(
      name: household?.name ?? "", timezone: household?.timezone ?? TimeZone.current.identifier)
    original = value
    draft = value
    super.init(
      app: app,
      title: household == nil
        ? app.text("创建家庭", "Create household") : app.text("家庭设置", "Household settings"))
  }

  required init?(coder: NSCoder) { nil }
  override var reloadsOnAppearance: Bool { false }
  override var hasUnsavedChanges: Bool { draft != original }

  override func viewDidLoad() {
    super.viewDidLoad()
    buildForm()
    _ = addFooter(
      household == nil ? app.text("创建", "Create") : app.text("保存", "Save")
    ) { [weak self] in self?.save() }
  }

  override func close() {
    guard hasUnsavedChanges else {
      super.close()
      return
    }
    confirm(
      app.text("放弃未保存的修改？", "Discard unsaved changes?"),
      detail: app.text("返回后本次修改不会生效。", "These changes will not take effect."),
      actionTitle: app.text("放弃修改", "Discard changes"), destructive: true
    ) { [weak self] in self?.qfClose() }
  }

  private func buildForm() {
    bodyStack.addArrangedSubview(
      QFTabUI.stack(
        [
          QFTabUI.label(app.text("家庭名称", "Household name"), size: 13, color: QFUI.secondary),
          QFContentUI.field(
            app.text("例如：我们的家", "For example: Our home"), text: draft.name, limit: 64
          ) { [weak self] in self?.draft.name = $0 },
        ], spacing: 7))
    let timezone = QFTabUI.button(
      draft.timezone, size: 14, weight: .medium, color: QFUI.primary,
      background: QFUI.surface
    ) { [weak self] in self?.chooseTimezone() }
    timezone.contentHorizontalAlignment = .right
    timezone.titleLabel?.numberOfLines = 2
    timezone.snp.makeConstraints {
      $0.height.greaterThanOrEqualTo(48)
      $0.width.lessThanOrEqualTo(220)
    }
    timezoneButton = timezone
    let timezoneRow = QFTabUI.stack(
      [QFTabUI.label(app.text("时区", "Timezone"), size: 16), UIView(), timezone],
      axis: .horizontal, spacing: 10)
    timezoneRow.alignment = .center
    bodyStack.addArrangedSubview(QFTabUI.card(timezoneRow, padding: 10, border: true))
    if household?.role == "OWNER" {
      bodyStack.addArrangedSubview(
        QFContentUI.action(app.text("解散家庭", "Dissolve household"), destructive: true) {
          [weak self] in self?.confirmDissolve()
        })
    }
  }

  private func chooseTimezone() {
    open(QFTimeZonePickerViewController(app: app, selected: draft.timezone) { [weak self] value in
      self?.draft.timezone = value
      self?.timezoneButton?.setTitle(value, for: .normal)
    })
  }

  private func save() {
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      message(app.text("请输入家庭名称。", "Enter a household name."), error: true)
      return
    }
    guard TimeZone(identifier: draft.timezone) != nil else {
      message(app.text("请选择有效时区。", "Choose a valid timezone."), error: true)
      return
    }
    execute(label: app.text("正在保存", "Saving")) { [self] in
      let value = try await app.saveHousehold(
        householdID,
        draft: QFHouseholdDraft(
          name: name, timezone: draft.timezone, expectedRevision: household?.revision))
      try Task.checkCancellation()
      original = Draft(name: value.name, timezone: value.timezone)
      draft = original
      onSaved(value)
      onChanged?()
      closeWithSuccess(
        household == nil ? app.text("家庭已创建", "Household created") : app.text("家庭设置已保存", "Household settings saved"))
    }
  }

  private func confirmDissolve() {
    guard let household else { return }
    confirm(
      app.text("解散这个家庭？", "Dissolve this household?"),
      detail: app.text(
        "成员将无法继续访问共享计划、采购单和库存。",
        "Members will lose access to shared plans, shopping lists, and inventory."),
      actionTitle: app.text("解散家庭", "Dissolve household"), destructive: true
    ) { [weak self] in self?.dissolve(household) }
  }

  private func dissolve(_ household: QFHousehold) {
    execute(label: app.text("正在解散家庭", "Dissolving household")) { [self] in
      try await app.dissolveHousehold(household.id, expectedRevision: household.revision)
      try Task.checkCancellation()
      onChanged?()
      qfClose { [onDissolved] in onDissolved?() }
    }
  }
}

@MainActor
private final class QFHouseholdDetailViewController: QFProfileContentController {
  private var household: QFHousehold
  private var members: [QFHouseholdMember] = []
  private var total = 0
  private var nextPage = 0
  private var hasMore = false
  private var loaded = false

  init(app: QFAppSession, household: QFHousehold) {
    self.household = household
    super.init(app: app, title: household.name)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    setReloadAction { [weak self] in self?.load(reset: true) }
    if canManage {
      _ = addFooter(app.text("家庭设置", "Household settings"), primary: false) { [weak self] in
        self?.editHousehold()
      }
      _ = addFooter(app.text("邀请成员", "Invite member")) { [weak self] in
        self?.chooseInvitationRole()
      }
    }
    load(reset: true)
  }

  private var canManage: Bool { household.role == "OWNER" || household.role == "ADMIN" }

  private func load(reset: Bool) {
    let page = reset ? 0 : nextPage
    execute(reloadOnFailure: true, loadingMore: !reset, showReadProgress: !loaded) { [self] in
      let memberPage: QFHouseholdMemberPage
      if reset {
        async let householdRequest = app.household(household.id)
        async let memberRequest = app.householdMembers(household.id, page: 0)
        let values = try await (householdRequest, memberRequest)
        household = values.0
        memberPage = values.1
        members = memberPage.items
      } else {
        memberPage = try await app.householdMembers(household.id, page: page)
        var positions = Dictionary(
          uniqueKeysWithValues: members.enumerated().map { ($0.element.publicUserId, $0.offset) })
        for member in memberPage.items {
          if let index = positions[member.publicUserId] { members[index] = member }
          else {
            positions[member.publicUserId] = members.count
            members.append(member)
          }
        }
      }
      try Task.checkCancellation()
      total = memberPage.total
      nextPage = page + 1
      hasMore = !memberPage.items.isEmpty && members.count < memberPage.total
      loaded = true
      updateHeading(household.name)
      render()
    }
  }

  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row(
      "summary",
      version: "\(household.name)|\(household.timezone)|\(household.role)|\(total)|\(household.revision)|\(app.interfaceLanguage)"
    ) { [weak self] in
      guard let self else { return UIView() }
      return QFTabUI.card(
        QFTabUI.stack(
          [
            QFTabUI.label(
              self.app.format("%d 位成员", "%d members", self.total), size: 20,
              weight: .semibold),
            QFTabUI.label(self.household.timezone, size: 12, color: QFUI.secondary),
            QFTabUI.label(
              self.roleTitle(self.household.role), size: 12, color: QFUI.green),
          ], spacing: 5), padding: 14, background: QFUI.paleGreen)
    }
    for member in members {
      let version = [
        member.nickname, member.avatarMediaId ?? "", member.role, member.joinedAt,
        household.role, String(household.revision), app.interfaceLanguage,
      ].joined(separator: "|")
      bodyStack.row("member.\(member.publicUserId)", version: version) { [weak self] in
        self?.memberCard(member) ?? UIView()
      }
    }
    bodyStack.endUpdates()
    setLoadMoreAction(hasMore ? { [weak self] in self?.load(reset: false) } : nil)
  }

  private func memberCard(_ member: QFHouseholdMember) -> UIView {
    let avatar = QFContentImageView()
    avatar.load(member.avatarMediaId, app: app)
    avatar.backgroundColor = QFUI.paleGreen
    avatar.layer.cornerRadius = 22
    avatar.clipsToBounds = true
    avatar.snp.makeConstraints { $0.size.equalTo(44) }
    let name = member.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? member.publicUserId : member.nickname
    let labels = QFTabUI.stack(
      [
        QFTabUI.label(name, size: 16, weight: .semibold, lines: 2),
        QFTabUI.label(roleTitle(member.role), size: 12, color: QFUI.secondary),
      ], spacing: 4)
    let button = UIButton(type: .system)
    button.backgroundColor = QFUI.surface
    button.layer.cornerRadius = 16
    button.layer.borderWidth = 1
    button.layer.borderColor = QFUI.border.cgColor
    let affordance = QFTabUI.symbol("ellipsis", size: 17, color: QFUI.secondary)
    let row = QFTabUI.stack([avatar, labels, UIView(), affordance], axis: .horizontal, spacing: 10)
    row.alignment = .center
    row.isUserInteractionEnabled = false
    button.addSubview(row)
    row.snp.makeConstraints { $0.edges.equalToSuperview().inset(12) }
    button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(68) }
    button.accessibilityLabel = name
    button.accessibilityValue = roleTitle(member.role)
    button.addAction(UIAction { [weak self] _ in self?.showMemberActions(member, source: button) }, for: .touchUpInside)
    return button
  }

  private func showMemberActions(_ member: QFHouseholdMember, source: UIView) {
    let isSelf = member.publicUserId == app.user?.userId
    let actorOwner = household.role == "OWNER"
    let targetOwner = member.role == "OWNER"
    let canEditTarget = canManage && !targetOwner && !isSelf
    guard canEditTarget || (isSelf && !targetOwner) else { return }
    let sheet = UIAlertController(title: member.nickname, message: member.publicUserId, preferredStyle: .actionSheet)
    if canEditTarget {
      for role in ["ADMIN", "EDITOR", "VIEWER"] where role != member.role {
        sheet.addAction(UIAlertAction(title: roleTitle(role), style: .default) { [weak self] _ in
          self?.changeRole(member, role: role)
        })
      }
      if actorOwner {
        sheet.addAction(UIAlertAction(title: app.text("转让所有权", "Transfer ownership"), style: .destructive) {
          [weak self] _ in self?.confirmTransfer(member)
        })
      }
      sheet.addAction(UIAlertAction(title: app.text("移出家庭", "Remove from household"), style: .destructive) {
        [weak self] _ in self?.confirmRemove(member, leaving: false)
      })
    } else if isSelf {
      sheet.addAction(UIAlertAction(title: app.text("退出家庭", "Leave household"), style: .destructive) {
        [weak self] _ in self?.confirmRemove(member, leaving: true)
      })
    }
    sheet.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    sheet.popoverPresentationController?.sourceView = source
    sheet.popoverPresentationController?.sourceRect = source.bounds
    open(sheet)
  }

  private func changeRole(_ member: QFHouseholdMember, role: String) {
    execute(label: app.text("正在更新成员", "Updating member")) { [self] in
      _ = try await app.changeHouseholdMemberRole(
        householdID: household.id, publicUserID: member.publicUserId,
        draft: QFHouseholdMemberRoleDraft(role: role, expectedRevision: household.revision))
      try await refreshAfterMutation()
    }
  }

  private func confirmRemove(_ member: QFHouseholdMember, leaving: Bool) {
    confirm(
      leaving ? app.text("退出这个家庭？", "Leave this household?") : app.text("移出这位成员？", "Remove this member?"),
      detail: app.text("共享计划与库存将不再对该成员可见。", "Shared plans and inventory will no longer be available to this member."),
      actionTitle: leaving ? app.text("退出家庭", "Leave household") : app.text("移出", "Remove"),
      destructive: true
    ) { [weak self] in self?.remove(member, leaving: leaving) }
  }

  private func remove(_ member: QFHouseholdMember, leaving: Bool) {
    execute(label: app.text("正在更新成员", "Updating member")) { [self] in
      try await app.removeHouseholdMember(
        householdID: household.id, publicUserID: member.publicUserId)
      try Task.checkCancellation()
      onChanged?()
      if leaving {
        qfClose()
      } else {
        try await refreshAfterMutation()
      }
    }
  }

  private func confirmTransfer(_ member: QFHouseholdMember) {
    confirm(
      app.text("转让家庭所有权？", "Transfer household ownership?"),
      detail: app.text("转让后你将变为管理员。", "You will become an admin after the transfer."),
      actionTitle: app.text("确认转让", "Transfer"), destructive: true
    ) { [weak self] in self?.transfer(member) }
  }

  private func transfer(_ member: QFHouseholdMember) {
    execute(label: app.text("正在转让", "Transferring")) { [self] in
      household = try await app.transferHouseholdOwnership(
        household.id,
        draft: QFHouseholdOwnershipTransferDraft(
          publicUserId: member.publicUserId, expectedRevision: household.revision))
      try await refreshAfterMutation()
      onChanged?()
    }
  }

  private func chooseInvitationRole() {
    let sheet = UIAlertController(
      title: app.text("邀请成员", "Invite member"),
      message: app.text("选择新成员权限", "Choose the new member's access."),
      preferredStyle: .actionSheet)
    for role in ["ADMIN", "EDITOR", "VIEWER"] {
      sheet.addAction(UIAlertAction(title: roleTitle(role), style: .default) { [weak self] _ in
        self?.createInvitation(role: role)
      })
    }
    sheet.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    sheet.popoverPresentationController?.sourceView = footer
    sheet.popoverPresentationController?.sourceRect = footer.bounds
    open(sheet)
  }

  private func createInvitation(role: String) {
    execute(label: app.text("正在创建邀请", "Creating invitation")) { [self] in
      let invitation = try await app.createHouseholdInvitation(
        household.id,
        draft: QFHouseholdInvitationDraft(role: role, expiresInHours: 72, maxUses: 1))
      try Task.checkCancellation()
      guard let token = invitation.token, !token.isEmpty else {
        throw QFAPIError(code: 50300, message: "INVITATION_TOKEN_MISSING")
      }
      showInvitation(invitation: invitation, token: token)
    }
  }

  private func showInvitation(invitation: QFHouseholdInvitation, token: String) {
    let alert = UIAlertController(
      title: app.text("邀请口令", "Invitation token"),
      message: token + "\n\n" + app.format("有效期至：%@", "Expires: %@", invitation.expiresAt),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: app.text("关闭", "Close"), style: .cancel))
    alert.addAction(UIAlertAction(title: app.text("复制口令", "Copy token"), style: .default) { [weak self] _ in
      UIPasteboard.general.string = token
      if let self { self.message(self.app.text("口令已复制", "Token copied")) }
    })
    alert.addAction(UIAlertAction(title: app.text("撤销邀请", "Revoke invitation"), style: .destructive) {
      [weak self] _ in self?.confirmRevokeInvitation(invitation)
    })
    open(alert)
  }

  private func confirmRevokeInvitation(_ invitation: QFHouseholdInvitation) {
    confirm(
      app.text("撤销这条邀请？", "Revoke this invitation?"),
      detail: app.text("撤销后该口令立即失效。", "The invitation token will stop working immediately."),
      actionTitle: app.text("撤销邀请", "Revoke invitation"), destructive: true
    ) { [weak self] in self?.revokeInvitation(invitation) }
  }

  private func revokeInvitation(_ invitation: QFHouseholdInvitation) {
    execute(label: app.text("正在撤销邀请", "Revoking invitation")) { [self] in
      try await app.revokeHouseholdInvitation(
        household.id, invitationID: invitation.id)
      try Task.checkCancellation()
      message(app.text("邀请已撤销", "Invitation revoked"))
    }
  }

  private func editHousehold() {
    let controller = QFHouseholdEditorViewController(
      app: app, household: household,
      onDissolved: { [weak self] in
        guard let self else { return }
        self.onChanged?()
        self.qfClose()
      }
    ) { [weak self] saved in
        guard let self else { return }
        self.household = saved
        self.updateHeading(saved.name)
        self.render()
        self.onChanged?()
      }
    controller.onChanged = { [weak self] in self?.onChanged?() }
    open(controller)
  }

  private func refreshAfterMutation() async throws {
    async let householdRequest = app.household(household.id)
    async let memberRequest = app.householdMembers(household.id, page: 0)
    let values = try await (householdRequest, memberRequest)
    try Task.checkCancellation()
    household = values.0
    members = values.1.items
    total = values.1.total
    nextPage = 1
    hasMore = members.count < total
    updateHeading(household.name)
    render()
    onChanged?()
  }

  private func roleTitle(_ role: String) -> String {
    switch role {
    case "OWNER": return app.text("所有者", "Owner")
    case "ADMIN": return app.text("管理员", "Admin")
    case "EDITOR": return app.text("可编辑", "Editor")
    case "VIEWER": return app.text("仅查看", "Viewer")
    default: return role
    }
  }
}
