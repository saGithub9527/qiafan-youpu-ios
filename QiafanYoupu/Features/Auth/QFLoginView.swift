import Combine
import SnapKit
import UIKit

@MainActor
final class QFLoginViewController: UIViewController {
  private enum LoginMethod { case quick, apple }
  private let app: QFAppSession
  private let onClose: () -> Void
  private let appleAuthorization = QFAppleAuthorization()
  private let form = UIView()
  private let closeButton = UIButton(type: .system)
  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private let hero = QFAuthChefHeroView()
  private let heroRow = UIView()
  private let brand = QFUI.label("恰饭有谱", size: 32, weight: .bold)
  private let tagline = QFUI.label("收藏世界风味，记录每一餐", size: 15, color: QFUI.secondary)
  private let quickButton = QFAuthLoadingButton("快速登录", size: 20)
  private let appleButton = QFAuthLoadingButton("通过 Apple 登录", background: .black, size: 22, symbol: "apple.logo", cornerRadius: 8)
  private let retryButton = QFAuthLoadingButton("重试加载启动配置", background: .clear, textColor: QFUI.green, size: 14)
  private let agreement = QFAuthAgreementControl(identifier: "login.agreement", noticeStyle: false)
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
    reloadAgreement()
    updateButtons()
    Publishers.CombineLatest4(app.$configuration, app.$configurationError,
                              app.$loadingConfiguration, app.$isLoggingIn)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        guard let self else { return }
        if self.lastRevision != state.0?.consentRevision { self.reloadAgreement() }
        self.updateButtons()
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
    closeButton.accessibilityLabel = "关闭登录"
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
    retryButton.snp.makeConstraints { $0.height.equalTo(44).priority(999) }
    [heroRow, brand, tagline, loginButtons, retryButton, agreement].forEach { stack.addArrangedSubview($0) }
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
      self.present(QFAuthAgreementViewController(app: self.app, document: document), animated: true)
    }
  }

  private func updateSpacing() {
    contentTop?.update(offset: compactHeight ? 10 : 23)
    stack.setCustomSpacing(compactHeight ? 12 : 19, after: heroRow)
    stack.setCustomSpacing(12, after: brand)
    stack.setCustomSpacing(compactHeight ? 20 : 70, after: tagline)
    let agreementGap: CGFloat = compactHeight ? 24 : 88
    stack.setCustomSpacing(retryButton.isHidden ? agreementGap : 12, after: loginButtons)
    stack.setCustomSpacing(agreementGap, after: retryButton)
  }

  private func updateButtons() {
    guard isViewLoaded else { return }
    quickButton.setLoading(activeMethod == .quick)
    appleButton.setLoading(activeMethod == .apple)
    retryButton.setLoading(retryingConfiguration)
    quickButton.isEnabled = !interactionBlocked
    appleButton.isEnabled = !interactionBlocked
    retryButton.isEnabled = !interactionBlocked
    closeButton.isEnabled = activeMethod == nil
    agreement.setEnabled(!interactionBlocked)
    retryButton.isHidden = app.configurationError == nil && !retryingConfiguration
    let loadingConfig = app.loadingConfiguration || retryingConfiguration
    quickButton.accessibilityValue = activeMethod == .quick ? "正在登录"
      : (loadingConfig ? "配置加载中" : (app.loginAvailability(apple: false) == nil ? "可用" : "暂不可用"))
    appleButton.accessibilityValue = activeMethod == .apple
      ? (authorizingApple ? "正在等待 Apple 授权" : "正在登录")
      : (loadingConfig ? "配置加载中" : (app.loginAvailability(apple: true) == nil ? "可用" : "暂不可用"))
    retryButton.accessibilityValue = retryingConfiguration ? "正在加载" : "可重试"
    isModalInPresentation = activeMethod != nil || noticeController != nil
    updateSpacing()
  }

  private func reloadAgreement() {
    lastRevision = app.configuration?.consentRevision
    agreementChecked = lastRevision.map { QFAuthConsentStore.isAgreementChecked(revision: $0) } ?? false
    agreement.checked = agreementChecked
    noticeController?.setChecked(agreementChecked)
  }

  private func setAgreement(_ checked: Bool) {
    agreementChecked = checked
    agreement.checked = checked
    QFAuthConsentStore.setAgreementChecked(checked, revision: app.configuration?.consentRevision ?? "ui-placeholder-v1")
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
    if let reason = app.loginAvailability(apple: method == .apple) { showError(reason); return }
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
        let error = error as NSError
        if error.domain == "com.apple.AuthenticationServices.AuthorizationError", error.code == 1001 { return }
        guard !Task.isCancelled else { return }
        self?.showError(error.localizedDescription)
      }
    }
  }

  private func showError(_ message: String) {
    guard !closed, presentedViewController == nil else { return }
    let alert = UIAlertController(title: "登录提示", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "知道了", style: .cancel))
    present(alert, animated: true)
  }
}
