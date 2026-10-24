import Combine
import SnapKit
import UIKit
import UserNotifications

@main
@MainActor
final class QFAppDelegate: UIResponder, UIApplicationDelegate {
  let session = QFAppSession()
  private var sessionStartup: Task<Void, Never>?
  func startSession() async {
    if let sessionStartup { await sessionStartup.value; return }
    let task = Task { [session] in await session.start() }
    sessionStartup = task
    await task.value
  }
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    QFGetuiPushService.shared.prepare(launchOptions: launchOptions)
    if !QFRuntime.isUnitTest {
      let consent = UserDefaults.standard.bool(forKey: QFLaunchPolicy.completedKey)
      QFGetuiPushService.shared.bind(to: session, privacyConsentAccepted: consent)
      QFMealSurfaceCoordinator.shared.bind(to: session, privacyConsentAccepted: consent)
      QFMealLivePushService.shared.bind(app: session, privacyConsentAccepted: consent)
      // ActivityKit can launch the app in the background without creating a scene.
      Task { await startSession() }
    }
    return true
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(
      name: "Default", sessionRole: connectingSceneSession.role)
    configuration.delegateClass = QFSceneDelegate.self
    return configuration
  }

  func application(
    _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
  ) -> UIInterfaceOrientationMask {
    UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
  }
}

@MainActor
final class QFSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var session: QFAppSession { (UIApplication.shared.delegate as! QFAppDelegate).session }
  private var startup: Task<Void, Never>?
  private var didScheduleCrashRecorder = false
  private var launchOptions: QFLaunchOptions?
  private let keyboardDismissal = QFKeyboardDismissal()

  func scene(
    _ scene: UIScene, willConnectTo sceneSession: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: windowScene)
    let options = QFLaunchOptions()
    launchOptions = options
    QFGetuiPushService.shared.rememberSceneConnection(connectionOptions)
    if !QFRuntime.isUnitTest {
      connectionOptions.urlContexts.forEach { QFMealSurfaceNavigation.shared.open($0.url) }
    }
    configureTheme(on: window)
    window.rootViewController = QFRootViewController(
      app: session, options: options,
      onPrivacyConsentAccepted: { [weak self] in
        guard let self else { return }
        QFGetuiPushService.shared.privacyConsentWasAccepted()
        QFMealSurfaceCoordinator.shared.privacyConsentWasAccepted()
        QFMealLivePushService.shared.bind(app: self.session, privacyConsentAccepted: true)
      })
    self.window = window
    keyboardDismissal.install(in: window)
    QFThemeManager.shared.onChange = { [weak self] _ in
      self?.reloadRootForTheme()
    }
    window.makeKeyAndVisible()
    if !QFRuntime.isUnitTest {
      startup = Task { [session] in
        if let delegate = UIApplication.shared.delegate as? QFAppDelegate { await delegate.startSession() }
        #if DEBUG
        QFAssistantAgentDeviceCheck.collectRecentFailureMetadataIfRequested(app: session)
        await QFAssistantAgentDeviceCheck.collectReminderStatusIfRequested(app: session)
        await QFMealSurfaceDeviceCheck.collectIfRequested(app: session)
        await QFMembershipDeviceCheck.collectIfRequested(app: session)
        await QFMealDisplayProbe.runIfRequested(app: session)
        await QFProductBarcodeDeviceCheck.verifyLiveIfRequested(app: session)
        #endif
      }
    }
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    URLContexts.forEach { QFMealSurfaceNavigation.shared.open($0.url) }
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    QFGetuiPushService.shared.applicationDidBecomeActive()
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-QFPrepareLocalModel") { _ = QFLocalModelStore.shared }
    if !QFRuntime.isUnitTest {
      QFLocalDeploymentCheck.startIfRequested(); QFAssistantAgentDeviceCheck.startIfRequested(app: session)
      QFProductBarcodeDeviceCheck.startIfRequested()
    }
    #endif
    guard !QFRuntime.isUnitTest, !didScheduleCrashRecorder else { return }
    didScheduleCrashRecorder = true

    // Keep crash-report decoding and disk maintenance away from the window's first frame.
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
      _ = QFCrashRecorder.shared.start()
    }
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    #if DEBUG
    QFLocalDeploymentCheck.cancel()
    QFAssistantAgentDeviceCheck.cancel()
    QFProductBarcodeDeviceCheck.cancel()
    #endif
  }

  private func configureTheme(on window: UIWindow) {
    window.overrideUserInterfaceStyle = QFThemeManager.shared.current == .dark ? .dark : .light
    window.tintColor = QFUI.primary
    window.backgroundColor = QFUI.background
  }

  private func reloadRootForTheme() {
    guard let window else { return }
    configureTheme(on: window)
    let options = QFLaunchOptions(
      showWelcome: false, initialTab: .profile,
      previewSignedIn: launchOptions?.previewSignedIn ?? false)
    window.rootViewController = QFRootViewController(
      app: session, options: options,
      onPrivacyConsentAccepted: { [weak self] in
        guard let self else { return }
        QFGetuiPushService.shared.privacyConsentWasAccepted()
        QFMealSurfaceCoordinator.shared.privacyConsentWasAccepted()
        QFMealLivePushService.shared.bind(app: self.session, privacyConsentAccepted: true)
      })
    window.makeKeyAndVisible()
  }
}

/// One gesture per app window also covers forms presented above the tab controllers.
@MainActor
private final class QFKeyboardDismissal: NSObject, UIGestureRecognizerDelegate {
  private weak var window: UIWindow?

  func install(in window: UIWindow) {
    self.window = window
    let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
    tap.cancelsTouchesInView = false
    tap.delegate = self
    window.addGestureRecognizer(tap)
  }

  @objc private func dismissKeyboard() { window?.endEditing(true) }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool
  {
    var ancestor = touch.view
    while let view = ancestor {
      // Keep selection, cursor movement and all control actions intact.
      if view is UITextInput || view is UIControl { return false }
      ancestor = view.superview
    }
    return true
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool { true }
}

enum QFTab: String, CaseIterable, Identifiable {
  case recipe, plan, ingredient, profile
  var id: String { rawValue }
  var title: String {
    title(language: .simplifiedChinese)
  }
  func title(language: QFInterfaceLanguage) -> String {
    switch self {
    case .recipe: return language.text(chinese: "菜谱", english: "Recipes")
    case .plan: return language.text(chinese: "计划", english: "Plan")
    case .ingredient: return language.text(chinese: "食材", english: "Ingredients")
    case .profile: return language.text(chinese: "我的", english: "Me")
    }
  }
  var symbol: String {
    switch self {
    case .recipe: return "book.closed"
    case .plan: return "calendar.badge.checkmark"
    case .ingredient: return "basket"
    case .profile: return "person"
    }
  }
}

@MainActor
private final class QFRootViewController: UIViewController {
  private let app: QFAppSession
  private let options: QFLaunchOptions
  private let onPrivacyConsentAccepted: () -> Void
  private var current: UIViewController?
  private var preparedCharacter: QFAssistantCharacterView?

  init(
    app: QFAppSession, options: QFLaunchOptions,
    onPrivacyConsentAccepted: @escaping () -> Void
  ) {
    self.app = app
    self.options = options
    self.onPrivacyConsentAccepted = onPrivacyConsentAccepted
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    if !QFRuntime.isUnitTest {
      _ = QFLocalModelStore.shared
      let character = QFAssistantCharacterView()
      character.isHidden = true
      view.addSubview(character)
      character.snp.makeConstraints {
        $0.leading.top.equalToSuperview(); $0.width.equalTo(92); $0.height.equalTo(112)
      }
      view.layoutIfNeeded()
      preparedCharacter = character
    }
    if options.showWelcome {
      install(
        QFWelcomeViewController(app: app) { [weak self] in
          UserDefaults.standard.set(true, forKey: QFLaunchPolicy.completedKey)
          self?.onPrivacyConsentAccepted()
          self?.showTabs()
        })
    } else {
      showTabs()
    }
  }

  private func showTabs() {
    install(QFMainTabViewController(app: app, options: options, preparedCharacter: preparedCharacter))
    preparedCharacter = nil
  }

  private func install(_ controller: UIViewController) {
    if let current {
      current.willMove(toParent: nil)
      current.view.removeFromSuperview()
      current.removeFromParent()
    }
    addChild(controller)
    view.addSubview(controller.view)
    controller.view.snp.makeConstraints { $0.edges.equalToSuperview() }
    controller.didMove(toParent: self)
    current = controller
    // The welcome flow replaces its child after the root controller is already visible, so
    // UIKit may not send a fresh viewDidAppear to the new tab controller. Trigger the same
    // post-first-frame hook explicitly; the overlay keeps an idempotent one-greeting gate.
    (controller as? QFMainTabViewController)?.hostDidAppear()
  }
}

@MainActor
private final class QFMainTabViewController: UITabBarController, UITabBarControllerDelegate {
  private let app: QFAppSession
  private let options: QFLaunchOptions
  private let preparedCharacter: QFAssistantCharacterView?
  private var assistantOverlay: QFDigitalAssistantOverlay?
  private var subscriptions = Set<AnyCancellable>()
  private var showingMealLogin = false
  init(app: QFAppSession, options: QFLaunchOptions, preparedCharacter: QFAssistantCharacterView? = nil) {
    self.app = app
    self.options = options
    self.preparedCharacter = preparedCharacter
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    hostDidAppear()
  }
  func hostDidAppear() { assistantOverlay?.hostDidAppear() }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    assistantOverlay?.ensureOnTop()
  }
  override func viewDidLoad() {
    super.viewDidLoad()
    let pages: [UIViewController] = [
      QFRecipeViewController(app: app), QFPlanViewController(app: app),
      QFIngredientViewController(app: app),
      QFProfileViewController(app: app, previewSignedIn: options.previewSignedIn) { [weak self] in
        self?.showLogin()
      },
    ]
    let language = QFInterfaceLanguage.normalized(app.interfaceLanguage)
    viewControllers = zip(QFTab.allCases, pages).map { tab, page in
      let navigation = QFNavigationController(rootViewController: page)
      navigation.tabBarItem = UITabBarItem(
        title: tab.title(language: language), image: UIImage(systemName: tab.symbol),
        selectedImage: UIImage(systemName: tab.symbol))
      navigation.tabBarItem.accessibilityIdentifier = "tab.\(tab.rawValue)"
      return navigation
    }
    selectedIndex = QFTab.allCases.firstIndex(of: options.initialTab) ?? 0
    let appearance = UITabBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = QFUI.surface
    appearance.stackedLayoutAppearance.selected.iconColor = QFUI.primary
    appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
      .foregroundColor: QFUI.primary
    ]
    tabBar.standardAppearance = appearance
    tabBar.scrollEdgeAppearance = appearance
    tabBar.tintColor = QFUI.primary
    tabBar.unselectedItemTintColor = QFUI.secondary
    QFDiagnosticsPresenter.attach(to: self, app: app, bottomInset: 76)
    delegate = self
    let assistant = QFDigitalAssistantOverlay(app: app, character: preparedCharacter)
    assistant.onOpenMealReminder = { [weak self] id in self?.openPlanReminder(plannedMealID: id) }
    assistant.attach(to: self)
    assistantOverlay = assistant
    NotificationCenter.default.publisher(for: .qfDidReceiveRemoteNotification)
      .receive(on: DispatchQueue.main).sink { [weak self] notification in
        guard let self else { return }
        if let plannedMealID = QFRemoteNotificationRoute.plannedMealID(from: notification) {
          self.openPlanReminder(plannedMealID: plannedMealID)
        } else if QFRemoteNotificationRoute.isAssistantNudge(from: notification) {
          self.assistantOverlay?.presentConversation()
        }
      }.store(in: &subscriptions)
    QFMealSurfaceNavigation.shared.$pending.receive(on: DispatchQueue.main).sink { [weak self] route in
      if route != nil { self?.openPendingMealSurface() }
    }.store(in: &subscriptions)
    app.$user.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] user in
      if user != nil { self?.openPendingMealSurface() }
    }.store(in: &subscriptions)
    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] code in
      guard let self else { return }
      let language = QFInterfaceLanguage.normalized(code)
      for (tab, controller) in zip(QFTab.allCases, self.viewControllers ?? []) {
        controller.tabBarItem.title = tab.title(language: language)
        // Detail and editor controllers hold a snapshot returned in the previous language.
        // Leave the active language/settings flow in place, and discard hidden snapshots so
        // returning to another tab can only render freshly negotiated content.
        if tab != .profile {
          (controller as? UINavigationController)?.popToRootViewController(animated: false)
        }
      }
      self.assistantOverlay?.refreshLanguage()
    }.store(in: &subscriptions)
  }

  func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
    assistantOverlay?.primaryPageChanged()
  }

  private func openPendingMealSurface() {
    guard let route = QFMealSurfaceNavigation.shared.pending else { return }
    if route.planID != nil && app.user == nil {
      guard let navigation = selectedViewController as? UINavigationController else { return }
      if showingMealLogin, navigation.viewControllers.contains(where: { $0 is QFLoginViewController }) { return }
      showingMealLogin = true
      let login = QFLoginViewController(app: app) { [weak self, weak navigation] in
        self?.showingMealLogin = false
        navigation?.popViewController(animated: false)
        self?.openPendingMealSurface()
      }
      login.hidesBottomBarWhenPushed = true
      navigation.pushViewController(login, animated: true)
      return
    }
    QFMealSurfaceNavigation.shared.consume()
    if let id = route.planID { openPlanReminder(plannedMealID: id) }
    else if let index = QFTab.allCases.firstIndex(of: .plan) {
      selectedIndex = index
      (viewControllers?[index] as? UINavigationController)?.popToRootViewController(animated: false)
    }
  }

  private func openPlanReminder(plannedMealID: String) {
    guard app.user != nil else {
      QFOperationHUD.toast(
        app.text("请先登录后查看这条计划提醒。", "Sign in to view this plan reminder."), in: view)
      return
    }
    guard let index = QFTab.allCases.firstIndex(of: .plan),
      let navigation = viewControllers?[index] as? UINavigationController,
      let plan = navigation.viewControllers.first as? QFPlanViewController
    else { return }
    selectedIndex = index
    navigation.popToRootViewController(animated: false)
    plan.openRemoteReminder(plannedMealID: plannedMealID)
  }

  private func showLogin() {
    guard let navigation = selectedViewController as? UINavigationController else { return }
    let controller = QFLoginViewController(app: app) { [weak navigation] in
      navigation?.popViewController(animated: true)
    }
    controller.hidesBottomBarWhenPushed = true
    navigation.pushViewController(controller, animated: true)
  }

#if DEBUG
  func debugVerifyPlanReminder(plannedMealID: String) async throws -> [String: Any] {
    guard let overlay = assistantOverlay, let planIndex = QFTab.allCases.firstIndex(of: .plan),
      let nav = viewControllers?[planIndex] as? UINavigationController,
      let plan = nav.viewControllers.first as? QFPlanViewController else {
      throw NSError(domain: "PlanReminderUIUnavailable", code: 1)
    }
    selectedIndex = 0
    overlay.primaryPageChanged()
    overlay.debugRefreshMealReminder()
    let deadline = Date().addingTimeInterval(25)
    while !overlay.debugMealReminderVisible(planID: plannedMealID), Date() < deadline {
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    guard overlay.debugMealReminderVisible(planID: plannedMealID) else {
      throw NSError(domain: "PlanReminderNotVisibleOnHome", code: 2)
    }
    overlay.debugActivateMealReminder()
    let routeDeadline = Date().addingTimeInterval(25)
    while !plan.debugDisplayedPlanIDs.contains(plannedMealID), Date() < routeDeadline {
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    guard selectedIndex == planIndex, plan.debugDisplayedPlanIDs.contains(plannedMealID) else {
      throw NSError(domain: "PlanReminderTapDidNotOpenPlan", code: 3)
    }
    let displayedDate = plan.debugDisplayedPlanDate ?? ""
    selectedIndex = 0
    overlay.primaryPageChanged()
    view.layoutIfNeeded()
    try await Task.sleep(nanoseconds: 500_000_000)
    guard overlay.debugMealReminderVisible(planID: plannedMealID), let scene = view.window?.windowScene else {
      throw NSError(domain: "PlanReminderNotRestoredOnHome", code: 4)
    }
    let windows = scene.windows.filter { !$0.isHidden && $0.alpha > 0 }.sorted { $0.windowLevel < $1.windowLevel }
    let image = UIGraphicsImageRenderer(bounds: view.window!.bounds).image { context in
      for window in windows {
        context.cgContext.saveGState()
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        context.cgContext.restoreGState()
      }
    }
    let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("plan-reminder-home-preview.png")
    try image.pngData()?.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    return ["homeReminderVisible": true, "tapOpenedExistingPlanPage": true,
      "displayedPlanDate": displayedDate, "returnedHomeReminderVisible": true,
      "text": overlay.debugMealReminderText, "previewFile": path.lastPathComponent]
  }
#endif
}

#if DEBUG
@MainActor
enum QFPlanReminderPresentationCheck {
  static func verify(app: QFAppSession, plannedMealID: String) async throws -> [String: Any] {
    func mainTabs(in controller: UIViewController) -> QFMainTabViewController? {
      if let main = controller as? QFMainTabViewController { return main }
      for child in controller.children { if let main = mainTabs(in: child) { return main } }
      return nil
    }
    for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
      for window in scene.windows where !window.isHidden {
        if let root = window.rootViewController, let main = mainTabs(in: root) {
          return try await main.debugVerifyPlanReminder(plannedMealID: plannedMealID)
        }
      }
    }
    throw NSError(domain: "PlanReminderMainPageUnavailable", code: 5)
  }
}
#endif

private enum QFRemoteNotificationRoute {
  static func plannedMealID(from notification: Notification) -> String? {
    // Foreground presentation and silent callbacks deliberately omit this field. Only a user tap
    // may change the selected tab or issue the detail request.
    guard notification.userInfo?["actionIdentifier"] as? String
      == UNNotificationDefaultActionIdentifier,
      let payload = notification.userInfo?["payload"]
    else { return nil }
    return plannedMealID(in: payload, depth: 0)
  }

  static func isAssistantNudge(from notification: Notification) -> Bool {
    guard notification.userInfo?["actionIdentifier"] as? String == UNNotificationDefaultActionIdentifier,
      let payload = notification.userInfo?["payload"] else { return false }
    return containsAssistantNudge(in: payload, depth: 0)
  }

  private static func containsAssistantNudge(in value: Any, depth: Int) -> Bool {
    guard depth <= 4 else { return false }
    if let text = value as? String, let data = text.data(using: .utf8),
      let decoded = try? JSONSerialization.jsonObject(with: data) {
      return containsAssistantNudge(in: decoded, depth: depth + 1)
    }
    let dictionary: [String: Any]
    if let value = value as? [String: Any] { dictionary = value }
    else if let value = value as? [AnyHashable: Any] {
      dictionary = value.reduce(into: [String: Any]()) { result, item in
        if let key = item.key as? String { result[key] = item.value }
      }
    } else if let values = value as? [Any] {
      return values.contains { containsAssistantNudge(in: $0, depth: depth + 1) }
    } else { return false }
    if dictionary["type"] as? String == "ASSISTANT_NUDGE" { return true }
    return ["payload", "transmission", "data", "extras", "aps"].contains {
      guard let nested = dictionary[$0] else { return false }
      return containsAssistantNudge(in: nested, depth: depth + 1)
    }
  }

  private static func plannedMealID(in value: Any, depth: Int) -> String? {
    guard depth <= 4 else { return nil }
    if let text = value as? String,
      let data = text.data(using: .utf8),
      let decoded = try? JSONSerialization.jsonObject(with: data)
    {
      return plannedMealID(in: decoded, depth: depth + 1)
    }
    if let values = value as? [Any] {
      return values.lazy.compactMap { plannedMealID(in: $0, depth: depth + 1) }.first
    }
    let dictionary: [String: Any]
    if let value = value as? [String: Any] {
      dictionary = value
    } else if let value = value as? [AnyHashable: Any] {
      var normalized: [String: Any] = [:]
      for (key, nested) in value {
        if let key = key as? String { normalized[key] = nested }
      }
      dictionary = normalized
    } else {
      return nil
    }
    if dictionary["type"] as? String == "PLAN_REMINDER",
      let id = dictionary["plannedMealId"] as? String,
      UUID(uuidString: id) != nil
    {
      return id.lowercased()
    }
    for key in ["payload", "transmission", "data", "extras", "aps"] {
      if let nested = dictionary[key],
        let id = plannedMealID(in: nested, depth: depth + 1)
      {
        return id
      }
    }
    return nil
  }
}

private final class QFTabButton: UIButton {
  private let icon = UIImageView()
  private let caption = UILabel()

  init(tab: QFTab) {
    super.init(frame: .zero)
    accessibilityIdentifier = "tab.\(tab.rawValue)"
    accessibilityLabel = tab.title
    isAccessibilityElement = true
    icon.image = UIImage(systemName: tab.symbol)
    icon.contentMode = .scaleAspectFit
    caption.text = tab.title
    caption.font = .systemFont(ofSize: 11, weight: .medium)
    caption.textAlignment = .center
    let stack = QFUI.stack([icon, caption], spacing: 4)
    stack.alignment = .center
    stack.isUserInteractionEnabled = false
    stack.isAccessibilityElement = false
    stack.accessibilityElementsHidden = true
    addSubview(stack)
    stack.snp.makeConstraints {
      $0.center.equalToSuperview()
      $0.leading.trailing.equalToSuperview()
    }
    icon.snp.makeConstraints { $0.width.height.equalTo(22) }
    updateColor()
  }
  required init?(coder: NSCoder) { nil }
  override var isSelected: Bool { didSet { updateColor() } }
  private func updateColor() {
    let color = isSelected ? QFUI.orange : QFUI.secondary
    icon.tintColor = color
    caption.textColor = color
    accessibilityTraits = isSelected ? [.button, .selected] : [.button]
  }
}

enum QFRuntime {
  static var isUnitTest: Bool {
    #if DEBUG
      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
    #else
      false
    #endif
  }
}
