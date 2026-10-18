import AuthenticationServices
import Combine
import SnapKit
import UIKit

@MainActor
final class QFLoginViewController: UIViewController {
  private enum LoginMethod { case quick, apple }
  private let app: QFAppSession
  private let onClose: () -> Void
  private lazy var appleAuthorization = QFAppleAuthorization(app: app)
  private let form = UIView()
  private let closeButton = UIButton(type: .system)
  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private lazy var hero = QFAuthChefHeroView(app: app)
  private let heroRow = UIView()
  private lazy var brand = QFUI.label(app.text("恰饭有谱", "Qiafan Youpu"), size: 32, weight: .bold)
  private lazy var tagline = QFUI.label(app.text("收藏世界风味，记录每一餐", "Save flavors from around the world and remember every meal"), size: 15, color: QFUI.secondary)
  private lazy var quickButton = QFAuthLoadingButton(app.text("快速登录", "Quick sign in"), size: 20)
  private let appleButton = ASAuthorizationAppleIDButton(
    authorizationButtonType: .signIn,
    authorizationButtonStyle: QFThemeManager.shared.current == .dark ? .white : .black)
  private let appleStatusRow = UIView()
  private let appleSpinner = UIActivityIndicatorView(style: .medium)
  private let appleStatus = UILabel()
  private lazy var retryButton = QFAuthLoadingButton(app.text("重试加载启动配置", "Retry loading configuration"), background: .clear, textColor: QFUI.green, size: 14)
  private lazy var agreement = QFAuthAgreementControl(app: app, identifier: "login.agreement", noticeStyle: false)
  private let loginButtons = UIStackView()
  private var heroSize: Constraint?
  private var contentTop: Constraint?
  private var subscriptions = Set<AnyCancellable>()
  private var loginTask: Task<Void, Never>?
  private var configurationTask: Task<Void, Never>?
  private var agreementChecked = false
  private var activeMethod: LoginMethod?
  private var pendingMethod: LoginMethod?
  private var authorizingApple = false
  private var retryingConfiguration = false
  private var lastRevision: String?
  private var lastAppleStatus: String?
  private var compactHeight = false
  private var lastHeroWidth: CGFloat = 0
  private var closed = false
  private weak var noticeController: QFSafetyNoticeViewController?

  init(app: QFAppSession, onClose: @escaping () -> Void) {
    self.app = app
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { return nil }
  deinit { loginTask?.cancel(); configurationTask?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    buildLayout()
    wireActions()
    localize()
    reloadAgreement()
    updateButtons()
    Publishers.CombineLatest4(app.$configuration, app.$configurationError,
                              app.$loadingConfiguration, app.$isLoggingIn)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        guard let self else { return }
        if self.lastRevision != self.agreementRevision { self.reloadAgreement() }
        self.updateButtons()
      }.store(in: &subscriptions)
    app.$interfaceLanguage.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.localize()
      self?.updateButtons()
    }.store(in: &subscriptions)
    QFDiagnosticsPresenter.attach(to: self, app: app, bottomInset: 76)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reloadAgreement()
    updateButtons()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let height = view.bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom
    compactHeight = height < 500
    let width = max(1, min(520, form.bounds.width))
    let regularHero = max(1, min(320, (width - 60) * 0.69))
    let heroWidth = compactHeight ? min(regularHero, max(80, height * 0.3)) : regularHero
    if abs(heroWidth - lastHeroWidth) > 0.5 {
      lastHeroWidth = heroWidth
      heroSize?.update(offset: heroWidth)
    }
    updateSpacing()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true {
      loginTask?.cancel()
      configurationTask?.cancel()
      subscriptions.removeAll()
    }
  }

  private var interactionBlocked: Bool {
    activeMethod != nil || app.isLoggingIn || retryingConfiguration || app.loadingConfiguration
  }

  private func buildLayout() {
    view.addSubview(form)
    form.snp.makeConstraints {
      $0.top.bottom.equalTo(view.safeAreaLayoutGuide)
      $0.centerX.equalToSuperview()
      $0.width.equalTo(view.safeAreaLayoutGuide.snp.width).priority(.high)
      $0.width.lessThanOrEqualTo(520)
      $0.leading.greaterThanOrEqualTo(view.safeAreaLayoutGuide.snp.leading)
      $0.trailing.lessThanOrEqualTo(view.safeAreaLayoutGuide.snp.trailing)
    }
    closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .light)), for: .normal)
    closeButton.tintColor = QFAuthPalette.color(0x5E6C69)
    closeButton.backgroundColor = QFUI.surface
    closeButton.layer.cornerRadius = 20
    closeButton.accessibilityLabel = app.text("关闭登录", "Close sign in")
    closeButton.accessibilityIdentifier = "login.close"
    form.addSubview(closeButton)
    closeButton.snp.makeConstraints { $0.leading.equalToSuperview().offset(20); $0.top.equalToSuperview().offset(10); $0.width.height.equalTo(40) }
    form.addSubview(scroll)
    scroll.showsVerticalScrollIndicator = false
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.snp.makeConstraints {
      $0.top.equalTo(closeButton.snp.bottom).offset(12)
      $0.leading.trailing.equalToSuperview()
      $0.bottom.equalToSuperview().inset(12)
    }
    stack.axis = .vertical
    stack.spacing = 0
    scroll.addSubview(stack)
    stack.snp.makeConstraints {
      contentTop = $0.top.equalTo(scroll.contentLayoutGuide.snp.top).offset(23).constraint
      $0.leading.trailing.equalTo(scroll.contentLayoutGuide).inset(30)
      $0.bottom.equalTo(scroll.contentLayoutGuide.snp.bottom).inset(12)
      $0.width.equalTo(scroll.frameLayoutGuide.snp.width).offset(-60)
    }
    heroRow.addSubview(hero)
    hero.snp.makeConstraints {
      $0.top.bottom.equalToSuperview()
      $0.centerX.equalToSuperview()
      heroSize = $0.width.equalTo(220).constraint
      $0.height.equalTo(hero.snp.width)
    }
    brand.textAlignment = .center
    tagline.textAlignment = .center
    loginButtons.axis = .vertical
    loginButtons.spacing = 16
    loginButtons.addArrangedSubview(quickButton)
    loginButtons.addArrangedSubview(appleButton)
    quickButton.snp.makeConstraints { $0.height.equalTo(55) }
    appleButton.snp.makeConstraints { $0.height.equalTo(55) }
    appleButton.cornerRadius = 8
    appleStatus.font = .preferredFont(forTextStyle: .footnote)
    appleStatus.adjustsFontForContentSizeCategory = true
    appleStatus.textColor = QFUI.secondary
    appleStatus.numberOfLines = 0
    appleStatus.accessibilityIdentifier = "login.apple.status"
    appleSpinner.color = QFUI.secondary
    appleSpinner.hidesWhenStopped = true
    appleSpinner.isAccessibilityElement = false
    appleStatusRow.addSubview(appleSpinner)
    appleStatusRow.addSubview(appleStatus)
    appleSpinner.snp.makeConstraints {
      $0.leading.equalToSuperview()
      $0.centerY.equalToSuperview()
      $0.width.height.equalTo(20)
    }
    appleStatus.snp.makeConstraints {
      $0.leading.equalTo(appleSpinner.snp.trailing).offset(8)
      $0.trailing.equalToSuperview()
      $0.top.bottom.equalToSuperview().inset(4)
      // Keep two lines reserved even when idle; waiting never moves the button.
      $0.height.greaterThanOrEqualTo(appleStatus.font.lineHeight * 2)
    }
    retryButton.snp.makeConstraints { $0.height.equalTo(44).priority(999) }
    [heroRow, brand, tagline, loginButtons, appleStatusRow, retryButton, agreement].forEach { stack.addArrangedSubview($0) }
    quickButton.accessibilityIdentifier = "login.quick"
    appleButton.accessibilityIdentifier = "login.apple"
    retryButton.accessibilityIdentifier = "login.configuration.retry"
    updateSpacing()
  }

  private func wireActions() {
    closeButton.addAction(UIAction { [weak self] _ in
      guard let self, self.activeMethod == nil, !self.closed else { return }
      self.pendingMethod = nil
      self.loginTask?.cancel()
      self.configurationTask?.cancel()
      self.closed = true
      self.onClose()
    }, for: .touchUpInside)
    quickButton.addAction(UIAction { [weak self] _ in self?.requestLogin(.quick) }, for: .touchUpInside)
    appleButton.addAction(UIAction { [weak self] _ in self?.requestLogin(.apple) }, for: .touchUpInside)
    retryButton.addAction(UIAction { [weak self] _ in self?.retryConfiguration() }, for: .touchUpInside)
    agreement.onCheckedChange = { [weak self] checked in self?.setAgreement(checked) }
    agreement.onReadDocument = { [weak self] document in
      guard let self, !self.interactionBlocked, self.presentedViewController == nil else { return }
      self.qfPush(
        QFLocalLegalViewController(
          document: document == .privacy ? "privacy-policy" : "user-agreement",
          title: document.title(app: self.app), language: self.app.interfaceLanguage))
    }
  }

  private func updateSpacing() {
    contentTop?.update(offset: compactHeight ? 10 : 23)
    stack.setCustomSpacing(compactHeight ? 12 : 19, after: heroRow)
    stack.setCustomSpacing(12, after: brand)
    stack.setCustomSpacing(compactHeight ? 20 : 70, after: tagline)
    let agreementGap: CGFloat = compactHeight ? 24 : 88
    stack.setCustomSpacing(4, after: loginButtons)
    stack.setCustomSpacing(retryButton.isHidden ? agreementGap : 12, after: appleStatusRow)
    stack.setCustomSpacing(agreementGap, after: retryButton)
  }

  private func updateButtons() {
    guard isViewLoaded else { return }
    quickButton.setLoading(activeMethod == .quick)
    retryButton.setLoading(retryingConfiguration)
    quickButton.isEnabled = !interactionBlocked
    appleButton.isEnabled = !interactionBlocked && app.loginAvailability(apple: true) == nil
    retryButton.isEnabled = !interactionBlocked
    closeButton.isEnabled = activeMethod == nil
    agreement.setEnabled(!interactionBlocked)
    retryButton.isHidden = app.configurationError == nil && !retryingConfiguration
    let loadingConfig = app.loadingConfiguration || retryingConfiguration
    quickButton.accessibilityValue = activeMethod == .quick ? app.text("正在登录", "Signing in")
      : (loadingConfig ? app.text("配置加载中", "Loading configuration") : (app.loginAvailability(apple: false) == nil ? app.text("可用", "Available") : app.text("暂不可用", "Unavailable")))
    appleButton.accessibilityValue = activeMethod == .apple
      ? (authorizingApple ? app.text("正在等待 Apple 授权", "Waiting for Apple authorization") : app.text("正在登录", "Signing in"))
      : (loadingConfig ? app.text("配置加载中", "Loading configuration") : (app.loginAvailability(apple: true) == nil ? app.text("可用", "Available") : app.text("暂不可用", "Unavailable")))
    retryButton.accessibilityValue = retryingConfiguration ? app.text("正在加载", "Loading") : app.text("可重试", "Ready to retry")
    updateAppleStatus()
    isModalInPresentation = activeMethod != nil || noticeController != nil
    updateSpacing()
  }

  private func updateAppleStatus() {
    let message: String?
    if activeMethod == .apple {
      message = authorizingApple ? app.text("正在等待 Apple 授权", "Waiting for Apple authorization") : app.text("正在登录", "Signing in")
    } else if app.loadingConfiguration || retryingConfiguration {
      message = app.text("配置加载中", "Loading configuration")
    } else if app.configurationError != nil {
      message = app.text("登录信息加载失败，请重试", "Sign-in information failed to load. Please retry.")
    } else if app.loginAvailability(apple: true) != nil {
      message = app.text("Apple 登录暂不可用", "Sign in with Apple is unavailable")
    } else {
      message = nil
    }
    let changed = lastAppleStatus != message
    lastAppleStatus = message
    appleStatus.text = message ?? app.text("正在等待 Apple 授权", "Waiting for Apple authorization")
    appleStatus.alpha = message == nil ? 0 : 1
    appleStatus.isAccessibilityElement = message != nil
    if activeMethod == .apple { appleSpinner.startAnimating() } else { appleSpinner.stopAnimating() }
    if changed, UIAccessibility.isVoiceOverRunning, view.window != nil {
      UIAccessibility.post(notification: .announcement, argument: message ?? app.text("Apple 登录可用", "Sign in with Apple is available"))
    }
  }

  private func reloadAgreement() {
    lastRevision = agreementRevision
    agreementChecked = lastRevision.map { QFAuthConsentStore.isAgreementChecked(revision: $0) } ?? false
    agreement.checked = agreementChecked
    noticeController?.setChecked(agreementChecked)
  }

  private func setAgreement(_ checked: Bool) {
    agreementChecked = checked
    agreement.checked = checked
    QFAuthConsentStore.setAgreementChecked(
      checked, revision: agreementRevision ?? QFAuthConsentStore.fallbackRevision)
  }

  private var agreementRevision: String? {
    app.configuration?.consentRevision.map {
      QFAuthConsentStore.fallbackRevision + ":" + $0
    }
  }

  private func requestLogin(_ method: LoginMethod) {
    guard !closed, !interactionBlocked, presentedViewController == nil else { return }
    if agreementChecked { beginLogin(method); return }
    pendingMethod = method
    let notice = QFSafetyNoticeViewController(
      app: app, checked: agreementChecked,
      onCheckedChange: { [weak self] checked in self?.setAgreement(checked) },
      onContinue: { [weak self] in
        guard let self else { return }
        let method = self.pendingMethod
        self.pendingMethod = nil
        self.noticeController = nil
        self.updateButtons()
        if let method, self.agreementChecked { self.beginLogin(method) }
      },
      onDecline: { [weak self] in
        self?.pendingMethod = nil
        self?.noticeController = nil
        self?.updateButtons()
      })
    noticeController = notice
    present(notice, animated: false)
  }

  private func retryConfiguration() {
    guard !closed, !interactionBlocked else { return }
    retryingConfiguration = true
    updateButtons()
    configurationTask = Task { [weak self, app] in
      await app.loadConfiguration()
      guard let self else { return }
      self.retryingConfiguration = false
      self.configurationTask = nil
      self.updateButtons()
    }
  }

  private func beginLogin(_ method: LoginMethod) {
    guard !closed, agreementChecked, !interactionBlocked else { return }
    if app.loginAvailability(apple: method == .apple) != nil {
      showError(app.configurationError != nil ? app.text("登录信息加载失败，请重试", "Sign-in information failed to load. Please retry.")
        : (method == .apple ? app.text("Apple 登录暂不可用", "Sign in with Apple is unavailable") : app.text("暂时无法完成登录，请稍后重试。", "Sign in is temporarily unavailable. Please try again later.")))
      return
    }
    activeMethod = method
    authorizingApple = method == .apple
    updateButtons()
    let consent = agreementChecked
    loginTask = Task { [weak self, app, appleAuthorization] in
      defer {
        self?.activeMethod = nil
        self?.authorizingApple = false
        self?.loginTask = nil
        self?.updateButtons()
      }
      do {
        let code = method == .apple ? try await appleAuthorization.authorize() : nil
        self?.authorizingApple = false
        self?.updateButtons()
        try Task.checkCancellation()
        try await app.login(authorizationCode: code, agreementAccepted: consent)
        try Task.checkCancellation()
        guard let self, !self.closed else { return }
        self.closed = true
        self.onClose()
      } catch is CancellationError {
      } catch {
        let nsError = error as NSError
        if nsError.domain == ASAuthorizationError.errorDomain,
           nsError.code == ASAuthorizationError.canceled.rawValue { return }
        guard !Task.isCancelled else { return }
        if (error as? QFAPIError)?.code == 40301 { self?.setAgreement(false) }
        guard let self else { return }
        self.showError(QFLoginFailureMessage.message(
          for: error, authorizingApple: self.authorizingApple, appleLogin: method == .apple,
          app: app))
      }
    }
  }

  private func showError(_ message: String) {
    guard !closed, presentedViewController == nil else { return }
    let alert = UIAlertController(title: app.text("登录提示", "Sign-in notice"), message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: app.text("知道了", "OK"), style: .cancel))
    present(alert, animated: true)
  }

  private func localize() {
    guard isViewLoaded else { return }
    brand.text = app.text("恰饭有谱", "Qiafan Youpu")
    tagline.text = app.text("收藏世界风味，记录每一餐", "Save flavors from around the world and remember every meal")
    quickButton.setTitle(app.text("快速登录", "Quick sign in"))
    retryButton.setTitle(app.text("重试加载启动配置", "Retry loading configuration"))
    closeButton.accessibilityLabel = app.text("关闭登录", "Close sign in")
  }
}

// G1-approved presentation policy. Never show server messages or underlying credential errors.
enum QFLoginFailureMessage {
  @MainActor
  static func message(for error: Error, authorizingApple: Bool, appleLogin: Bool, app: QFAppSession) -> String {
    if authorizingApple { return app.text("Apple 授权未完成，请重试。", "Apple authorization was not completed. Please retry.") }
    let unavailable = app.text("暂时无法完成登录，请稍后重试。", "Sign in is temporarily unavailable. Please try again later.")
    guard let apiError = error as? QFAPIError else { return unavailable }
    switch apiError.code {
    case 40100: return appleLogin ? app.text("Apple 授权已失效，请重新授权", "Apple authorization has expired. Please authorize again.") : unavailable
    case 40101: return unavailable // Device credential failure is not an expired Apple authorization.
    case 40300: return app.text("当前账号暂不可用", "This account is temporarily unavailable.")
    case 40301: return app.text("请先阅读并同意用户协议和隐私政策", "Please read and agree to the Terms of Service and Privacy Policy first.")
    case 40903: return app.text("当前 Apple 身份无法用于此设备的账号登录。", "This Apple ID cannot be used to sign in to the account on this device.")
    case 42900: return app.text("操作过于频繁，请稍后再试。", "Too many attempts. Please try again later.")
    default: return unavailable
    }
  }
}
