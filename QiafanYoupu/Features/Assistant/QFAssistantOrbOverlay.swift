import Combine
import SnapKit
import UIKit
import UserNotifications

/// Scene intent is deliberately broader than a single canned gesture. The rig
/// chooses a compatible clip/pose variant at runtime, so the same intent can
/// read differently across conversations and screens.
enum QFAssistantCharacterIntent: Equatable {
  case idle
  case greeting
  case thinking
  case positive
  case sad
  case awkward
  case angry

  static func from(text: String) -> QFAssistantCharacterIntent {
    let value = text.lowercased()
    let words = Set(value.split { !$0.isLetter }.map(String.init))
    func matches(_ phrases: [String], _ tokens: [String]) -> Bool {
      value.containsAny(phrases) || tokens.contains { words.contains($0) }
    }
    if matches(["不好意思", "抱歉", "对不起", "尴尬"], ["sorry", "embarrassed"]) { return .awkward }
    if matches(["难过", "伤心", "哭", "遗憾"], ["sad", "upset", "cry", "crying"]) { return .sad }
    if matches(["生气", "愤怒", "气死", "烦死"], ["angry", "mad", "furious"]) { return .angry }
    if matches(["你好", "嗨", "哈喽"], ["hello", "hi", "hey"]) { return .greeting }
    if matches(["谢谢", "太好了", "喜欢", "开心", "棒"], ["thanks", "great", "love"]) { return .positive }
    return .thinking
  }
}

private extension String {
  func containsAny(_ values: [String]) -> Bool { values.contains { contains($0) } }
}

/// Local-only assistant nudges. Remote Getui delivery remains a separate,
/// opt-in server flow and notification bodies never include private data.
@MainActor
enum QFDigitalAssistantNudgeScheduler {
  private static let enabledPrefix = "qf.assistant.nudges.enabled."

  private static func token(for app: QFAppSession) -> String {
    let scope = app.user?.userId ?? app.contentScope
    return scope.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
  }
  private static func key(for app: QFAppSession) -> String { enabledPrefix + token(for: app) }
  private static func dailyID(for app: QFAppSession) -> String { "qfyp.assistant.daily." + token(for: app) }
  private static func inactiveID(for app: QFAppSession) -> String { "qfyp.assistant.inactive." + token(for: app) }

  static func isEnabled(for app: QFAppSession) -> Bool {
    UserDefaults.standard.bool(forKey: key(for: app))
  }

  static func setEnabled(_ enabled: Bool, for app: QFAppSession, completion: @escaping (Bool) -> Void) {
    if !enabled {
      UserDefaults.standard.set(false, forKey: key(for: app))
      cancel(for: app)
      completion(true)
      return
    }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
      Task { @MainActor in
        guard granted else { completion(false); return }
        UserDefaults.standard.set(true, forKey: key(for: app))
        schedule(for: app)
        completion(true)
      }
    }
  }

  static func recordAppUse(for app: QFAppSession) {
    guard isEnabled(for: app) else { return }
    schedule(for: app)
  }

  private static func schedule(for app: QFAppSession) {
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: [dailyID(for: app), inactiveID(for: app)])

    let daily = UNMutableNotificationContent()
    daily.title = app.text("饮食助手", "Diet assistant")
    daily.body = app.text("今天想吃什么？打开助手一起安排。", "What would you like to eat today? Open the assistant to plan it together.")
    daily.sound = .default
    daily.userInfo = ["type": "ASSISTANT_NUDGE"]
    var components = DateComponents(); components.hour = 9; components.minute = 0
    center.add(UNNotificationRequest(identifier: dailyID(for: app), content: daily,
      trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)))

    let inactive = UNMutableNotificationContent()
    inactive.title = app.text("回来继续规划饮食", "Continue planning your meals")
    inactive.body = app.text("你的饮食助手还在等你，打开看看今天的安排。", "Your diet assistant is ready when you are. Open the app to review today's plan.")
    inactive.sound = .default
    inactive.userInfo = ["type": "ASSISTANT_NUDGE"]
    center.add(UNNotificationRequest(identifier: inactiveID(for: app), content: inactive,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 7 * 24 * 60 * 60, repeats: false)))
  }

  private static func cancel(for app: QFAppSession) {
    UNUserNotificationCenter.current().removePendingNotificationRequests(
      withIdentifiers: [dailyID(for: app), inactiveID(for: app)])
  }
}

/// One non-key window in the host's own scene. Empty space passes touches to
/// the app; only the light orb and its greeting participate.
@MainActor
final class QFAssistantOverlayWindow: UIWindow {
  static let assistantLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
  override var canBecomeKey: Bool { false }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, !QFAssistantOrbLayout.isBackEdge(point, in: bounds),
      let root = rootViewController?.view else { return nil }
    for view in root.subviews.reversed() where !view.isHidden && view.alpha > 0.01 {
      if let hit = view.hitTest(view.convert(point, from: self), with: event) { return hit }
    }
    return nil
  }
}

/// Shared speech treatment for the floating greeting and assistant messages.
/// Text is always complete; the view fades without changing its reading area.
@MainActor
final class QFAssistantOrbSpeechView: UIView {
  private let textLabel = UILabel()
  private let textScrollView: UIScrollView?
  private let gradient = CAGradientLayer()
  private let cornerRadius: CGFloat = 16
  var onContentSizeChanged: (() -> Void)?

  var text: String? {
    get { textLabel.text }
    set {
      textLabel.text = newValue; accessibilityLabel = newValue
      textScrollView?.setContentOffset(.zero, animated: false)
      onContentSizeChanged?()
    }
  }

  init(text: String? = nil, isThinking: Bool = false, scrollable: Bool = false) {
    textScrollView = scrollable ? UIScrollView() : nil
    super.init(frame: .zero)
    isOpaque = false; backgroundColor = .clear
    gradient.colors = [
      UIColor(red: 16.0 / 255, green: 32.0 / 255, blue: 57.0 / 255, alpha: 1).cgColor,
      UIColor(red: 19.0 / 255, green: 62.0 / 255, blue: 72.0 / 255, alpha: 1).cgColor
    ]
    gradient.startPoint = CGPoint(x: 0, y: 0.2)
    gradient.endPoint = CGPoint(x: 1, y: 0.8)
    gradient.cornerRadius = cornerRadius
    layer.insertSublayer(gradient, at: 0)
    let teal = UIColor(red: 7.0 / 255, green: 143.0 / 255, blue: 139.0 / 255, alpha: 1)
    layer.cornerRadius = cornerRadius
    layer.borderWidth = 0.75; layer.borderColor = teal.withAlphaComponent(0.4).cgColor
    layer.shadowColor = teal.cgColor
    layer.shadowOpacity = 0.1; layer.shadowRadius = 6; layer.shadowOffset = .zero
    textLabel.font = isThinking
      ? UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .italicSystemFont(ofSize: 14))
      : .preferredFont(forTextStyle: .subheadline)
    textLabel.adjustsFontForContentSizeCategory = true
    textLabel.textColor = UIColor(red: 214.0 / 255, green: 245.0 / 255, blue: 240.0 / 255, alpha: isThinking ? 0.85 : 1)
    textLabel.numberOfLines = 0; textLabel.textAlignment = .left
    textLabel.lineBreakMode = .byWordWrapping
    textLabel.isAccessibilityElement = false
    if let scroll = textScrollView {
      scroll.contentInsetAdjustmentBehavior = .never
      scroll.scrollsToTop = false; scroll.showsHorizontalScrollIndicator = false
      addSubview(scroll)
      scroll.snp.makeConstraints { $0.edges.equalToSuperview() }
      scroll.addSubview(textLabel)
      textLabel.snp.makeConstraints {
        $0.edges.equalTo(scroll.contentLayoutGuide).inset(UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))
        $0.width.greaterThanOrEqualTo(0)
        // A fully occluded/zero-width viewport must not require a negative label width.
        $0.width.equalTo(scroll.frameLayoutGuide.snp.width).offset(-28).priority(999)
      }
    } else {
      addSubview(textLabel)
      textLabel.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)) }
    }
    isAccessibilityElement = true; accessibilityTraits = .staticText
    self.text = text
  }
  required init?(coder: NSCoder) { nil }

  func fittingSize(in maximumSize: CGSize) -> CGSize {
    let textSize = textLabel.sizeThatFits(CGSize(width: max(1, maximumSize.width - 28), height: .greatestFiniteMagnitude))
    return CGSize(width: min(maximumSize.width, ceil(textSize.width) + 28),
      height: min(maximumSize.height, ceil(textSize.height) + 24))
  }

  func waitForScrolling(before tap: UITapGestureRecognizer) {
    if let scroll = textScrollView { tap.require(toFail: scroll.panGestureRecognizer) }
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
      onContentSizeChanged?()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin(); CATransaction.setDisableActions(true)
    gradient.frame = bounds
    layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).cgPath
    CATransaction.commit()
  }
}

@MainActor
final class QFDigitalAssistantOverlay {
  private weak var host: UIViewController?
  private weak var app: QFAppSession?
  private let hasBusinessAccess: () -> Bool
  private func accessibilityHint(_ app: QFAppSession) -> String {
    #if DEBUG
    return app.text("与助手交流计划、食材和做菜问题", "Chat about plans, ingredients and cooking")
    #else
    return app.text("管理主动语音并查看餐次提醒", "Manage proactive speech and view meal reminders")
    #endif
  }
  private var proactiveSpeech: QFProactiveSpeechController?
  private var proactiveBubbleID: UUID?
  private let button = UIButton(type: .custom)
  private let mascotView: QFAssistantCharacterView
  private let greetingBubble = QFAssistantOrbSpeechView(scrollable: true)
  private let overlayController = UIViewController()
  private var overlayWindow: QFAssistantOverlayWindow?
  private lazy var orbPan = QFAssistantOrbLayout.makePanRecognizer(target: self, action: #selector(moveOrb(_:)))
  private var orbRelativePosition: CGPoint?
  private var applyingOrbLayout = false
  private var lastOrbFrame: CGRect?
  private var lastBubbleFrame: CGRect?
  // One conversation per scene: dismissing a page does not destroy its generation.
  private var conversationNavigation: UINavigationController?
  private var greetingTask: Task<Void, Never>?
  private var greetingPresentationID = UUID()
  private var shouldGreetOnAppear = true
  private var isVisible = false
  private var hasEnteredBackground = false
  private var keyboardIsVisible = false
  private var observers: [NSObjectProtocol] = []
  private let mealReminderService = QFNextMealReminderService()
  private var mealReminder: QFNextMealReminderSnapshot?
  private var mealReminderTask: Task<Void, Never>?
  private var mealReminderTimer: Task<Void, Never>?
  private var mealReminderRequest = UUID()
  private var mealReminderLoadedAt: Date?
  private var showingMealReminder = false
  private var reminderSubscriptions = Set<AnyCancellable>()
  var onOpenMealReminder: ((String) -> Void)?


  init(app: QFAppSession, character: QFAssistantCharacterView? = nil,
       hasBusinessAccess: @escaping () -> Bool = { false }) {
    self.app = app; self.hasBusinessAccess = hasBusinessAccess
    mascotView = character ?? QFAssistantCharacterView()
  }

  deinit {
    let navigation = conversationNavigation
    let window = overlayWindow
    let speech = proactiveSpeech
    Task { @MainActor in
      speech?.stop()
      #if DEBUG
      (navigation?.viewControllers.first as? QFDigitalAssistantConversationViewController)?.endScene()
      #endif
      window?.isHidden = true
      window?.rootViewController = nil
      window?.windowScene = nil
    }
    greetingTask?.cancel(); mealReminderTask?.cancel(); mealReminderTimer?.cancel()

    observers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  func attach(to host: UIViewController) {
    guard button.superview == nil else { return }
    self.host = host
    guard let app else { return }
    #if DEBUG
    QFDigitalAssistantNudgeScheduler.recordAppUse(for: app)
    if QFLocalModelViewController.networkEnabled(app) {
      Task { try? await app.touchAssistantNotificationActivity(assistantInteraction: false) }
    }
    #endif

    // Keep the native chat button separate from the passive transparent light orb.
    mascotView.isUserInteractionEnabled = false
    mascotView.isAccessibilityElement = true
    mascotView.accessibilityIdentifier = "assistant.mascot"
    mascotView.accessibilityLabel = app.text("饮食助手光球", "Diet assistant light orb")
    mascotView.snp.removeConstraints()
    mascotView.removeFromSuperview(); mascotView.isHidden = false
    mascotView.onDisplayStateChanged = { [weak self] in self?.updateOrbPresentation() }
    button.backgroundColor = .clear
    button.accessibilityLabel = app.text("打开饮食助手", "Open diet assistant")
    button.accessibilityHint = accessibilityHint(app)
    button.accessibilityIdentifier = "assistant.floating-button"
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.18
    button.layer.shadowRadius = 8
    button.layer.shadowOffset = CGSize(width: 0, height: 4)
    button.addSubview(mascotView)
    button.addTarget(self, action: #selector(open), for: .touchUpInside)
    button.addGestureRecognizer(orbPan)
    let content = QFAssistantOrbContainerView()
    overlayController.view = content
    content.backgroundColor = .clear
    content.isOpaque = false
    content.keyboardLayoutGuide.followsUndockedKeyboard = true
    content.onLayout = { [weak self] in self?.layoutOrb() }
    content.addSubview(button)
    button.snp.makeConstraints {
      $0.left.top.equalToSuperview()
      $0.size.equalTo(QFAssistantOrbLayout.buttonSize)
    }
    mascotView.snp.makeConstraints { $0.edges.equalToSuperview() }

    greetingBubble.isUserInteractionEnabled = true
    greetingBubble.isAccessibilityElement = true
    greetingBubble.accessibilityIdentifier = "assistant.greeting"
    greetingBubble.accessibilityTraits = .button
    let greetingTap = UITapGestureRecognizer(target: self, action: #selector(openGreeting))
    greetingTap.cancelsTouchesInView = false
    greetingBubble.waitForScrolling(before: greetingTap)
    greetingBubble.addGestureRecognizer(greetingTap)
    greetingBubble.onContentSizeChanged = { [weak content] in content?.setNeedsLayout() }
    content.addSubview(greetingBubble)
    greetingBubble.snp.makeConstraints {
      $0.left.top.equalToSuperview()
      $0.width.height.equalTo(0)
    }
    greetingBubble.isHidden = true
    refreshLanguage()
    isVisible = true
    installLifecycleObservers()
    app.$user.dropFirst().map { $0?.userId }.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.refreshProactiveSpeech()
      self?.refreshMealReminderIfNeeded(force: true)
    }.store(in: &reminderSubscriptions)
    app.$planningScope.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.refreshProactiveSpeech()
      self?.refreshMealReminderIfNeeded(force: true)
    }.store(in: &reminderSubscriptions)
    mountWindowIfPossible()
    updateOrbPresentation()
  }

  private func currentOrbLayout() -> QFAssistantOrbLayout {
    let content = overlayController.view!
    let safe = content.safeAreaLayoutGuide.layoutFrame
    // Read current scene-local UIKit guides. The host covers docked keyboards
    // even though this transparent overlay deliberately never becomes key.
    var keyboardFrames = [content.keyboardLayoutGuide.layoutFrame]
    if let hostView = host?.viewIfLoaded {
      keyboardFrames.append(hostView.convert(hostView.keyboardLayoutGuide.layoutFrame, to: content))
    }
    let keyboard = keyboardFrames.filter { !$0.isEmpty && $0.minY < safe.maxY && $0.intersects(safe) }
      .min { $0.minY < $1.minY }
    return QFAssistantOrbLayout(bounds: content.bounds, safeAreaInsets: content.safeAreaInsets, keyboardFrame: keyboard)
  }

  private func layoutOrb() {
    guard !applyingOrbLayout, let content = overlayController.viewIfLoaded,
      content.bounds.width > 0, content.bounds.height > 0 else { return }
    applyingOrbLayout = true
    defer { applyingOrbLayout = false }
    let layout = currentOrbLayout()
    let orb = layout.orbFrame(relativePosition: orbRelativePosition)
    if orbRelativePosition == nil, orb.width > 0, content.window != nil {
      orbRelativePosition = layout.relativePosition(for: orb)
    }
    if lastOrbFrame != orb {
      button.snp.updateConstraints {
        $0.left.equalToSuperview().offset(orb.minX); $0.top.equalToSuperview().offset(orb.minY)
        $0.width.equalTo(orb.width); $0.height.equalTo(orb.height)
      }
      lastOrbFrame = orb
    }
    let bubble = layout.bubblePlacement(near: orb, sizeThatFits: { [greetingBubble] in greetingBubble.fittingSize(in: $0) })?.frame ?? .zero
    greetingBubble.accessibilityElementsHidden = bubble.isEmpty
    if lastBubbleFrame != bubble {
      greetingBubble.snp.updateConstraints {
        $0.left.equalToSuperview().offset(bubble.minX); $0.top.equalToSuperview().offset(bubble.minY)
        $0.width.equalTo(bubble.width); $0.height.equalTo(bubble.height)
      }
      lastBubbleFrame = bubble
    }
    content.layoutIfNeeded()
  }

  @objc private func moveOrb(_ pan: UIPanGestureRecognizer) {
    guard let content = overlayController.viewIfLoaded else { return }
    switch pan.state {
    case .began:
      // UIKit cancels the original UIControl touch; never turn a drag into chat.
      button.cancelTracking(with: nil)
      pan.setTranslation(.zero, in: content)
    case .changed, .ended:
      let translation = pan.translation(in: content)
      let layout = currentOrbLayout()
      let frame = layout.orbFrame(center: CGPoint(x: button.center.x + translation.x, y: button.center.y + translation.y))
      orbRelativePosition = layout.relativePosition(for: frame)
      pan.setTranslation(.zero, in: content)
      layoutOrb()
    default: break
    }
  }

  private func updateOrbPresentation() {
    button.isHidden = !mascotView.isAvailableForDisplay || !hasBusinessAccess()
    if mascotView.isReadyForDisplay {
      hostDidAppear()

    }
    else {
      hideGreeting()

    }
  }

  func businessAccessDidChange() {
    updateOrbPresentation()
    if !hasBusinessAccess() {
      hideGreeting(); invalidateMealReminder()
    }
    refreshProactiveSpeech()
  }

  private func mountWindowIfPossible() {
    guard overlayWindow == nil, let hostWindow = host?.viewIfLoaded?.window, let scene = hostWindow.windowScene else { return }
    let window = QFAssistantOverlayWindow(windowScene: scene)
    window.frame = hostWindow.frame
    window.backgroundColor = .clear
    window.isOpaque = false
    window.windowLevel = QFAssistantOverlayWindow.assistantLevel
    window.overrideUserInterfaceStyle = hostWindow.overrideUserInterfaceStyle
    window.rootViewController = overlayController
    overlayWindow = window
    window.isHidden = false
    overlayController.view.setNeedsLayout()
    startIdleAnimation()
  }

  private func startIdleAnimation() {
    mascotView.layer.removeAllAnimations()
    mascotView.beginRigAnimation()
    refreshProactiveSpeech()

  }

  private func installLifecycleObservers() {
    let center = NotificationCenter.default
    for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in self?.overlayController.viewIfLoaded?.setNeedsLayout() }
      })
    }
    for name in [Notification.Name("qf.planningReminderDataDidChange"), .qfLocalSettingsDidChange, UIApplication.significantTimeChangeNotification, .NSCalendarDayChanged] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        Task { @MainActor [weak self] in
          guard let self else { return }
          if let scope = note.userInfo?["scope"] as? String, scope != self.app?.contentScope { return }
          self.refreshProactiveSpeech()
          if note.userInfo?["proactiveSpeech"] != nil { return }
          self.refreshMealReminderIfNeeded(force: true)
        }
      })
    }
    observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.hasEnteredBackground = true
        self.proactiveSpeech?.refresh(in: nil)
        self.invalidateMealReminder()
        self.hideGreeting()

        self.mascotView.layer.removeAllAnimations()
        self.mascotView.stopRigAnimation()
      }
    })
    observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.isVisible else { return }
        self.startIdleAnimation()
        if self.hasEnteredBackground {
          self.shouldGreetOnAppear = true
          self.hasEnteredBackground = false
        }
        self.refreshMealReminderIfNeeded(force: true)
        DispatchQueue.main.async { [weak self] in self?.hostDidAppear() }
      }
    })
    observers.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.keyboardIsVisible = true; self?.hideGreeting()
      }
    })
    observers.append(center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.keyboardIsVisible = false; self?.hostDidAppear()
      }
    })
  }

  private var showsPrimaryPage: Bool {
    guard let tabs = host as? UITabBarController,
      let navigation = tabs.selectedViewController as? UINavigationController else { return false }
    return navigation.viewControllers.count == 1
  }

  /// Called from the tab controller's viewDidAppear so the greeting happens after the first
  /// frame is visible, rather than while the root view is still being installed.
  func hostDidAppear() {
    mountWindowIfPossible()
    refreshProactiveSpeech()
    guard hasBusinessAccess(), isVisible, let host, host.viewIfLoaded?.window != nil,
      host.presentedViewController == nil, mascotView.isReadyForDisplay,
      showsPrimaryPage, !keyboardIsVisible,
      UIApplication.shared.applicationState == .active,
      overlayWindow?.windowScene?.activationState == .foregroundActive else { return }
    refreshMealReminderIfNeeded()
    if showsRecipeHome, mealReminder != nil { presentMealReminderIfPossible(); return }
    if shouldGreetOnAppear {
      shouldGreetOnAppear = false
      showGreeting()
    }

  }

  func refreshLanguage() {
    guard let app else { return }
    button.accessibilityLabel = app.text("打开饮食助手", "Open diet assistant")
    button.accessibilityHint = accessibilityHint(app)
    mascotView.accessibilityLabel = app.text("饮食助手光球", "Diet assistant light orb")
    mascotView.interfaceLanguage = QFInterfaceLanguage.normalized(app.interfaceLanguage)
    refreshProactiveSpeech()
    refreshMealReminderIfNeeded(force: true)
    if !greetingBubble.isHidden {
      greetingBubble.text = greetingText()
    }
  }

  func ensureOnTop() {
    guard hasBusinessAccess(), isVisible else { return }
    mountWindowIfPossible()
    refreshProactiveSpeech()
    overlayWindow?.windowLevel = QFAssistantOverlayWindow.assistantLevel
    let content = overlayController.view!
    content.bringSubviewToFront(greetingBubble)
    content.bringSubviewToFront(button)
    if showingMealReminder && !showsRecipeHome { clearMealReminderPresentation() }
    else if showsRecipeHome && !showingMealReminder {
      refreshMealReminderIfNeeded()
      presentMealReminderIfPossible()
    }
  }

  private var showsRecipeHome: Bool {
    guard let tabs = host as? UITabBarController else { return false }
    return tabs.selectedIndex == 0 && showsPrimaryPage
  }

  func primaryPageChanged() {
    if !showsRecipeHome, showingMealReminder { clearMealReminderPresentation() }
    hostDidAppear()
  }

  private func invalidateMealReminder() {
    mealReminderRequest = UUID(); mealReminderTask?.cancel(); mealReminderTask = nil
    mealReminderTimer?.cancel(); mealReminderTimer = nil
    mealReminderService.cancel(); mealReminder = nil; mealReminderLoadedAt = nil
    clearMealReminderPresentation()
  }

  private func clearMealReminderPresentation() {
    guard showingMealReminder else { return }
    showingMealReminder = false
    greetingTask?.cancel(); greetingTask = nil; greetingPresentationID = UUID()
    greetingBubble.isHidden = true; greetingBubble.text = nil; greetingBubble.alpha = 1
    greetingBubble.accessibilityIdentifier = "assistant.greeting"
    greetingBubble.accessibilityHint = nil
  }

  private func refreshMealReminderIfNeeded(force: Bool = false) {
    invalidateMealReminder()
    QFMealSurfaceCoordinator.shared.refresh(force: force)
  }

  private func presentMealReminderIfPossible() {
    guard let app, let snapshot = mealReminder,
      snapshot.scope == app.contentScope, snapshot.householdID == app.planningHouseholdID,
      snapshot.language == app.interfaceLanguage, snapshot.scheduledAt > Date(),
      showsRecipeHome, !keyboardIsVisible, isVisible, mascotView.isReadyForDisplay,
      host?.presentedViewController == nil, UIApplication.shared.applicationState == .active else { return }

    greetingTask?.cancel(); greetingTask = nil; greetingPresentationID = UUID()
    showingMealReminder = true
    greetingBubble.text = Self.mealReminderText(snapshot, app: app)
    greetingBubble.accessibilityIdentifier = "assistant.meal-reminder"
    greetingBubble.accessibilityHint = app.text("查看这餐计划和备菜", "View this meal plan and preparation")
    greetingBubble.alpha = 1; greetingBubble.isHidden = false
    overlayController.view.layoutIfNeeded()
  }

  static func mealReminderText(_ snapshot: QFNextMealReminderSnapshot, app: QFAppSession) -> String {
    func preview(_ names: [String], limit: Int = 3) -> String {
      var seen = Set<String>()
      let values = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
      let formatter = ListFormatter()
      formatter.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
      let first = formatter.string(from: Array(values.prefix(limit))) ?? values.prefix(limit).joined(separator: ", ")
      return values.count > limit ? app.format("%@，另%d项", "%@ and %d more", first, values.count - limit) : first
    }
    let zone = TimeZone(identifier: snapshot.timezone) ?? .current
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
    let formatter = DateFormatter(); formatter.timeZone = zone; formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
    let today = formatter.string(from: Date())
    let tomorrow = formatter.string(from: calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date())
    let day = snapshot.date == today ? app.text("今天", "Today") : snapshot.date == tomorrow ? app.text("明天", "Tomorrow") : snapshot.date
    let meal: String
    switch snapshot.meal {
    case "BREAKFAST": meal = app.text("早餐", "Breakfast")
    case "LUNCH": meal = app.text("午餐", "Lunch")
    case "DINNER": meal = app.text("晚餐", "Dinner")
    default: meal = app.text("加餐", "Snack")
    }
    let titles = snapshot.plans.map { $0.contentAvailable ? ($0.title ?? app.text("菜谱内容暂不可用", "Recipe content unavailable")) : app.text("菜谱内容暂不可用", "Recipe content unavailable") }
    var lines = [app.format("%@%@准备吃：%@", "%@ %@ planned: %@", day, meal, preview(titles, limit: 2))]
    if snapshot.availabilityStatus != "SUCCEEDED" {
      lines.append(app.text("食材与库存暂时无法读取", "Ingredients and stock are temporarily unavailable"))
    } else {
      let required = preview(snapshot.materials.map(\.name))
      lines.append(app.format("所需食材：%@", "Ingredients needed: %@", required.isEmpty ? app.text("用料待核对", "Ingredients need checking") : required))
      let owned = preview(snapshot.materials.filter {
        $0.status != "UNCONFIRMED" && (Decimal(string: $0.availableQuantity ?? "", locale: Locale(identifier: "en_US_POSIX")) ?? 0) > 0
      }.map(\.name))
      let unknown = snapshot.materials.isEmpty || snapshot.materials.contains { $0.status == "UNCONFIRMED" || $0.availableQuantity == nil }
      let stock = owned.isEmpty ? (unknown ? app.text("库存待核对", "Stock needs checking") : app.text("未找到可用库存", "No usable stock found")) : owned
      lines.append(app.format("家里已有：%@", "At home: %@", stock))
      if !owned.isEmpty && unknown { lines.append(app.text("部分用量或库存待核对", "Some quantities or stock need checking")) }
    }
    lines.append(app.text("点击查看计划与备菜", "Tap to view plans and preparation"))
    return lines.joined(separator: "\n")
  }

  @objc private func openGreeting() {
    if showingMealReminder, let app, let snapshot = mealReminder,
      snapshot.scope == app.contentScope, snapshot.householdID == app.planningHouseholdID,
      snapshot.language == app.interfaceLanguage, let id = snapshot.plans.first?.id {
      hideGreeting(); onOpenMealReminder?(id)
    } else { open() }
  }

#if DEBUG
  func debugRefreshMealReminder() { refreshMealReminderIfNeeded(force: true) }
  func debugActivateMealReminder() { openGreeting() }
  func debugMealReminderVisible(planID: String) -> Bool {
    showingMealReminder && showsRecipeHome && mealReminder?.plans.contains(where: { $0.id == planID }) == true
      && !greetingBubble.isHidden && greetingBubble.alpha > 0.99 && greetingBubble.window?.isHidden == false
      && greetingBubble.bounds.height > 0 && greetingBubble.accessibilityIdentifier == "assistant.meal-reminder"
  }
  var debugMealReminderText: String { greetingBubble.text ?? "" }
#endif

  private func refreshProactiveSpeech() {
    if proactiveSpeech == nil {
      proactiveSpeech = QFProactiveSpeechController(context: { [weak self] in
        guard let self, let app = self.app, app.user != nil, self.isVisible,
          self.host?.viewIfLoaded?.window != nil, self.hasBusinessAccess(),
          self.mascotView.isReadyForDisplay,
          QFProactiveSpeechPreferences.isEnabled(scope: app.contentScope) else { return nil }
        let language = QFInterfaceLanguage.normalized(app.interfaceLanguage)
        guard let text = QFProactiveSpeechContext.greeting(for: language) else { return nil }
        return QFProactiveSpeechContext(binding: app.contentScope + "/" + language.rawValue,
          language: language, text: text)
      }, canSpeak: { [weak self] in
        guard let self else { return false }
        return self.hasBusinessAccess() && self.showsPrimaryPage && !self.keyboardIsVisible
          && !self.showingMealReminder && self.host?.presentedViewController == nil
          && self.overlayWindow?.isHidden == false
      }, onStart: { [weak self] text in
        guard let self else { return }
        self.showMessage(text, holdSeconds: 60)
        self.proactiveBubbleID = self.greetingPresentationID
      }, onEnd: { [weak self] in
        guard let self, let id = self.proactiveBubbleID else { return }
        self.proactiveBubbleID = nil
        if self.greetingPresentationID == id { self.hideGreeting() }
      })
    }
    let scene = isVisible && overlayWindow?.isHidden == false ? overlayWindow?.windowScene : nil
    proactiveSpeech?.refresh(in: scene)
  }

  private func greetingText() -> String {
    app?.text("今天想吃什么？打开助手一起安排。", "What would you like to eat today? Open the assistant to plan it together.") ?? "What would you like to eat today? Open the assistant to plan it together."
  }

  private func showGreeting() {

    showMessage(greetingText(), holdSeconds: 5.5)
  }

  private func showMessage(_ text: String, holdSeconds: Double) {
    guard let host, host.presentedViewController == nil, mascotView.isReadyForDisplay else { return }
    greetingTask?.cancel()
    clearMealReminderPresentation()
    let presentationID = UUID()
    greetingPresentationID = presentationID
    greetingBubble.text = text
    greetingBubble.alpha = 0
    greetingBubble.isHidden = false
    overlayController.view.layoutIfNeeded()
    mascotView.playGreeting()
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.15 : 0.65, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: { [weak self] in
      self?.greetingBubble.alpha = 1
    })
    greetingTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
      guard !Task.isCancelled, self?.greetingPresentationID == presentationID else { return }
      self?.hideGreeting()
    }
  }



  private func hideGreeting() {
    greetingTask?.cancel(); greetingTask = nil
    guard !greetingBubble.isHidden else { return }
    let presentationID = UUID()
    greetingPresentationID = presentationID
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.15 : 0.4, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: { [weak self] in self?.greetingBubble.alpha = 0 }, completion: { [weak self] finished in
      guard finished, self?.greetingPresentationID == presentationID else { return }
      self?.greetingBubble.isHidden = true
    })
  }

  @objc private func open() {
    guard QFAssistantOrbLayout.allowsActivation(panState: orbPan.state) else { return }
    presentConversation()
  }

  /// Opens the assistant when an opted-in remote nudge is tapped.
  func presentConversation() {
    #if DEBUG
    guard hasBusinessAccess(), let host, let app else { return }
    var presenter = host
    while let presented = presenter.presentedViewController {
      if presented is QFDigitalAssistantConversationViewController || (presented as? UINavigationController)?.viewControllers.first is QFDigitalAssistantConversationViewController { return }
      presenter = presented
    }
    guard presenter.viewIfLoaded?.window != nil else { return }
    guard app.user != nil else {
      QFOperationHUD.toast(app.text("请先登录后使用饮食助手", "Sign in to use the diet assistant"), in: presenter.view)
      return
    }
    hideGreeting()

    mascotView.layer.removeAllAnimations()
    mascotView.playExcited()
    QFDigitalAssistantNudgeScheduler.recordAppUse(for: app)
    if QFLocalModelViewController.networkEnabled(app) {
      Task { try? await app.touchAssistantNotificationActivity(assistantInteraction: true) }
    }
    let navigation: UINavigationController
    let controller: QFDigitalAssistantConversationViewController
    if let existing = conversationNavigation, let chat = existing.viewControllers.first as? QFDigitalAssistantConversationViewController {
      navigation = existing; controller = chat
      existing.popToRootViewController(animated: false)
    } else {
      controller = QFDigitalAssistantConversationViewController(app: app)
      navigation = UINavigationController(rootViewController: controller)
      conversationNavigation = navigation
    }
    controller.tabNavigationHost = host as? UITabBarController ?? host.tabBarController
    controller.onCharacterIntent = { [weak self] intent in
      self?.mascotView.playSceneAction(intent)
    }
    controller.onDismiss = { [weak self] in
      self?.overlayWindow?.isHidden = false
      self?.startIdleAnimation()
      self?.ensureOnTop()
      self?.hostDidAppear()
    }
    navigation.modalPresentationStyle = .fullScreen
    overlayWindow?.isHidden = true
    proactiveSpeech?.refresh(in: nil)
    presenter.present(navigation, animated: true)
    #else
    guard hasBusinessAccess(), let host, let app, app.user != nil,
      host.presentedViewController == nil else { return }
    hideGreeting()
    let page = QFCoreAssistantViewController(app: app)
    page.onDismiss = { [weak self] in
      self?.overlayWindow?.isHidden = false
      self?.hostDidAppear()
    }
    let navigation = UINavigationController(rootViewController: page)
    navigation.setNavigationBarHidden(true, animated: false)
    navigation.modalPresentationStyle = .fullScreen
    overlayWindow?.isHidden = true
    proactiveSpeech?.refresh(in: nil)
    host.present(navigation, animated: true)
    #endif
  }

}



#if !DEBUG
@MainActor
private final class QFCoreAssistantViewController: QFProfileContentController {
  var onDismiss: (() -> Void)?
  init(app: QFAppSession) { super.init(app: app, title: app.text("饮食助手", "Diet assistant")) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    bodyStack.beginUpdates()
    bodyStack.row("availability", version: app.interfaceLanguage) { [self] in
      QFTabUI.card(QFSettingsPageUI.label(app.text(
        "本次订阅包含做饭工具和主动语音，云端问答暂不可用。",
        "Your subscription includes cooking tools and proactive speech. Cloud chat is currently unavailable."),
        size: 15), padding: 24)
    }
    bodyStack.row("speech", version: app.contentScope) { [self] in
      let toggle = UISwitch()
      toggle.isOn = QFProactiveSpeechPreferences.isEnabled(scope: app.contentScope)
      toggle.accessibilityLabel = app.text("主动语音（每5分钟）", "Proactive speech (every 5 minutes)")
      toggle.accessibilityIdentifier = "assistant.proactive-speech"
      let scope = app.contentScope
      toggle.addAction(UIAction { [weak app, weak toggle] _ in
        guard let app, app.contentScope == scope else { return }
        guard let toggle else { return }
        QFProactiveSpeechPreferences.setEnabled(toggle.isOn, scope: scope)
      }, for: .valueChanged)
      let row = QFTabUI.stack([
        QFSettingsPageUI.label(app.text("主动语音（每5分钟）", "Proactive speech (every 5 minutes)"), size: 15),
        toggle
      ], axis: .horizontal, spacing: 16)
      row.alignment = .center
      return QFTabUI.card(row, padding: 24)
    }
    bodyStack.endUpdates()
  }
  override func close() {
    super.close()
    onDismiss?()
  }
}
#endif
