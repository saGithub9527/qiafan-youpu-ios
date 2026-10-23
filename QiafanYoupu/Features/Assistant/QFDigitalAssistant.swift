@preconcurrency import AVFoundation
import Combine
import PhotosUI
import SceneKit
import SnapKit
import Speech
import SafariServices
import UIKit
import UserNotifications
@preconcurrency import Vision

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
private enum QFDigitalAssistantNudgeScheduler {
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

@MainActor
enum QFAssistantFaceSelection: String, CaseIterable {
  case neutral, smile, surprised, thinking, sad, angry, shy, eyesClosed, leftEyeClosed, rightEyeClosed, mouthOpen

  func title(language: QFInterfaceLanguage) -> String {
    switch self {
    case .neutral: return language.text(chinese: "自然", english: "Neutral")
    case .smile: return language.text(chinese: "微笑", english: "Smile")
    case .surprised: return language.text(chinese: "惊讶", english: "Surprised")
    case .thinking: return language.text(chinese: "思考", english: "Thinking")
    case .sad: return language.text(chinese: "难过", english: "Sad")
    case .angry: return language.text(chinese: "生气", english: "Angry")
    case .shy: return language.text(chinese: "害羞", english: "Shy")
    case .eyesClosed: return language.text(chinese: "闭眼", english: "Eyes closed")
    case .leftEyeClosed: return language.text(chinese: "左眼闭合", english: "Left eye closed")
    case .rightEyeClosed: return language.text(chinese: "右眼闭合", english: "Right eye closed")
    case .mouthOpen: return language.text(chinese: "张嘴", english: "Mouth open")
    }
  }

  var emotion: QFAssistantRigView.QFAssistantEmotion {
    switch self {
    case .smile: return .happy
    case .surprised: return .excited
    case .thinking: return .thinking
    case .sad: return .sad
    case .angry: return .angry
    case .shy: return .shy
    default: return .calm
    }
  }
  var holdsEyes: Bool { [.eyesClosed, .leftEyeClosed, .rightEyeClosed].contains(self) }
}

extension QFAssistantRigView.QFAssistantPose {
  func title(language: QFInterfaceLanguage) -> String {
    switch self {
    case .welcome: return language.text(chinese: "欢迎", english: "Welcome")
    case .wave: return language.text(chinese: "挥手", english: "Wave")
    case .thinking: return language.text(chinese: "思考", english: "Thinking")
    case .calm: return language.text(chinese: "待机", english: "Idle")
    case .excited: return language.text(chinese: "兴奋", english: "Excited")
    case .sad: return language.text(chinese: "低落", english: "Downcast")
    case .angry: return language.text(chinese: "生气", english: "Angry")
    case .coverFace: return language.text(chinese: "捂面", english: "Cover face")
    case .flustered: return language.text(chinese: "手足无措", english: "Flustered")
    case .stomp: return language.text(chinese: "跺脚", english: "Stomp")
    }
  }
}

/// One non-key window in the host's own scene. Empty space passes touches to
/// the app; only the light orb and its greeting participate.
@MainActor
final class QFAssistantOverlayWindow: UIWindow {
  static let assistantLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
  override var canBecomeKey: Bool { false }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, let root = rootViewController?.view else { return nil }
    for view in root.subviews.reversed() where !view.isHidden && view.alpha > 0.01 {
      if let hit = view.hitTest(view.convert(point, from: self), with: event) { return hit }
    }
    return nil
  }
}

/// Shared speech treatment for the floating greeting and assistant messages.
/// Text is always complete; the view fades without changing its reading area.
@MainActor
private final class QFAssistantOrbSpeechView: UIView {
  private let textLabel = UILabel()
  private let gradient = CAGradientLayer()
  private let cornerRadius: CGFloat = 16

  var text: String? {
    get { textLabel.text }
    set { textLabel.text = newValue; accessibilityLabel = newValue }
  }

  init(text: String? = nil, isThinking: Bool = false) {
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
    textLabel.isAccessibilityElement = false
    addSubview(textLabel)
    textLabel.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)) }
    isAccessibilityElement = true; accessibilityTraits = .staticText
    self.text = text
  }
  required init?(coder: NSCoder) { nil }

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
  private let button = UIButton(type: .custom)
  private let mascotView: QFAssistantCharacterView
  private let greetingBubble = QFAssistantOrbSpeechView()
  private let overlayController = UIViewController()
  private var overlayWindow: QFAssistantOverlayWindow?
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
  private var mealReminderBinding: QFAgentScope?
  private var showingMealReminder = false
  private var reminderSubscriptions = Set<AnyCancellable>()
  var onOpenMealReminder: ((String) -> Void)?

#if DEBUG
  private var debugMessageTask: Task<Void, Never>?
  private var debugMessageRun = UUID()
  private var debugMessageIndex = Int.random(in: 0..<8)
  private var displayedDebugMessage: Int?
#endif

  init(app: QFAppSession, character: QFAssistantCharacterView? = nil) {
    self.app = app; mascotView = character ?? QFAssistantCharacterView()
  }

  deinit {
    let navigation = conversationNavigation
    let window = overlayWindow
    Task { @MainActor in
      (navigation?.viewControllers.first as? QFDigitalAssistantConversationViewController)?.endScene()
      window?.isHidden = true
      window?.rootViewController = nil
      window?.windowScene = nil
    }
    greetingTask?.cancel(); mealReminderTask?.cancel(); mealReminderTimer?.cancel()
#if DEBUG
    debugMessageTask?.cancel()
#endif
    observers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  func attach(to host: UIViewController) {
    guard button.superview == nil else { return }
    self.host = host
    guard let app else { return }
    QFDigitalAssistantNudgeScheduler.recordAppUse(for: app)
    if QFLocalModelViewController.networkEnabled(app) {
      Task { try? await app.touchAssistantNotificationActivity(assistantInteraction: false) }
    }

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
    button.accessibilityHint = app.text("与助手交流计划、食材和做菜问题", "Chat about plans, ingredients and cooking")
    button.accessibilityIdentifier = "assistant.floating-button"
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.18
    button.layer.shadowRadius = 8
    button.layer.shadowOffset = CGSize(width: 0, height: 4)
    button.addSubview(mascotView)
    button.addTarget(self, action: #selector(open), for: .touchUpInside)
    let content = overlayController.view!
    content.backgroundColor = .clear
    content.isOpaque = false
    content.addSubview(button)
    button.snp.makeConstraints {
      $0.trailing.equalTo(content.safeAreaLayoutGuide).inset(14)
      // Keep the established light-orb position above the existing tab bar.
      $0.bottom.equalTo(content.keyboardLayoutGuide.snp.top).offset(-126)
      $0.size.equalTo(CGSize(width: 92, height: 112))
    }
    mascotView.snp.makeConstraints { $0.edges.equalToSuperview() }

    greetingBubble.isUserInteractionEnabled = true
    greetingBubble.isAccessibilityElement = true
    greetingBubble.accessibilityIdentifier = "assistant.greeting"
    greetingBubble.accessibilityTraits = .button
    let greetingTap = UITapGestureRecognizer(target: self, action: #selector(openGreeting))
    greetingBubble.addGestureRecognizer(greetingTap)
    content.addSubview(greetingBubble)
    greetingBubble.snp.makeConstraints {
      $0.trailing.equalTo(button.snp.leading).offset(-8)
      $0.centerY.equalTo(button.snp.centerY).offset(-12).priority(750)
      $0.bottom.lessThanOrEqualTo(content.keyboardLayoutGuide.snp.top).offset(-126)
      $0.leading.greaterThanOrEqualTo(content.safeAreaLayoutGuide).offset(18)
      $0.width.lessThanOrEqualTo(240)
    }
    greetingBubble.isHidden = true
    refreshLanguage()
    isVisible = true
    installLifecycleObservers()
    app.$user.dropFirst().map { $0?.userId }.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.refreshMealReminderIfNeeded(force: true)
    }.store(in: &reminderSubscriptions)
    app.$planningScope.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.refreshMealReminderIfNeeded(force: true)
    }.store(in: &reminderSubscriptions)
    mountWindowIfPossible()
    updateOrbPresentation()
  }

  private func updateOrbPresentation() {
    button.isHidden = !mascotView.isAvailableForDisplay
    if mascotView.isReadyForDisplay {
      hostDidAppear()
#if DEBUG
      startDebugMessages()
#endif
    }
    else {
      hideGreeting()
#if DEBUG
      stopDebugMessages()
#endif
    }
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
    startIdleAnimation()
  }

  private func startIdleAnimation() {
    mascotView.layer.removeAllAnimations()
    mascotView.beginRigAnimation()
#if DEBUG
    startDebugMessages()
#endif
  }

  private func installLifecycleObservers() {
    let center = NotificationCenter.default
    for name in [Notification.Name("qf.planningReminderDataDidChange"), .qfLocalSettingsDidChange, UIApplication.significantTimeChangeNotification, .NSCalendarDayChanged] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        Task { @MainActor [weak self] in
          guard let self else { return }
          if let scope = note.userInfo?["scope"] as? String, scope != self.app?.contentScope { return }
          self.refreshMealReminderIfNeeded(force: true)
        }
      })
    }
    observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.hasEnteredBackground = true
        self.invalidateMealReminder()
        self.hideGreeting()
#if DEBUG
        self.stopDebugMessages()
#endif
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
    guard isVisible, let host, host.viewIfLoaded?.window != nil,
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
#if DEBUG
    startDebugMessages()
#endif
  }

  func refreshLanguage() {
    guard let app else { return }
    button.accessibilityLabel = app.text("打开饮食助手", "Open diet assistant")
    button.accessibilityHint = app.text("与助手交流计划、食材和做菜问题", "Chat about plans, ingredients and cooking")
    mascotView.accessibilityLabel = app.text("饮食助手光球", "Diet assistant light orb")
    mascotView.interfaceLanguage = QFInterfaceLanguage.normalized(app.interfaceLanguage)
    refreshMealReminderIfNeeded(force: true)
    if !greetingBubble.isHidden {
#if DEBUG
      greetingBubble.text = displayedDebugMessage.map { debugText(at: $0) } ?? greetingText()
#else
      greetingBubble.text = greetingText()
#endif
    }
  }

  func ensureOnTop() {
    guard isVisible else { return }
    mountWindowIfPossible()
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
    mealReminderService.cancel(); mealReminder = nil; mealReminderLoadedAt = nil; mealReminderBinding = nil
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
    guard let app, app.user != nil else { invalidateMealReminder(); return }
    let binding = QFAssistantAgent.scope(app)
    if force || mealReminderBinding != binding { invalidateMealReminder() }
    guard QFLocalSettingsStore.current(scope: app.contentScope).planReminders else { invalidateMealReminder(); return }
    guard showsRecipeHome, UIApplication.shared.applicationState == .active else { return }
    if let loaded = mealReminderLoadedAt, Date().timeIntervalSince(loaded) < 60,
      mealReminder == nil || (mealReminder?.scheduledAt ?? .distantPast) > Date() { return }
    guard mealReminderTask == nil else { return }
    mealReminderBinding = binding
    let request = UUID(); mealReminderRequest = request
    mealReminderTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
      guard let self, !Task.isCancelled, self.mealReminderRequest == request else { return }
      let snapshot = await self.mealReminderService.refresh(app: app)
      guard !Task.isCancelled, self.mealReminderRequest == request,
        QFAssistantAgent.scope(app) == binding else { return }
      self.mealReminderTask = nil; self.mealReminderLoadedAt = Date(); self.mealReminder = snapshot
      if let snapshot {
        self.presentMealReminderIfPossible()
        self.mealReminderTimer?.cancel()
        self.mealReminderTimer = Task { [weak self] in
          let delay = max(0.2, snapshot.scheduledAt.timeIntervalSinceNow + 0.2)
          do { try await Task.sleep(nanoseconds: UInt64(min(delay, 172_800) * 1_000_000_000)) } catch { return }
          self?.refreshMealReminderIfNeeded(force: true)
        }
      } else {
        self.clearMealReminderPresentation()
#if DEBUG
        self.startDebugMessages()
#endif
      }
    }
  }

  private func presentMealReminderIfPossible() {
    guard let app, let snapshot = mealReminder,
      snapshot.scope == app.contentScope, snapshot.householdID == app.planningHouseholdID,
      snapshot.language == app.interfaceLanguage, snapshot.scheduledAt > Date(),
      showsRecipeHome, !keyboardIsVisible, isVisible, mascotView.isReadyForDisplay,
      host?.presentedViewController == nil, UIApplication.shared.applicationState == .active else { return }
#if DEBUG
    stopDebugMessages(); displayedDebugMessage = nil
#endif
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

  private func greetingText() -> String {
    app?.text("今天想吃什么？打开助手一起安排。", "What would you like to eat today? Open the assistant to plan it together.") ?? "What would you like to eat today? Open the assistant to plan it together."
  }

  private func showGreeting() {
#if DEBUG
    displayedDebugMessage = nil
#endif
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

#if DEBUG
  private func startDebugMessages() {
    guard debugMessageTask == nil, !(showsRecipeHome && mealReminder != nil), !QFRuntime.isUnitTest, mascotView.isReadyForDisplay,
      UIApplication.shared.applicationState == .active,
      overlayWindow?.windowScene?.activationState == .foregroundActive,
      host?.presentedViewController == nil else { return }
    let run = UUID(); debugMessageRun = run
    debugMessageTask = Task { [weak self] in
      defer {
        if self?.debugMessageRun == run { self?.debugMessageTask = nil }
      }
      while !Task.isCancelled {
        do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
        guard let self, self.debugMessageRun == run, self.isVisible,
          self.host?.viewIfLoaded?.window != nil else { return }
        guard UIApplication.shared.applicationState == .active,
          self.overlayWindow?.windowScene?.activationState == .foregroundActive,
          self.showsPrimaryPage, !(self.showsRecipeHome && self.mealReminder != nil), !self.keyboardIsVisible,
          self.host?.presentedViewController == nil, self.mascotView.isReadyForDisplay else { continue }
        let index = self.debugMessageIndex
        self.debugMessageIndex = (index + 1) % 8
        self.displayedDebugMessage = index
        self.showMessage(self.debugText(at: index), holdSeconds: 4)
      }
    }
  }

  private func stopDebugMessages() {
    debugMessageRun = UUID(); debugMessageTask?.cancel(); debugMessageTask = nil
  }

  private func debugText(at index: Int) -> String {
    guard let app else { return "" }
    switch index {
    case 0: return app.text("想做一道番茄炒蛋吗？我们可以先在菜谱中查找。", "Feel like tomato and eggs? We can look for a recipe first.")
    case 1: return app.text("炒菜前先备好食材和调味料，做起来会更从容。", "Prepare the ingredients and seasonings before cooking for a calmer start.")
    case 2: return app.text("想换个口味？去菜谱页看看今天想做哪道菜。", "Want something different? Explore recipes for what to cook today.")
    case 3: return app.text("把常用食材整理一下，下一顿饭会更好安排。", "Organizing your usual ingredients can make the next meal easier to plan.")
    case 4: return app.text("看看备菜页，能帮你区分家里已有和待采购的食材。", "The preparation page helps separate ingredients at home from those to buy.")
    case 5: return app.text("安排一周菜单，可以先从明天的一顿饭开始。", "Planning a week of meals can start with just one meal tomorrow.")
    case 6: return app.text("想聊聊今天的心情，或一起安排晚餐？点我就可以开始。", "Want to talk about your day or plan dinner together? Tap me to start.")
    default: return app.text("做完一道菜，可以记录作品，留住这次的心得。", "After cooking, save your result and what you learned.")
    }
  }
#endif

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
    presentConversation()
  }

  /// Opens the assistant when an opted-in remote nudge is tapped.
  func presentConversation() {
    guard let host, let app else { return }
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
#if DEBUG
    stopDebugMessages()
#endif
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
    presenter.present(navigation, animated: true)
  }
}

@MainActor
final class QFDigitalAssistantConversationViewController: UIViewController,
  PHPickerViewControllerDelegate, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate {
  private let app: QFAppSession
  private let applicationState: @MainActor () -> UIApplication.State
  private let panel = UIView()
  private let messagesScroll = UITableView(frame: .zero, style: .plain)
  private let jumpButton = UIButton(type: .system)
  private var expandedProcess = Set<UUID>()
  private var manuallyExpandedProcess = Set<UUID>()
  private var scrollFollow = QFAssistantScrollFollow()
  private var deferredStreamRender = false
#if DEBUG
  private let debugAudioProbe = QFAssistantVoiceBufferProbe()
  private var debugFrameRate: Float = 60
  private var debugRevealFrames: [Double]?
  private var debugVoicePartials: [[String: Any]] = []
  private var debugViewportEvents: [[String: Any]]? = nil
  private func traceViewport(_ event: String) {
    guard debugViewportEvents != nil, debugViewportEvents!.count < 50 else { return }
    let position = readingPosition()
    debugViewportEvents?.append(["event": event, "y": messagesScroll.contentOffset.y, "h": messagesScroll.contentSize.height,
      "relative": position.relativeY, "follow": followLatest, "interacting": scrollFollow.isInteracting])
  }
#endif
  private var followLatest: Bool { scrollFollow.canFollow }
  private var activeMessageID: UUID?
  private var renderTask: Task<Void, Never>?
  private var revealDisplayLink: CADisplayLink?
  private var reveals: [UUID: QFAssistantTextReveal] = [:]
  private var navigationTask: Task<Void, Never>?
  private var composerHeight: Constraint?
  private let composer = UIView()
  private let input = UITextView()
  private let inputPlaceholder = UILabel()
  private let imagePreview = UIImageView()
  private let previewHolder = UIView()
  private var previewHeight: Constraint?
  private let send = UIButton(type: .system)
  private let mic = UIButton(type: .system)
  private let voicePanel = UIView()
  private let voiceTranscript = UITextView()
  private let holdToTalk = UIButton(type: .system)
  private let cancelVoice = UIButton(type: .system)
  private var voiceMode = false
  private var voice = QFAssistantVoiceInput()
  private var holdOrigin = CGPoint.zero
  private let photo = UIButton(type: .system)
  private let modeButton = UIButton(type: .system)
  private let attachment = UILabel()
  private let removeAttachment = UIButton(type: .system)
  private var messages: [QFAssistantLocalMessage]
  private var conversationStore: QFAssistantConversationStore
  private let persistConversation: Bool
  private var conversationBinding: QFAgentScope
  private var requestTask: Task<Void, Never>?
  private var requestGeneration = UUID()
  private let audioEngine = AVAudioEngine()
  private var audioTapInstalled = false
  private var ownsAudioSession = false
  private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
  private var transcriptionDeadline: Task<Void, Never>?
  private var transcription: SFSpeechRecognitionTask?
  private var attachmentScope: QFAgentScope?
  private var selectedImage: UIImage?
  private var selectedImageData: Data?
  private var selectedImageMimeType = "image/jpeg"
  // Local Qwen is paused at the product entry; its files and diagnostic code are retained.
  private var useCloud: Bool { true }
  private var selectedProvider: QFAssistantProvider = .glmFree
  private var lifecycle = Set<AnyCancellable>()
  var onDismiss: (() -> Void)?
  fileprivate weak var tabNavigationHost: UITabBarController?
  fileprivate var onCharacterIntent: ((QFAssistantCharacterIntent) -> Void)?

  private var cloudConsentKey: String { selectedProvider.consentKey(scope: app.contentScope) }

  init(app: QFAppSession, applicationState: (@MainActor () -> UIApplication.State)? = nil, persistConversation: Bool = true) {
    self.app = app
    self.applicationState = applicationState ?? { UIApplication.shared.applicationState }
    self.persistConversation = persistConversation
    let store = QFAssistantConversationStore(scope: QFAssistantAgent.scope(app), persistent: persistConversation)
    conversationBinding = QFAssistantAgent.scope(app)
    conversationStore = store
    messages = store.load()
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { nil }
  deinit {
    requestTask?.cancel()
    renderTask?.cancel()
    revealDisplayLink?.invalidate(); navigationTask?.cancel()
    transcription?.cancel()
    transcriptionDeadline?.cancel()
    audioEngine.stop()
    if audioTapInstalled { audioEngine.inputNode.removeTap(onBus: 0) }
    speechRequest?.endAudio()
    if ownsAudioSession { try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation]) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.accessibilityViewIsModal = true
    setupPanel()
    let knowledgeLanguage = app.interfaceLanguage
    Task { try? await QFAssistantKnowledge.shared.prewarm(language: knowledgeLanguage) }
    refreshLocalizedControls()
    renderMessages()
    NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
      .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.stopCapture(); self?.pausePresentation() }.store(in: &lifecycle)
    NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
      .receive(on: DispatchQueue.main).sink { [weak self] _ in
        guard let self else { return }
        self.interruptVoiceCapture()
        self.pausePresentation()
      }.store(in: &lifecycle)
    NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
      .receive(on: DispatchQueue.main).sink { [weak self] note in
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        self?.interruptVoiceCapture()
      }.store(in: &lifecycle)
    NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
      .receive(on: DispatchQueue.main).sink { [weak self] note in
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        self?.interruptVoiceCapture()
      }.store(in: &lifecycle)
    NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
      .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.pausePresentation() }.store(in: &lifecycle)
    NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
      .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.resumePresentation() }.store(in: &lifecycle)
    app.$interfaceLanguage.dropFirst().receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.reloadConversationScope() }.store(in: &lifecycle)
    app.$user.dropFirst().receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.reloadConversationScope() }.store(in: &lifecycle)
    app.$planningScope.dropFirst().receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.reloadConversationScope() }.store(in: &lifecycle)
  }

  private func reloadConversationScope() {
    guard conversationBinding != QFAssistantAgent.scope(app) else { return }
    cancelRequest()
    QFOnDeviceInference.releaseIdleCache()
    selectedImage = nil; selectedImageData = nil; attachmentScope = nil
    input.text = ""; attachment.isHidden = true; removeAttachment.isHidden = true; mic.tintColor = QFUI.primary
    refreshImagePreview()
    conversationStore = QFAssistantConversationStore(scope: QFAssistantAgent.scope(app), persistent: persistConversation)
    conversationBinding = QFAssistantAgent.scope(app)
    messages = conversationStore.load(); selectedProvider = .glmFree; expandedProcess.removeAll(); manuallyExpandedProcess.removeAll(); scrollFollow.jumpToLatest()
    refreshLocalizedControls(); renderMessages()
  }

  private func cancelRequest() {
    requestGeneration = UUID(); requestTask?.cancel(); requestTask = nil
    navigationTask?.cancel(); navigationTask = nil
    stopCapture()
    if let id = activeMessageID, let index = messages.firstIndex(where: { $0.id == id }) {
      finishProcess(index: index, state: "stopped")
      if messages[index].text.isEmpty { messages[index].notice = app.text("已停止生成", "Generation stopped") }
      conversationStore.save(messages)
    }
    activeMessageID = nil; pausePresentation()
    updateSendButton(); renderMessages()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    pausePresentation()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stopCapture() // Leaving a page preserves submitted generation, never live microphone capture.
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(false, animated: animated)
    renderMessages()
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    resumePresentation()
  }

  private func resumePresentation() {
    renderMessages()
    startTextReveal() // Also resumes an interrupted animation with no subsequent model token.
  }

  private func pausePresentation() {
    for cell in messagesScroll.visibleCells.compactMap({ $0 as? QFAssistantChatCell }) { cell.advanceTextFade(at: CACurrentMediaTime() + 1) }
    renderTask?.cancel(); renderTask = nil; revealDisplayLink?.invalidate(); revealDisplayLink = nil; reveals.removeAll()
    conversationStore.save(messages)
  }
  fileprivate func endScene() { cancelRequest(); QFOnDeviceInference.releaseIdleCache() }

  private func dismissConversation() {
    stopCapture()
    navigationTask?.cancel(); navigationTask = nil
    // Resume the overlay only after UIKit has removed the presentation chain.
    let completion = onDismiss; onDismiss = nil
    dismiss(animated: true, completion: completion)
  }

  private func setupPanel() {
    title = app.text("饮食助手", "Diet assistant")
    navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "chevron.down"), style: .plain, target: self, action: #selector(closeChat))
    navigationItem.leftBarButtonItem?.accessibilityLabel = app.text("关闭", "Close")
    navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "brain.head.profile"), style: .plain, target: self, action: #selector(openMemory))
    navigationItem.rightBarButtonItem?.accessibilityLabel = app.text("记忆管理", "Manage memory")
    navigationController?.navigationBar.tintColor = QFUI.primary
    panel.backgroundColor = QFUI.background; panel.accessibilityIdentifier = "assistant.conversation.fullscreen"
    view.addSubview(panel); panel.snp.makeConstraints { $0.edges.equalTo(view.safeAreaLayoutGuide) }
    modeButton.accessibilityIdentifier = "assistant.mode-toggle"
    modeButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
    modeButton.layer.cornerRadius = 16; modeButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
    modeButton.addTarget(self, action: #selector(toggleMode), for: .touchUpInside)
    panel.addSubview(modeButton); modeButton.snp.makeConstraints { $0.top.equalToSuperview().offset(6); $0.centerX.equalToSuperview(); $0.height.greaterThanOrEqualTo(36) }
    refreshModeButton()
    composer.backgroundColor = QFUI.surface; composer.layer.cornerRadius = 22
    composer.layer.borderWidth = 0.7; composer.layer.borderColor = QFUI.border.cgColor
    view.addSubview(composer)
    composer.snp.makeConstraints { $0.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(14); $0.bottom.equalTo(view.keyboardLayoutGuide.snp.top).offset(-8) }
    input.font = .preferredFont(forTextStyle: .body); input.adjustsFontForContentSizeCategory = true
    input.textColor = QFUI.text; input.backgroundColor = .clear; input.delegate = self
    input.isScrollEnabled = false; input.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 6, right: 8)
    input.accessibilityLabel = app.text("发送消息", "Message")
    previewHolder.clipsToBounds = true
    composer.addSubview(previewHolder)
    previewHolder.snp.makeConstraints { $0.top.equalToSuperview().offset(8); $0.leading.trailing.equalToSuperview().inset(12); previewHeight = $0.height.equalTo(0).constraint }
    previewHolder.addSubview(imagePreview)
    imagePreview.snp.makeConstraints { $0.leading.top.equalToSuperview(); $0.size.equalTo(80) }
    imagePreview.contentMode = .scaleAspectFill; imagePreview.clipsToBounds = true; imagePreview.layer.cornerRadius = 12
    imagePreview.isUserInteractionEnabled = true
    imagePreview.isAccessibilityElement = true; imagePreview.accessibilityTraits = .button
    imagePreview.accessibilityLabel = app.text("查看大图", "View full image")
    imagePreview.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(previewSelectedImage)))
    composer.addSubview(input)
    input.snp.makeConstraints { $0.leading.trailing.equalToSuperview().inset(6); $0.top.equalTo(previewHolder.snp.bottom).offset(2); composerHeight = $0.height.equalTo(44).constraint }
    inputPlaceholder.font = .preferredFont(forTextStyle: .body); inputPlaceholder.adjustsFontForContentSizeCategory = true
    inputPlaceholder.textColor = QFUI.secondary; inputPlaceholder.isUserInteractionEnabled = false
    inputPlaceholder.isAccessibilityElement = false
    composer.addSubview(inputPlaceholder)
    inputPlaceholder.snp.makeConstraints { $0.leading.equalTo(input).offset(13); $0.top.equalTo(input).offset(10); $0.trailing.lessThanOrEqualTo(input).inset(12) }
    let tools = QFTabUI.stack([photo, mic], axis: .horizontal, spacing: 4)
    composer.addSubview(tools); composer.addSubview(send)
    tools.snp.makeConstraints { $0.leading.equalToSuperview().offset(8); $0.top.equalTo(input.snp.bottom); $0.bottom.equalToSuperview().inset(4); $0.height.equalTo(44); $0.width.equalTo(92) }
    send.snp.makeConstraints { $0.trailing.equalToSuperview().inset(8); $0.centerY.equalTo(tools); $0.size.equalTo(44) }
    configureButton(photo, icon: "photo", label: app.text("添加图片", "Add image"), action: #selector(selectPhoto))
    configureButton(mic, icon: "mic", label: app.text("发送语音", "Voice input"), action: #selector(toggleVoiceMode))
    photo.snp.makeConstraints { $0.width.equalTo(44) }
    mic.snp.makeConstraints { $0.width.equalTo(44) }
    mic.accessibilityIdentifier = "assistant.voice-mode"
    setupVoicePanel()
    configureButton(send, icon: "arrow.up.circle.fill", label: app.text("发送", "Send"), action: #selector(sendMessage))
    send.accessibilityIdentifier = "assistant.send-or-stop"
    attachment.font = .preferredFont(forTextStyle: .caption1); attachment.textColor = QFUI.secondary; attachment.numberOfLines = 1; attachment.isHidden = true
    view.addSubview(attachment)
    attachment.snp.makeConstraints { $0.leading.equalTo(composer).offset(8); $0.trailing.equalTo(composer).inset(48); $0.bottom.equalTo(composer.snp.top).offset(-4); $0.height.equalTo(32) }
    view.addSubview(removeAttachment); removeAttachment.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
    removeAttachment.tintColor = QFUI.secondary; removeAttachment.isHidden = true
    removeAttachment.accessibilityLabel = app.text("移除图片", "Remove photo")
    removeAttachment.accessibilityIdentifier = "assistant.attachment.remove"
    removeAttachment.snp.makeConstraints { $0.trailing.equalTo(composer); $0.centerY.equalTo(attachment); $0.width.equalTo(44); $0.height.equalTo(32) }
    removeAttachment.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      guard self.selectedImage != nil else { return }
      self.cancelRequest() // Invalidates an in-flight OCR callback as well.
      self.selectedImage = nil; self.selectedImageData = nil; self.attachmentScope = nil
      self.attachment.isHidden = true; self.removeAttachment.isHidden = true
      self.refreshImagePreview()
      self.updateSendButton()
    }, for: .touchUpInside)
    messagesScroll.backgroundColor = .clear; messagesScroll.separatorStyle = .none
    messagesScroll.dataSource = self; messagesScroll.delegate = self
    messagesScroll.rowHeight = UITableView.automaticDimension; messagesScroll.estimatedRowHeight = 140
    messagesScroll.keyboardDismissMode = .interactive; messagesScroll.showsVerticalScrollIndicator = false
    messagesScroll.register(QFAssistantChatCell.self, forCellReuseIdentifier: "chat")
    panel.addSubview(messagesScroll)
    messagesScroll.snp.makeConstraints { $0.leading.trailing.equalToSuperview(); $0.top.equalTo(modeButton.snp.bottom).offset(8); $0.bottom.equalTo(attachment.snp.top).offset(-4) }
    jumpButton.setImage(UIImage(systemName: "arrow.down.circle.fill"), for: .normal); jumpButton.tintColor = QFUI.primary
    jumpButton.accessibilityLabel = app.text("回到最新消息", "Jump to latest")
    jumpButton.backgroundColor = QFUI.surface; jumpButton.layer.cornerRadius = 22; jumpButton.isHidden = true
    jumpButton.addAction(UIAction { [weak self] _ in self?.scrollFollow.jumpToLatest(); self?.renderMessages(); self?.scrollToLatest(userInitiated: true) }, for: .touchUpInside)
    view.addSubview(jumpButton); jumpButton.snp.makeConstraints { $0.trailing.equalTo(composer).inset(8); $0.bottom.equalTo(attachment.snp.top).offset(-10); $0.size.equalTo(44) }
    let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard)); tap.cancelsTouchesInView = false; messagesScroll.addGestureRecognizer(tap)
  }

  @objc private func closeChat() { dismissConversation() }
  @objc private func openMemory() { stopCapture(); present(QFDigitalAssistantMemoryViewController(app: app), animated: true) }
  func textViewDidChange(_ textView: UITextView) {
    let height = textView.sizeThatFits(CGSize(width: max(1, textView.bounds.width), height: .greatestFiniteMagnitude)).height
    textView.isScrollEnabled = height > QFAssistantChatLayout.composerMaxHeight
    composerHeight?.update(offset: min(QFAssistantChatLayout.composerMaxHeight, max(44, height)))
    inputPlaceholder.isHidden = !textView.text.isEmpty
    updateSendButton()
  }

  private func configureButton(_ button: UIButton, icon: String, label: String, action: Selector) {
    button.setImage(UIImage(systemName: icon), for: .normal)
    button.tintColor = QFUI.primary; button.accessibilityLabel = label; button.addTarget(self, action: action, for: .touchUpInside)
  }

  private func refreshLocalizedControls() {
    title = app.text("饮食助手", "Diet assistant")
    navigationItem.leftBarButtonItem?.accessibilityLabel = app.text("关闭", "Close")
    navigationItem.rightBarButtonItem?.accessibilityLabel = app.text("记忆管理", "Manage memory")
    input.accessibilityLabel = app.text("发送消息", "Message")
    inputPlaceholder.text = app.text("问菜谱、食材，或聊聊今天吃什么", "Ask about recipes, ingredients or today's meals")
    photo.accessibilityLabel = app.text("添加图片", "Add image")
    mic.accessibilityLabel = app.text("发送语音", "Voice input")
    removeAttachment.accessibilityLabel = app.text("移除图片", "Remove photo")
    jumpButton.accessibilityLabel = app.text("回到最新消息", "Jump to latest")
    refreshModeButton(); updateSendButton()
  }

  private func renderMessages(forceWhileReading: Bool = false) {
#if DEBUG
    traceViewport("render")
#endif
    guard isViewLoaded, view.window != nil, applicationState() == .active else { return }
    if messages.isEmpty {
      let welcome = QFTabUI.label(app.text("你好，我可以帮你规划饮食、整理食材和生成待确认草稿。", "Hi. I can help plan meals, organize ingredients and make drafts for your review."), size: 18, color: QFUI.secondary, lines: 0)
      welcome.textAlignment = .center; messagesScroll.backgroundView = welcome
    } else { messagesScroll.backgroundView = nil }
    guard !scrollFollow.isInteracting else { deferredStreamRender = true; return }
    // Reappearing/lifecycle refreshes can arrive after a gesture. Even a reload
    // with unchanged content may refine estimated row heights under the reader.
    guard followLatest || forceWhileReading || messagesScroll.numberOfRows(inSection: 0) == 0 else {
      deferredStreamRender = true; jumpButton.isHidden = false; return
    }
    let position = readingPosition()
    messagesScroll.reloadData(); messagesScroll.layoutIfNeeded()
    if followLatest { scrollToLatest() } else { restoreReadingPosition(position); jumpButton.isHidden = false }
    deferredStreamRender = false
  }
  private func scheduleStreamRender(metadataChanged: Bool = true) {
    guard viewIfLoaded?.window != nil, applicationState() == .active else { return }
    if let id = activeMessageID, let item = messages.first(where: { $0.id == id }), !item.text.isEmpty {
      var reveal = reveals[id] ?? QFAssistantTextReveal(initial: displayedText(for: id))
      reveal.receive(item.text); reveals[id] = reveal
      startTextReveal()
    }
    // TextKit receives text in place. Rebuilding the entire cell for each delta
    // duplicates layout and recreates source/processing controls unnecessarily.
    guard metadataChanged else { return }
    guard renderTask == nil else { return }
    renderTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
      guard let self else { return }; self.renderTask = nil
      guard self.followLatest else { self.deferredStreamRender = true; return }
      guard let id = self.activeMessageID, let row = self.messages.firstIndex(where: { $0.id == id }) else { return }
      if self.messagesScroll.indexPathsForVisibleRows?.contains(IndexPath(row: row, section: 0)) == true {
        let position = self.readingPosition()
        self.messagesScroll.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
        self.messagesScroll.layoutIfNeeded()
        if self.followLatest { self.scrollToLatest() } else { self.restoreReadingPosition(position) }
      } else if self.followLatest { self.scrollToLatest() }
    }
  }

  private func displayedText(for id: UUID) -> String {
    guard let row = messages.firstIndex(where: { $0.id == id }),
      let cell = messagesScroll.cellForRow(at: IndexPath(row: row, section: 0)) as? QFAssistantChatCell else { return "" }
    return cell.displayedText
  }

  private func startTextReveal() {
    guard revealDisplayLink == nil else { return }
    let target = QFAssistantDisplayLinkTarget { [weak self] link in self?.revealFrame(link) }
    let link = CADisplayLink(target: target, selector: #selector(QFAssistantDisplayLinkTarget.tick(_:)))
#if DEBUG
    link.preferredFrameRateRange = CAFrameRateRange(minimum: debugFrameRate, maximum: debugFrameRate, preferred: debugFrameRate)
#else
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
#endif
    revealDisplayLink = link
    link.add(to: .main, forMode: .common)
  }
  private func revealFrame(_ link: CADisplayLink) {
    guard viewIfLoaded?.window != nil, applicationState() == .active, followLatest else {
      for cell in messagesScroll.visibleCells.compactMap({ $0 as? QFAssistantChatCell }) { cell.advanceTextFade(at: CACurrentMediaTime() + 1) }
      link.invalidate(); revealDisplayLink = nil; return
    }
    var heightChanged = false, textChanged = false
    let time = CACurrentMediaTime()
#if DEBUG
    if debugRevealFrames != nil, debugRevealFrames!.count < 600 { debugRevealFrames?.append(time) }
#endif
    for id in reveals.keys {
      if reveals[id]?.isComplete == false { reveals[id]?.step(reduceMotion: UIAccessibility.isReduceMotionEnabled) }
      guard let row = messages.firstIndex(where: { $0.id == id }),
        let cell = messagesScroll.cellForRow(at: IndexPath(row: row, section: 0)) as? QFAssistantChatCell,
        cell.displayedText != reveals[id]?.visible else { continue }
      heightChanged = cell.revealText(reveals[id]?.visible ?? "", at: time) || heightChanged
      textChanged = true
    }
    if heightChanged { UIView.performWithoutAnimation { messagesScroll.beginUpdates(); messagesScroll.endUpdates() } }
    if heightChanged || textChanged { scrollToLatest() }
    let cells = messagesScroll.visibleCells.compactMap { $0 as? QFAssistantChatCell }
    for cell in cells where cell.hasTextFade { cell.advanceTextFade(at: time) }
    if !reveals.values.contains(where: { !$0.isComplete }) && !cells.contains(where: { $0.hasTextFade }) {
      link.invalidate(); revealDisplayLink = nil
    }
  }
  private func scrollToLatest(userInitiated: Bool = false) {
    guard followLatest, !messages.isEmpty else { return }
    guard userInitiated || (!messagesScroll.isTracking && !messagesScroll.isDragging && !messagesScroll.isDecelerating) else { return }
    messagesScroll.layoutIfNeeded()
    messagesScroll.scrollToRow(at: IndexPath(row: messages.count - 1, section: 0), at: .bottom, animated: false)
    jumpButton.isHidden = true
  }
  private var distanceFromBottom: Double {
    Double(messagesScroll.contentSize.height + messagesScroll.adjustedContentInset.bottom
      - messagesScroll.contentOffset.y - messagesScroll.bounds.height)
  }
  private struct ReadingPosition { let id: UUID?; let relativeY: CGFloat; let offset: CGPoint }
  private func readingPosition() -> ReadingPosition {
    let first = messagesScroll.indexPathsForVisibleRows?.sorted().first
    let id = first.flatMap { messages.indices.contains($0.row) ? messages[$0.row].id : nil }
    let relativeY = first.map { messagesScroll.rectForRow(at: $0).minY - messagesScroll.contentOffset.y } ?? 0
    return .init(id: id, relativeY: relativeY, offset: messagesScroll.contentOffset)
  }
  private func restoreReadingPosition(_ position: ReadingPosition) {
    guard !scrollFollow.isInteracting, !messagesScroll.isTracking,
      !messagesScroll.isDragging, !messagesScroll.isDecelerating else { return }
    var y = position.offset.y
    if let id = position.id, let row = messages.firstIndex(where: { $0.id == id }) {
      y = messagesScroll.rectForRow(at: IndexPath(row: row, section: 0)).minY - position.relativeY
    }
    let minimum = -messagesScroll.adjustedContentInset.top
    let maximum = max(minimum, messagesScroll.contentSize.height - messagesScroll.bounds.height + messagesScroll.adjustedContentInset.bottom)
    messagesScroll.setContentOffset(CGPoint(x: position.offset.x, y: min(maximum, max(minimum, y))), animated: false)
  }
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    guard scrollView === messagesScroll else { return }
    scrollFollow.beginDragging(); jumpButton.isHidden = false
  }
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === messagesScroll else { return }
#if DEBUG
    traceViewport("scroll")
#endif
    scrollFollow.didScroll(distanceFromBottom: distanceFromBottom)
  }
  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if scrollView === messagesScroll, !decelerate { finishReadingGesture() }
  }
  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    if scrollView === messagesScroll { finishReadingGesture() }
  }
  private func finishReadingGesture() {
    scrollFollow.finishGesture(distanceFromBottom: distanceFromBottom)
    jumpButton.isHidden = followLatest
    if followLatest {
      if deferredStreamRender { renderMessages() }
      else { scrollToLatest() }
    }
    startTextReveal()
  }
#if DEBUG
  /// Exercise the real footer button under the App's root -> tabs containment.
  /// The chat uses an ephemeral store; no prompt, business request or user draft.
  static func debugCheckTabNavigation() async throws -> [String: Any] {
    let app = QFAppSession() // Never start/login this isolated session.
    let root = UIViewController(), tabs = UITabBarController()
    tabs.viewControllers = (0..<3).map { _ in UINavigationController(rootViewController: UIViewController()) }
    root.addChild(tabs); root.view.addSubview(tabs.view)
    tabs.view.snp.makeConstraints { $0.edges.equalToSuperview() }; tabs.didMove(toParent: root)
    let window: UIWindow
    if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
      window = UIWindow(windowScene: scene)
    } else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 414, height: 896)) }
    window.rootViewController = root; window.isHidden = false
    defer { window.isHidden = true; window.rootViewController = nil }
    let chat = QFDigitalAssistantConversationViewController(app: app, applicationState: { .active }, persistConversation: false)
    chat.tabNavigationHost = tabs
    let navigation = UINavigationController(rootViewController: chat)
    navigation.modalPresentationStyle = .fullScreen
    defer { chat.endScene() }
    var checked: [String] = []
    for (action, destination) in [("NAVIGATE_RECIPES", 0), ("NAVIGATE_PLAN", 1), ("NAVIGATE_INVENTORY", 2)] {
      tabs.selectedIndex = (destination + 1) % 3
      await withCheckedContinuation { continuation in root.present(navigation, animated: false) { continuation.resume() } }
      let activeID = UUID()
      chat.messages = [
        .init(id: UUID(), role: "assistant", text: "Public navigation example", createdAt: Date(),
          actions: [.init(type: action, recipeID: nil, date: nil)], state: "complete"),
        .init(id: activeID, role: "assistant", text: "Partial reply", createdAt: Date(), state: "streaming")
      ]
      chat.activeMessageID = activeID
      chat.input.text = "Unsent isolated draft"
      let generation = chat.requestGeneration
      var dismissed = 0
      chat.onDismiss = { dismissed += 1 }
      chat.renderMessages(); chat.view.layoutIfNeeded()
      chat.messagesScroll.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
      chat.messagesScroll.layoutIfNeeded()
      func button(in view: UIView) -> UIButton? {
        if let value = view as? UIButton, value.accessibilityIdentifier == "assistant.action.\(action)" { return value }
        return view.subviews.lazy.compactMap { button(in: $0) }.first
      }
      guard let cell = chat.messagesScroll.cellForRow(at: IndexPath(row: 0, section: 0)), let control = button(in: cell),
        control.isEnabled, !control.isHidden else { throw NSError(domain: "AssistantTabButtonMissing", code: 1) }
      let point = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: window)
      guard let hit = window.hitTest(point, with: nil), hit === control || hit.isDescendant(of: control) else {
        throw NSError(domain: "AssistantTabButtonObstructed", code: 4)
      }
      control.sendActions(for: .touchUpInside)
      control.sendActions(for: .touchUpInside) // A repeated tap must not dismiss/callback twice.
      try await Task.sleep(nanoseconds: 700_000_000)
      guard tabs.selectedIndex == destination, root.presentedViewController == nil, dismissed == 1 else {
        throw NSError(domain: "AssistantTabNavigationFailed", code: 2, userInfo: [NSLocalizedDescriptionKey:
          "action=\(action); selected=\(tabs.selectedIndex); target=\(destination); dismissed=\(dismissed); presenter=\(String(describing: navigation.presentingViewController.map { type(of: $0) }))"])
      }
      guard chat.activeMessageID == activeID, chat.requestGeneration == generation,
        chat.messages.last?.text == "Partial reply", chat.input.text == "Unsent isolated draft" else {
        throw NSError(domain: "AssistantTabNavigationLostConversation", code: 3)
      }
      checked.append(action)
    }
    return ["passed": true, "footerActions": checked, "rootContainment": true,
      "generationAndDraftPreserved": true, "modelCalls": 0, "businessWrites": 0, "conversationWrites": 0]
  }

  /// Compare the home constructor with the real assistant source-tap route for
  /// one published ID. Reads only; no model request and no persisted messages.
  static func debugCheckRecipeEntryParity(app: QFAppSession) async throws -> [String: Any] {
    let page: QFContentPage<QFRecipeHomeItem> = try await app.publicContentRequest(path: "home/recipes", query: ["page": "0"])
    guard let first = page.items.first else { throw NSError(domain: "RecipeParityNoPublishedRecipe", code: 1) }
    var results = [try await debugCompareRecipeEntry(app: app, item: first)]
    for id in ["b9491989-a862-58b4-8bdf-1336397aa8a1", "fc501baa-0a7f-53f0-929a-b391cd4c4342"] where id != first.id {
      let detail: QFRecipeHomeDetail = try await app.publicContentRequest(path: "home/recipes/" + id)
      results.append(try await debugCompareRecipeEntry(app: app, item: detail.listItem))
    }
    return ["status": "MATCHED", "cases": results, "modelCalls": false, "businessWrites": false]
  }
  private static func debugCompareRecipeEntry(app: QFAppSession, item: QFRecipeHomeItem) async throws -> [String: Any] {
    let home = QFHomeRecipeDetailViewController(app: app, initial: item, onChanged: { _ in })
    let assistant = QFDigitalAssistantConversationViewController(app: app, applicationState: { .active }, persistConversation: false)
    let window: UIWindow
    if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window = UIWindow(windowScene: scene) }
    else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 414, height: 896)) }
    let homeNavigation = QFNavigationController(rootViewController: home)
    window.rootViewController = homeNavigation; window.isHidden = false
    defer { assistant.endScene(); window.isHidden = true; window.rootViewController = nil }
    let deadline = Date().addingTimeInterval(30)
    while try home.debugRecipeSnapshot() == nil, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
    guard let fromHome = try home.debugRecipeSnapshot() else { throw NSError(domain: "RecipeParityHomeLoadFailed", code: 2) }
    let navigation = UINavigationController(rootViewController: assistant)
    window.rootViewController = navigation
    assistant.loadViewIfNeeded()
    try await Task.sleep(nanoseconds: 250_000_000)
    assistant.openSource(.init(id: "recipe:\(item.id)", title: item.title, url: nil, revision: nil))
    guard let fromAIController = navigation.topViewController as? QFHomeRecipeDetailViewController else {
      throw NSError(domain: "RecipeParityAssistantRouteMismatch", code: 3, userInfo: [NSLocalizedDescriptionKey:
        "idIsUUID=\(UUID(uuidString: item.id) != nil); attached=\(assistant.navigationController === navigation); top=\(String(describing: navigation.topViewController.map { type(of: $0) }))"])
    }
    let aiDeadline = Date().addingTimeInterval(30)
    while try fromAIController.debugRecipeSnapshot() == nil, Date() < aiDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
    guard let fromAI = try fromAIController.debugRecipeSnapshot(),
      fromHome.data == fromAI.data, !fromHome.texts.isEmpty, fromHome.texts == fromAI.texts,
      navigation.isNavigationBarHidden else {
      throw NSError(domain: "RecipeParityContentMismatch", code: 4)
    }
    // A cached detail can load before UIKit's push animation finishes. Wait for
    // its real completion before checking Back; a pop during that transition
    // does not exercise the user's settled detail-screen return path.
    if let transition = navigation.transitionCoordinator {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let scheduled = transition.animate(alongsideTransition: nil) { _ in continuation.resume() }
        if !scheduled { continuation.resume() }
      }
    }
    navigation.popViewController(animated: false)
    try await Task.sleep(nanoseconds: 100_000_000)
    guard navigation.topViewController === assistant, !navigation.isNavigationBarHidden else {
      throw NSError(domain: "RecipeParityChatNavigationNotRestored", code: 5, userInfo: [NSLocalizedDescriptionKey:
        "returnedToChat=\(navigation.topViewController === assistant); hidden=\(navigation.isNavigationBarHidden); transition=\(navigation.transitionCoordinator != nil)"])
    }
    return ["sameRecipeID": true, "sameDetailPayload": true, "sameRenderedRecipeText": true,
      "recipeID": item.id, "materialCount": fromAI.materials, "visibleStepCount": fromAI.steps,
      "sameNavigationChrome": true, "chatNavigationRestored": true,
      "publicRecipeReads": true, "modelCalls": false, "businessWrites": false]
  }

  static func debugCheckComposerMediaAndThinking(app: QFAppSession) async throws -> [String: Any] {
    let controller = QFDigitalAssistantConversationViewController(app: app, applicationState: { .active }, persistConversation: false)
    let window: UIWindow
    if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window = UIWindow(windowScene: scene) }
    else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 414, height: 896)) }
    window.rootViewController = UINavigationController(rootViewController: controller); window.isHidden = false
    defer { controller.endScene(); window.isHidden = true; window.rootViewController = nil }
    try await Task.sleep(nanoseconds: 200_000_000)
    let id = UUID()
    controller.messages = [.init(id: id, role: "assistant", text: "", createdAt: Date(), state: "streaming",
      process: [.init(stage: "preparing", state: "running")],
      analysis: QFAssistantQuestionAnalysis.summary(text: "请给两人安排20分钟的晚餐，花生过敏。", hasImage: false, app: app))]
    controller.activeMessageID = id
    controller.renderMessages(); window.layoutIfNeeded()
    try await Task.sleep(nanoseconds: 150_000_000)
    guard let thinking = controller.messagesScroll.cellForRow(at: IndexPath(row: 0, section: 0)) as? QFAssistantChatCell,
      thinking.debugSweepVisible, thinking.debugDisclosureWidth >= 14 else { throw NSError(domain: "ThinkingSweepOrDisclosureMissing", code: 1) }
    thinking.debugToggleAnalysis()
    guard controller.expandedProcess.contains(id) else { throw NSError(domain: "AnalysisToggleNotImmediate", code: 2) }
    try await Task.sleep(nanoseconds: 500_000_000)
    let preview = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
    if let data = preview.pngData() {
      let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("assistant-processing-preview.png")
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    controller.activeMessageID = nil
    let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
      UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    let media = try controller.conversationStore.saveImage(image.pngData()!)
    defer { QFLocalMediaStore.remove(media, scope: controller.conversationStore.mediaScope) }
    guard let local = controller.conversationStore.imageURL(media),
      (try? QFLocalMediaStore.url(media, scope: controller.conversationStore.mediaScope + "-other")) == nil else { throw NSError(domain: "ChatImageScopeLeak", code: 3) }
    controller.selectedImage = image; controller.selectedImageData = image.pngData(); controller.refreshImagePreview()
    controller.view.layoutIfNeeded()
    guard controller.previewHolder.bounds.height >= 80, controller.imagePreview.image != nil, controller.send.isEnabled else { throw NSError(domain: "ComposerImagePreviewMissing", code: 4) }
    controller.messages = [.init(id: UUID(), role: "user", text: "Public image fixture", createdAt: Date(), imageID: media)]
    controller.renderMessages()
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if let cell = controller.messagesScroll.cellForRow(at: IndexPath(row: 0, section: 0)) as? QFAssistantChatCell, cell.debugPhotoLoaded { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard let cell = controller.messagesScroll.cellForRow(at: IndexPath(row: 0, section: 0)) as? QFAssistantChatCell, cell.debugPhotoLoaded,
      FileManager.default.fileExists(atPath: local.path) else { throw NSError(domain: "SentImagePreviewMissing", code: 5) }
    controller.voiceMode = true; controller.input.text = "Existing draft"
    let token = controller.voice.begin(draft: controller.input.text)!
    guard controller.voice.start(token: token) else { throw NSError(domain: "VoiceStartFailed", code: 6) }
    controller.voice.receive("番茄", token: token); controller.updateSendButton()
    guard !controller.send.isEnabled, controller.send.accessibilityLabel == app.text("发送", "Send"),
      controller.voiceTranscript.text == "番茄", !controller.cancelVoice.isHidden else { throw NSError(domain: "VoiceSendStateCoupled", code: 7) }
    controller.voice.receive("番茄炒蛋", token: token); controller.updateSendButton()
    guard controller.voiceTranscript.text == "番茄炒蛋", controller.input.text == "Existing draft" else { throw NSError(domain: "VoicePartialDuplicatedOrOverwroteDraft", code: 8) }
    controller.activeMessageID = id; controller.updateSendButton()
    guard controller.send.accessibilityLabel == app.text("停止生成", "Stop generating"), controller.send.isEnabled else { throw NSError(domain: "GenerationStopDependsOnVoice", code: 10) }
    controller.activeMessageID = nil
    controller.voice.setCancelArmed(true); controller.releaseVoiceHold()
    guard controller.input.text == "Existing draft", controller.selectedImage != nil, !controller.voice.isBusy else { throw NSError(domain: "VoiceCancelLostDraftOrImage", code: 11) }
    let late = controller.voice.begin(draft: controller.input.text)!
    controller.releaseVoiceHold()
    guard !controller.voice.start(token: late) else { throw NSError(domain: "LatePermissionStartedRecording", code: 12) }
    let finish = controller.voice.begin(draft: controller.input.text)!
    guard controller.voice.start(token: finish) else { throw NSError(domain: "VoiceRestartFailed", code: 13) }
    controller.voice.receive("番茄炒蛋", token: finish)
    controller.commitVoice(token: finish)
    guard controller.input.text == "Existing draft\n番茄炒蛋", !controller.voiceMode,
      controller.send.accessibilityLabel == app.text("发送", "Send"), controller.send.isEnabled else { throw NSError(domain: "DictationLostDraftOrSendState", code: 14) }
    var speechResult: [String: Any] = ["status": "NOT_RUN_NO_FIXTURE"]
    let fixture = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("assistant-speech-live-fixture.wav")
    if FileManager.default.fileExists(atPath: fixture.path) {
      defer { try? FileManager.default.removeItem(at: fixture) } // Exact task-owned public fixture only.
      if SFSpeechRecognizer.authorizationStatus() == .authorized,
        SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))?.supportsOnDeviceRecognition == true {
        controller.input.text = ""; controller.voiceMode = true
        let live = controller.voice.begin(draft: "")!
        guard controller.voice.start(token: live) else { throw NSError(domain: "FixtureVoiceStartFailed", code: 15) }
        try controller.beginSpeechRecognition(token: live, binding: QFAssistantAgent.scope(app))
        let file = try AVAudioFile(forReading: fixture)
        while file.framePosition < file.length, controller.voice.isCurrent(live) {
          guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024) else { break }
          try file.read(into: buffer)
          controller.speechRequest?.append(buffer)
          try await Task.sleep(nanoseconds: UInt64(Double(buffer.frameLength) / file.processingFormat.sampleRate * 1_000_000_000))
        }
        let beforeRelease = controller.voiceTranscript.text ?? ""
        controller.releaseVoiceHold()
        let deadline = Date().addingTimeInterval(5)
        while controller.voice.isBusy, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        let partials = controller.debugVoicePartials
        speechResult = ["status": controller.input.text.isEmpty ? "RECOGNITION_FAILED" : "RECOGNIZED",
          "publicFixtureTranscript": controller.input.text ?? "", "onDeviceRequired": true,
          "partialResults": partials, "visibleBeforeRelease": beforeRelease,
          "receivedBeforeEndAudio": partials.contains { ($0["beforeEndAudio"] as? Bool) == true },
          "audioBufferRequest": true, "microphoneUsed": false]
        controller.stopCapture()
      } else { speechResult = ["status": "REQUIRES_SPEECH_AUTHORIZATION_OR_LOCAL_ASSET"] }
    }
    var microphoneCheck: [String: Any] = ["status": "NOT_RUN_PERMISSION_REQUIRED", "microphoneUsed": false]
    if AVAudioSession.sharedInstance().recordPermission == .granted, SFSpeechRecognizer.authorizationStatus() == .authorized {
      controller.input.text = "Preserved capture draft"; controller.voiceMode = true
      controller.beginVoiceHold()
      let captureDeadline = Date().addingTimeInterval(4)
      while controller.debugAudioProbe.count == 0, Date() < captureDeadline {
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      let capturedFrames = controller.debugAudioProbe.count
      guard capturedFrames > 0, controller.audioEngine.isRunning, controller.audioTapInstalled else { throw NSError(domain: "MicrophoneLiveInputUnavailable", code: 16) }
      controller.cancelVoiceHold()
      guard !controller.audioEngine.isRunning, !controller.audioTapInstalled, !controller.ownsAudioSession,
        controller.speechRequest == nil, controller.transcription == nil, !controller.voice.isBusy,
        controller.input.text == "Preserved capture draft" else { throw NSError(domain: "MicrophoneCancelDidNotRelease", code: 17) }
      microphoneCheck = ["status": "CAPTURED_AND_CANCELLED", "microphoneUsed": true,
        "capturedFrames": capturedFrames, "rawAudioSaved": false, "networkUsed": false,
        "engineStopped": true, "tapRemoved": true, "sessionReleased": true, "draftPreserved": true]
      controller.voiceMode = false; controller.updateSendButton()
    }
    var editorialTimings: [[String: Any]] = []
    for question in ["如何避免生熟交叉污染？", "剩菜怎么保存？", "冻肉怎么安全解冻？", "如何判断肉是否熟透？"] {
      let start = Date()
      let response = try await QFAssistantAgent.productHelp(text: question, history: [], knownSources: [], hasImage: false, app: app)
      editorialTimings.append(["question": question, "seconds": Date().timeIntervalSince(start),
        "answered": response != nil, "sources": response?.sources.map(\.id) ?? [], "nativeInferenceUsed": response?.nativeInferenceUsed ?? false])
    }
    let detail = QFCatalogDetailViewController.make(app: app, type: "RECIPE", id: "00000000-0000-4000-8000-000000000001")
    guard detail is QFHomeRecipeDetailViewController, !detail.isViewLoaded else { throw NSError(domain: "RecipeEntryNotCanonical", code: 9) }
    return ["thinkingSweep": true, "disclosureWidth": thinking.debugDisclosureWidth, "instantAnalysisToggle": true,
      "composerImage": true, "messageImage": true, "imageScopeIsolated": true,
      "independentVoiceAndSendState": true, "livePartialReplacement": true, "slideCancelPreservesDraftAndImage": true, "lateAuthorizationInvalidated": true, "dictationPreservesDraft": true,
      "canonicalRecipeController": true, "modelCalls": false, "microphoneCheck": microphoneCheck,
      "speechAuthorization": SFSpeechRecognizer.authorizationStatus().rawValue,
      "speechFixture": speechResult, "editorialKnowledgeTimings": editorialTimings,
      "onDeviceSpeechSupported": SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))?.supportsOnDeviceRecognition ?? false]
  }
  /// Exercise the actual input/send/history/render path without saving fixture
  /// messages to the user's account. No cloud inference is requested.
  static func debugCollectLocalDialogue(app: QFAppSession, questions: [String],
    receive: ([String: Any]) -> Void) async throws {
    let controller = QFDigitalAssistantConversationViewController(app: app, applicationState: { .active }, persistConversation: false)
    let window: UIWindow
    if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window = UIWindow(windowScene: scene) }
    else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 414, height: 896)) }
    window.rootViewController = UINavigationController(rootViewController: controller); window.isHidden = false
    defer { controller.endScene(); window.isHidden = true; window.rootViewController = nil }
    try await Task.sleep(nanoseconds: 200_000_000)
    for question in questions {
      let start = Date()
      controller.input.text = question
      controller.textViewDidChange(controller.input)
      guard controller.send.isEnabled, controller.inputPlaceholder.isHidden else { throw NSError(domain: "DialogueComposerUnavailable", code: 4) }
      controller.send.sendActions(for: .touchUpInside)
      guard let id = controller.activeMessageID else { throw NSError(domain: "DialogueSendNotStarted", code: 1) }
      let deadline = Date().addingTimeInterval(210)
      var firstOutputAt: Date?
      while controller.activeMessageID == id, Date() < deadline {
        if firstOutputAt == nil, controller.messages.first(where: { $0.id == id })?.text.isEmpty == false { firstOutputAt = Date() }
        try await Task.sleep(nanoseconds: 200_000_000)
      }
      guard let message = controller.messages.first(where: { $0.id == id }), message.state == "complete" else {
        throw NSError(domain: "DialogueUIRequestFailed", code: 2, userInfo: [NSLocalizedDescriptionKey:
          controller.messages.first(where: { $0.id == id })?.notice ?? "No completed UI reply"])
      }
      let generationFinished = Date()
      while controller.reveals[id]?.isComplete == false, Date().timeIntervalSince(generationFinished) < 20 {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      controller.renderMessages(); controller.view.layoutIfNeeded()
      guard controller.displayedText(for: id) == message.text else { throw NSError(domain: "DialogueUIRenderedWrongAnswer", code: 3) }
      receive(["question": question, "answer": message.text, "renderedMatchesAnswer": true,
        "elapsedSeconds": generationFinished.timeIntervalSince(start), "notice": message.notice ?? "",
        "firstVisibleUpperBoundSeconds": (firstOutputAt ?? generationFinished).timeIntervalSince(start),
        "presentationTailSeconds": Date().timeIntervalSince(generationFinished),
        "sourceIDs": (message.sources ?? []).map(\.id), "actionTypes": (message.actions ?? []).map(\.type),
        "nativeMetrics": (message.sources ?? []).contains(where: { $0.id == "knowledge:guide-assistant" }) ? [:] : (QFOnDeviceInference.latestMetrics ?? [:])])
    }
  }

  /// An isolated real-UIKit check. No submitted prompts, business calls or user
  /// conversation persistence; the ephemeral window is released on every exit.
  static func debugCheckStreamingViewport(app: QFAppSession) async throws -> [String: Any] {
    let controller = QFDigitalAssistantConversationViewController(app: app, applicationState: { .active }, persistConversation: false)
    let window: UIWindow
    if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
      window = UIWindow(windowScene: scene)
    } else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 414, height: 896)) }
    window.rootViewController = UINavigationController(rootViewController: controller)
    window.isHidden = false
    defer { controller.pausePresentation(); window.isHidden = true; window.rootViewController = nil }
    controller.loadViewIfNeeded()
    controller.debugViewportEvents = []
    try await Task.sleep(nanoseconds: 200_000_000) // finish presentation lifecycle before the gesture
    guard !controller.send.isEnabled, !controller.inputPlaceholder.isHidden else {
      throw NSError(domain: "ChatEmptyComposerEnabled", code: 5)
    }
    controller.messages = (0..<12).map { n in
      .init(id: UUID(), role: n.isMultiple(of: 2) ? "user" : "assistant",
        text: "\(n) " + String(repeating: "A public cooking example. ", count: 15), createdAt: Date(), state: "complete")
    }
    let id = UUID()
    controller.messages.append(.init(id: id, role: "assistant", text: "Answer", createdAt: Date(), state: "streaming"))
    controller.activeMessageID = id
    controller.updateSendButton()
    guard controller.send.isEnabled, !controller.modeButton.isEnabled else { throw NSError(domain: "ChatGeneratingControls", code: 6) }
    window.layoutIfNeeded(); controller.view.layoutIfNeeded(); controller.renderMessages()
    try await Task.sleep(nanoseconds: 100_000_000)
    let table = controller.messagesScroll
    let bottom = table.contentOffset.y
    guard bottom > 300 else { throw NSError(domain: "ChatViewportNoScrollableContent", code: 1) }
    controller.scrollViewWillBeginDragging(table)
    table.setContentOffset(CGPoint(x: 0, y: bottom - 40), animated: false)
    controller.scrollViewDidScroll(table)
    table.layoutIfNeeded()
    // Self-sizing rows can refine their internal content y after this manual
    // scroll. Compare the visible message and its screen position, just as the
    // settled-reading assertion below, rather than the estimated raw offset.
    let duringPosition = controller.readingPosition()
    controller.messages[controller.messages.count - 1].text = String(repeating: "New actual reply text. ", count: 30)
    let during = table.contentOffset.y
    controller.scheduleStreamRender()
    try await Task.sleep(nanoseconds: 150_000_000)
    let duringAfter = controller.readingPosition()
    let duringOffsetDelta = table.contentOffset.y - during
    guard !controller.followLatest, duringPosition.id == duringAfter.id,
      abs(duringAfter.relativeY - duringPosition.relativeY) < 2 else {
      throw NSError(domain: "ChatViewportDraggedBackDuringStream", code: 2, userInfo: [NSLocalizedDescriptionKey:
        "follow=\(controller.followLatest), anchor=\(duringPosition.id == duringAfter.id), relativeDelta=\(duringAfter.relativeY - duringPosition.relativeY), offsetDelta=\(duringOffsetDelta), trace=\(controller.debugViewportEvents ?? [])"])
    }
    // Continue reading an earlier row after the finger/deceleration has stopped.
    table.setContentOffset(CGPoint(x: 0, y: max(0, bottom - 500)), animated: false)
    controller.scrollViewDidEndDragging(table, willDecelerate: false)
    // UITableView may refine estimated row heights on the next layout pass.
    // Judge the visible message/relative position, not its internal content y.
    try await Task.sleep(nanoseconds: 100_000_000)
    let settled = controller.readingPosition()
    controller.traceViewport("settled")
    controller.messages[controller.messages.count - 1].text += String(repeating: "More reply text. ", count: 40)
    controller.scheduleStreamRender()
    try await Task.sleep(nanoseconds: 150_000_000)
    let after = controller.readingPosition()
    guard !controller.followLatest, after.id == settled.id, abs(after.relativeY - settled.relativeY) < 2 else {
      throw NSError(domain: "ChatViewportReadingPositionLost", code: 3, userInfo: [NSLocalizedDescriptionKey:
        "follow=\(controller.followLatest), anchor=\(settled.id == after.id), relativeDelta=\(after.relativeY - settled.relativeY), offsetDelta=\(after.offset.y - settled.offset.y), trace=\(controller.debugViewportEvents ?? [])"])
    }
    controller.jumpButton.sendActions(for: .touchUpInside)
    guard controller.distanceFromBottom < 2 else { throw NSError(domain: "ChatViewportExplicitJumpFailed", code: 4) }
    let partial = controller.messages.last?.text
    controller.input.text = "An unsent public draft"
    controller.textViewDidChange(controller.input)
    controller.send.sendActions(for: .touchUpInside)
    guard controller.activeMessageID == nil, controller.messages.last?.state == "stopped",
      controller.messages.last?.text == partial, controller.input.text == "An unsent public draft",
      controller.modeButton.isEnabled else { throw NSError(domain: "ChatStopLostTextOrDraft", code: 7) }
    var benchmarks: [[String: Any]] = []
    var frames: [Double] = [], intervals: [Double] = [], p95 = 0.0
    for rate: Float in [30, 60] {
      controller.debugFrameRate = rate
      let streamID = UUID()
      controller.messages = [.init(id: streamID, role: "assistant", text: "", createdAt: Date(), state: "streaming")]
      controller.activeMessageID = streamID; controller.reveals.removeAll(); controller.scrollFollow.jumpToLatest(); controller.renderMessages()
      controller.debugRevealFrames = []
      for _ in 0..<20 {
        controller.messages[0].text += "实际收到的文字逐步显示。"
        controller.scheduleStreamRender(metadataChanged: false)
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      try await Task.sleep(nanoseconds: 900_000_000)
      guard controller.displayedText(for: streamID) == controller.messages[0].text,
        let liveCell = table.cellForRow(at: IndexPath(row: 0, section: 0)) as? QFAssistantChatCell,
        !liveCell.hasTextFade, controller.revealDisplayLink == nil else { throw NSError(domain: "DisplayRevealDidNotSettle", code: 8) }
      frames = controller.debugRevealFrames ?? []
      intervals = zip(frames.dropFirst(), frames).map { $0 - $1 }.sorted()
      p95 = intervals.isEmpty ? 0 : intervals[min(intervals.count - 1, Int(Double(intervals.count) * 0.95))]
      benchmarks.append(["configuredHz": rate, "frames": frames.count, "intervalP95Seconds": p95,
        "intervalMeanSeconds": intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count),
        "sameWorkload": "20 received chunks at 50ms intervals; 900ms settle", "settled": true])
      controller.activeMessageID = nil
    }
    return ["duringDragHeld": true, "readingPositionHeld": true, "explicitJumpWorked": true,
      "duringDragRawOffsetDelta": duringOffsetDelta,
      "duringDragRelativeDelta": duringAfter.relativeY - duringPosition.relativeY,
      "emptyComposerDisabled": true, "generatingControls": true, "stopKeptPartialAndDraft": true,
      "sameWorkloadFrameRateComparison": benchmarks,
      "displayLinkFrames": frames.count, "frameIntervalP95Seconds": p95,
      "frameIntervalMeanSeconds": intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count),
      "realTextAppendAndFadeSettled": true, "displayLinkReleased": true,
      "persistence": false, "modelCalls": false]
  }
#endif
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { messages.count }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "chat", for: indexPath) as! QFAssistantChatCell
    let item = messages[indexPath.row], binding = conversationBinding
    cell.configure(item, app: app, expanded: expandedProcess.contains(item.id), displayText: reveals[item.id]?.visible, actionTitle: actionTitle)
    cell.configureImage(conversationStore.imageURL(item.imageID), app: app)
    cell.onImage = { [weak self] url in
      guard let self, self.conversationBinding == binding else { return }
      guard let image = UIImage(contentsOfFile: url.path) else { QFOperationHUD.toast(self.app.text("图片加载失败", "Image failed to load"), in: self.view); return }
      self.stopCapture(); self.present(QFContentImagePreviewController(image: image, app: self.app), animated: true)
    }
    cell.onToggle = { [weak self] in
      guard let self else { return }
      if self.expandedProcess.contains(item.id) { self.expandedProcess.remove(item.id) } else { self.expandedProcess.insert(item.id) }
      if self.expandedProcess.contains(item.id) { self.manuallyExpandedProcess.insert(item.id) }
      else { self.manuallyExpandedProcess.remove(item.id) }
      if item.id != self.messages.last?.id { self.scrollFollow.keepReading() }
      self.renderMessages(forceWhileReading: true)
    }
    cell.onSource = { [weak self] source in guard let self, QFAssistantAgent.scope(self.app) == binding else { return }; self.openSource(source) }
    cell.onAction = { [weak self] action in guard let self, QFAssistantAgent.scope(self.app) == binding else { return }; self.openAgentAction(action) }
    cell.onRetry = { [weak self] in
      guard let self, self.activeMessageID == nil, self.conversationBinding == binding, let text = item.retryText else { return }
      guard self.input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, self.selectedImage == nil else {
        QFOperationHUD.toast(self.app.text("请先处理当前草稿，再重试这条问题。", "Finish the current draft before retrying this question."), in: self.view); return
      }
      self.input.text = text; self.textViewDidChange(self.input); self.sendMessage()
    }
    return cell
  }

  private func actionTitle(_ action: QFAgentAction) -> String {
    switch action.type {
    case "WEEKLY_PLAN_PROPOSAL": return app.text("核对七天方案与补购清单", "Review seven-day plan and shopping list")
    case "PLAN_DRAFT": return app.text("核对计划草稿（尚未保存）", "Review plan draft (not saved)")
    case "NAVIGATE_PLAN": return app.text("打开饮食计划", "Open meal plans")
    case "NAVIGATE_INVENTORY": return app.text("打开食材库存", "Open ingredient stock")
    case "NAVIGATE_RECIPES": return app.text("打开菜谱", "Open recipes")
    case "NAVIGATE_MODEL_SETTINGS": return app.text("模型管理", "Manage model")
    default: return app.text("记忆管理", "Manage memory")
    }
  }

  private func openSource(_ source: QFAgentSource) {
    stopCapture()
    if source.id.hasPrefix("recipe:"), let uuid = UUID(uuidString: String(source.id.dropFirst(7))) {
      openAgentAction(.init(type: "OPEN_RECIPE", recipeID: uuid.uuidString.lowercased(), date: nil))
    } else if source.id.hasPrefix("plan-slot:") {
      let parts = source.id.components(separatedBy: ":")
      navigateToTab(1, date: parts.count == 4 ? parts[2] : nil)
    } else if source.id.hasPrefix("inventory-lot:") {
      navigateToTab(2)
    } else if source.id.hasPrefix("knowledge:"), source.url == nil {
      let binding = QFAssistantAgent.scope(app)
      navigationTask?.cancel()
      navigationTask = Task { [weak self] in
        guard let self, let hit = try? await QFAssistantKnowledge.shared.lookup(sourceID: source.id, language: binding.language),
          !Task.isCancelled, QFAssistantAgent.scope(self.app) == binding else { return }
        let preview = UIAlertController(title: hit.title, message: hit.body, preferredStyle: .alert)
        preview.addAction(UIAlertAction(title: self.app.text("关闭", "Close"), style: .cancel))
        self.present(preview, animated: true)
      }
    } else if let raw = source.url, let url = URL(string: raw), url.scheme == "https", url.host != nil {
      present(SFSafariViewController(url: url), animated: true)
    }
  }

  private func openAgentAction(_ action: QFAgentAction) {
    stopCapture()
    switch action.type {
    case "WEEKLY_PLAN_PROPOSAL":
      guard let id = action.proposalID, UUID(uuidString: id) != nil else { return }
      let binding = QFAssistantAgent.scope(app)
      navigationTask?.cancel()
      navigationTask = Task { [weak self] in
        guard let self else { return }
        do {
          let proposal = try await self.app.weeklyPlanProposal(id)
          try Task.checkCancellation()
          guard QFAssistantAgent.scope(self.app) == binding,
            proposal.householdId == binding.household, proposal.language == binding.language else { return }
          self.qfPush(QFWeeklyPlanProposalViewController(app: self.app, proposal: proposal, appendAndShop: true, onUpdate: { _ in }, onAccepted: { [weak self] in
            guard let self, QFAssistantAgent.scope(self.app) == binding else { return }
            if let index = self.messages.firstIndex(where: { $0.actions?.contains(where: { $0.proposalID == id }) == true }) {
              self.messages[index].text = self.app.text("七天方案已保存到饮食计划，补购清单已按库存生成。已有餐次和完成记录已保留。", "The seven-day proposal is saved and its shopping list has been generated from inventory. Existing meals and completed records are preserved.")
              self.messages[index].actions = [.init(type: "NAVIGATE_PLAN", recipeID: nil, date: proposal.weekStart)]
              self.conversationStore.save(self.messages); self.renderMessages()
            }
          }))
        } catch is CancellationError { }
        catch { QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self.view) }
      }
    case "NAVIGATE_RECIPES": navigateToTab(0)
    case "NAVIGATE_PLAN": navigateToTab(1)
    case "NAVIGATE_INVENTORY": navigateToTab(2)
    case "NAVIGATE_MODEL_SETTINGS":
      present(UINavigationController(rootViewController: QFLocalModelViewController(app: app)), animated: true)
    case "NAVIGATE_MEMORY":
      present(QFDigitalAssistantMemoryViewController(app: app), animated: true)
    case "OPEN_RECIPE", "PLAN_DRAFT":
      guard let id = action.recipeID, UUID(uuidString: id) != nil else { return }
      if action.type == "OPEN_RECIPE" {
        navigationTask?.cancel(); navigationTask = nil
        qfPush(QFHomeRecipeDetailViewController(app: app, recipeID: id))
        return
      }
      let binding = QFAssistantAgent.scope(app), generation = requestGeneration
      navigationTask?.cancel()
      navigationTask = Task { [weak self] in
        guard let self else { return }
        do {
          let detail: QFRecipeHomeDetail = try await self.app.publicContentRequest(path: "home/recipes/\(id)")
          try Task.checkCancellation()
          guard self.requestGeneration == generation, QFAssistantAgent.scope(self.app) == binding,
            UUID(uuidString: detail.id) == UUID(uuidString: id), detail.contentAvailable == true,
            detail.contentLanguage == self.app.interfaceLanguage else { throw CancellationError() }
          if action.type == "PLAN_DRAFT" {
            guard let date = action.date, QFAgentPlan.validDate(date), let meal = action.meal,
              QFManualPlanDraft.meals.contains(meal) else { return }
            var seed = QFManualPlanDraft(date: date)
            seed.recipes[meal] = [.init(id: detail.id, title: detail.title, subtitle: detail.subtitle,
              mediaId: detail.mediaId, minutes: detail.minutes, language: self.app.interfaceLanguage)]
            self.qfPush(QFCreatePlanViewController(app: self.app, initialDate: Date(), assistantSeed: seed, saved: {}))
          }
        } catch is CancellationError { }
        catch {
          guard self.requestGeneration == generation else { return }
          QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self.view)
        }
      }
    default: break
    }
  }

  private func navigateToTab(_ index: Int, date: String? = nil) {
    stopCapture()
    navigationTask?.cancel(); navigationTask = nil
    let presentation = navigationController ?? self
    guard !presentation.isBeingDismissed else { return }
    // Full-screen presentation can be owned by QFRootViewController, whose
    // child is the Tab controller. Use the host that opened this conversation.
    var tabs = tabNavigationHost
    var candidate = presentation.presentingViewController
    while tabs == nil, let controller = candidate {
      if let found = controller as? UITabBarController { tabs = found; break }
      if let found = controller.tabBarController { tabs = found; break }
      candidate = controller.presentingViewController
    }
    guard let tabs, (tabs.viewControllers ?? []).indices.contains(index) else { return }
    let completion = onDismiss; onDismiss = nil
    presentation.dismiss(animated: true) {
      tabs.selectedIndex = index
      if let date, index == 1, let navigation = tabs.viewControllers?[index] as? UINavigationController,
        let plan = navigation.viewControllers.first as? QFPlanViewController, !plan.openAssistantDay(date) {
        QFOperationHUD.toast(self.app.text("请先完成或保留当前编辑，返回后会打开所选日期。", "Finish or keep the current edit first; the selected date will open when you return."), in: tabs.view)
      }
      completion?()
    }
  }

  private func refreshModeButton() {
    modeButton.setTitle(selectedProvider == .glmFree ? "GLM  ▾" : "DeepSeek  ▾", for: .normal)
    modeButton.setTitleColor(QFUI.primary, for: .normal)
    modeButton.backgroundColor = QFUI.primary.withAlphaComponent(0.10)
    modeButton.accessibilityLabel = app.text("切换 AI 模式", "Switch AI mode")
    modeButton.accessibilityValue = selectedProvider == .glmFree ? app.text("GLM · 免费", "GLM · Free") : "DeepSeek"
  }

  @objc private func toggleMode() {
    stopCapture()
    let menu = UIAlertController(title: app.text("切换 AI 模式", "Switch AI mode"), message: nil, preferredStyle: .actionSheet)
    menu.addAction(UIAlertAction(title: app.text("GLM · 免费", "GLM · Free"), style: .default) { [weak self] _ in self?.selectMode(provider: .glmFree) })
    menu.addAction(UIAlertAction(title: "DeepSeek", style: .default) { [weak self] _ in self?.selectMode(provider: .deepSeek) })
    menu.addAction(UIAlertAction(title: app.text("模型管理", "Manage model"), style: .default) { [weak self] _ in
      guard let self else { return }
      let navigation = UINavigationController(rootViewController: QFLocalModelViewController(app: self.app))
      navigation.modalPresentationStyle = .pageSheet; self.present(navigation, animated: true)
    })
    menu.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    menu.popoverPresentationController?.sourceView = modeButton
    menu.popoverPresentationController?.sourceRect = modeButton.bounds
    present(menu, animated: true)
  }

  private func selectMode(provider: QFAssistantProvider) {
    guard activeMessageID == nil else { return }
    stopCapture(); selectedProvider = provider; refreshModeButton()
    guard provider.available(in: app.configuration?.assistantCapabilities?.chatProviders) else {
      QFOperationHUD.toast(app.text("所选模型暂不可用，请稍后重试。", "The selected model is unavailable. Please try again later."), in: view)
      return
    }
    guard provider.requiresCredits else {
      QFOperationHUD.toast(app.text("已切换到免费 GLM。", "Free GLM selected."), in: view)
      return
    }
    QFOperationHUD.toast(app.text("正在检查云端额度…", "Checking cloud credits…"), in: view)
    let binding = conversationBinding
    Task { [weak self] in
      guard let self else { return }
      do {
        let snapshot = try await app.assistantCreditSnapshot()
        guard self.selectedProvider == provider, self.conversationBinding == binding,
          QFAssistantAgent.scope(self.app) == binding else { return }
        let copy = snapshot.billingEnabled
          ? app.format("云端已就绪，剩余 %d 积分。", "Cloud ready; %d credits remaining.", snapshot.balanceUnits)
          : app.text("云端已就绪，当前使用测试额度。", "Cloud ready; test allowance is active.")
        QFOperationHUD.toast(copy, in: self.view)
      } catch {
        guard self.selectedProvider == provider, self.conversationBinding == binding else { return }
        QFOperationHUD.toast(app.text("暂时无法获取云端额度。", "Cloud credits are temporarily unavailable."), in: self.view)
      }
    }
  }

  @objc private func dismissKeyboard() { view.endEditing(true) }

  @objc private func sendMessage() {
    if activeMessageID != nil { cancelRequest(); return }
    guard !voice.isBusy else { return }
    guard conversationBinding == QFAssistantAgent.scope(app) else { reloadConversationScope(); return }
    guard selectedProvider.available(in: app.configuration?.assistantCapabilities?.chatProviders) else {
      QFOperationHUD.toast(app.text("所选模型暂不可用，请稍后重试。", "The selected model is unavailable. Please try again later."), in: view)
      return
    }
    guard !UserDefaults.standard.bool(forKey: cloudConsentKey) else {
      sendMessageAfterSend(cloud: true)
      return
    }
    let consentBinding = conversationBinding, consentKey = cloudConsentKey, consentProvider = selectedProvider
    let confirm = UIAlertController(
      title: app.text("允许云端处理？", "Allow cloud processing?"),
      message: app.format("本轮文字、图片、对话上下文及经授权读取的相关计划或库存会交给 %@ 处理。保存或修改仍需你确认。", "Your text, images, conversation context and relevant plans or inventory read with permission will be processed by %@. Saving or changing data still requires your confirmation.", selectedProvider == .glmFree ? "GLM" : "DeepSeek"),
      preferredStyle: .alert)
    confirm.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    confirm.addAction(UIAlertAction(title: app.text("同意并发送", "Agree and send"), style: .default) { [weak self] _ in
      guard let self, self.selectedProvider == consentProvider, self.conversationBinding == consentBinding, QFAssistantAgent.scope(self.app) == consentBinding else { return }
      UserDefaults.standard.set(true, forKey: consentKey)
      self.sendMessageAfterSend(cloud: true)
    })
    present(confirm, animated: true)
  }

  private func sendMessageAfterSend(cloud: Bool) {
    let value = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !voice.isBusy else { return }
    guard !value.isEmpty || selectedImage != nil else { return }
    if !cloud {
      guard QFLocalModelStore.shared.state == .ready || QFAssistantWeeklyPlanIntent.matches(value) else {
        QFOperationHUD.toast(app.text("请先在模型管理中下载并校验千问模型。", "Download and verify Qwen in Manage model first."), in: view)
        return
      }
      guard selectedImage == nil else {
        QFOperationHUD.toast(app.text("本地模式当前支持文字，请移除图片或选择云端模式。", "Local mode currently supports text. Remove the image or select cloud mode."), in: view)
        return
      }
    }
    if !cloud, value.utf8.count > 1200 {
      QFOperationHUD.toast(app.text("内容超过本地模型上下文，请缩短本次问题。", "The message exceeds the local context. Please shorten your question."), in: view)
      return
    }
    stopCapture()
    QFDigitalAssistantNudgeScheduler.recordAppUse(for: app)
    let imageQuestion = app.text("请根据图片内容给出饮食建议或生成待确认草稿。", "Analyze this image and give diet advice or make a reviewable draft.")
    let history: [QFOnDeviceInference.Turn]
    do {
      if !cloud, conversationStore.nativeCapacityReached { throw QFAgentConversationContext.Invalid.capacity }
      let previous = try conversationStore.history(messages, imageQuestion: imageQuestion)
      history = try QFAgentConversationContext.preserving(previous).map {
        .init(role: $0.role, content: $0.content)
      }
    } catch {
      let alert = UIAlertController(title: app.text("开启新对话？", "Start a new conversation?"),
        message: app.text("当前对话已达上下文容量，本轮尚未发送。开启新对话会保留现有聊天记录，从这条消息开始新的上下文；请重新说明过敏等重要要求。", "This conversation has reached its context capacity; nothing was sent. Starting a new conversation keeps existing chat and begins a new context with this message. Restate important requirements such as allergies."), preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
      let contextBinding = conversationBinding
      alert.addAction(UIAlertAction(title: app.text("开启并发送", "Start and send"), style: .default) { [weak self] _ in
        guard let self, self.conversationBinding == contextBinding,
          QFAssistantAgent.scope(self.app) == contextBinding else { return }
        self.conversationStore.beginNewContext(after: self.messages.last?.id)
        self.sendMessageAfterSend(cloud: cloud)
      })
      present(alert, animated: true)
      return
    }
    let known = conversationStore.knownSources(messages)
    let imageData = selectedImageData, mimeType = selectedImageMimeType
    let imageID: String?
    do { imageID = try imageData.map { try conversationStore.saveImage($0) } }
    catch { QFOperationHUD.toast(QFProfileContentController.errorText(error, app: app), in: view); return }
    let question = value.isEmpty ? imageQuestion : value
    append(role: "user", text: value, imageID: imageID)
    onCharacterIntent?(QFAssistantCharacterIntent.from(text: value))
    input.text = ""; textViewDidChange(input)
    selectedImage = nil; selectedImageData = nil; attachment.isHidden = true; removeAttachment.isHidden = true
    refreshImagePreview()
    requestTask?.cancel(); let generation = UUID(); requestGeneration = generation
    let binding = conversationBinding, id = UUID(), provider = selectedProvider
    activeMessageID = id; scrollFollow.jumpToLatest()
    messages.append(.init(id: id, role: "assistant", text: "", createdAt: Date(), state: "streaming",
      process: [.init(stage: "preparing", state: "running")], retryText: imageData == nil ? value : nil,
      analysis: QFAssistantQuestionAnalysis.summary(text: question, hasImage: imageData != nil, app: app)))
    conversationStore.save(messages); updateSendButton()
    if followLatest { renderMessages() } else { deferredStreamRender = true; jumpButton.isHidden = false }
    requestTask = Task { [weak self] in
      guard let self else { return }
      @MainActor func currentIndex() -> Int? {
        guard !Task.isCancelled, self.requestGeneration == generation,
          QFAssistantAgent.scope(self.app) == binding, self.activeMessageID == id else { return nil }
        return self.messages.firstIndex(where: { $0.id == id })
      }
      do {
        if imageData == nil, let plan = try await QFAssistantAgent.weeklyPlan(text: question, cloud: cloud, requestID: id, app: self.app, provider: provider,
          progress: { [weak self] stage in guard let self, let index = currentIndex() else { return }; self.setProcess(stage: stage, index: index) }) {
          guard let index = currentIndex() else { return }
          self.messages[index].text = plan.answer; self.messages[index].sources = plan.sources
          self.messages[index].actions = plan.actions; self.messages[index].notice = plan.notice
          self.completeMessage(index: index)
        } else if cloud, imageData == nil, let help = try await QFAssistantAgent.productHelp(text: question, history: history,
          knownSources: known, hasImage: imageData != nil, app: self.app) {
          guard let index = currentIndex() else { return }
          self.messages[index].text = help.answer
          self.messages[index].sources = help.sources; self.messages[index].actions = help.actions
          self.messages[index].notice = help.notice
          self.completeMessage(index: index)
        } else if cloud {
          let response = try await self.app.assistantStream(text: question, history: history, imageData: imageData, mimeType: mimeType, provider: provider) { [weak self] event in
            guard let self, let index = currentIndex() else { return }
            switch event {
            case .status(let stage): self.setProcess(stage: stage, index: index)
            case .delta(let text):
              let first = self.messages[index].text.isEmpty && !text.isEmpty
              self.messages[index].text += text
              if first { self.answerBegan(id: id) }
              self.scheduleStreamRender(metadataChanged: first)
            case .reasoning(let text):
              self.messages[index].reasoning = QFAgentText.limit((self.messages[index].reasoning ?? "") + text, utf8: 65_536)
              self.scheduleStreamRender()
            }
          }
          guard let index = currentIndex() else { return }
          self.messages[index].text = response.answer
          self.messages[index].sources = response.sources; self.messages[index].actions = response.actions
          if QFAgentPlan.mayNeedRecipeLookup(question), (response.sources ?? []).allSatisfy({ !$0.id.hasPrefix("recipe:") }), response.actions?.isEmpty != false {
            self.messages[index].actions = [.init(type: "NAVIGATE_RECIPES", recipeID: nil, date: nil)]
          }
          self.messages[index].notice = response.notice
          self.completeMessage(index: index)
        } else {
          let response = try await QFAssistantAgent.answer(text: value, history: history, knownSources: known, app: self.app,
            progress: { [weak self] stage in
              guard let self, let index = currentIndex() else { return }; self.setProcess(stage: stage, index: index)
            }, onOutput: { [weak self] text in
              Task { @MainActor in
                guard let self, self.requestGeneration == generation, self.activeMessageID == id,
                  QFAssistantAgent.scope(self.app) == binding, let index = self.messages.firstIndex(where: { $0.id == id }) else { return }
                let first = self.messages[index].text.isEmpty && !text.isEmpty
                self.messages[index].text = text
                if first { self.answerBegan(id: id) }
                self.scheduleStreamRender(metadataChanged: first)
              }
            })
          guard let index = currentIndex() else { return }
          self.messages[index].text = response.answer
          self.messages[index].sources = response.sources; self.messages[index].actions = response.actions
          self.messages[index].notice = response.notice
          self.completeMessage(index: index)
        }
      } catch {
        guard let index = currentIndex() else { return }
        self.finishProcess(index: index, state: error is CancellationError ? "stopped" : "failed")
        let copy: String
        if let failure = error as? QFOnDeviceInference.Failure {
          switch failure {
          case .contextTooLong:
            self.conversationStore.markNativeCapacityReached()
            copy = self.app.text("内容超过本地模型上下文，请缩短本次问题。", "The message exceeds the local context. Please shorten your question.")
          case .outputLimit: copy = self.app.text("回答达到本地长度上限，已保留现有内容。请缩小问题范围后重试。", "The local answer reached its length limit. Existing text is kept. Narrow your question and try again.")
          case .timeout: copy = self.app.text("本地生成超时，请稍后重试或缩短问题。", "Local generation timed out. Try again later or shorten the question.")
          case .generation(code: 8, diagnostic: _): copy = self.app.text("设备内存不足，本次回答已停止，已保留现有内容。请稍后重试。", "The device is low on memory, so this answer has stopped. Existing text is kept. Please try again later.")
          case .generation: copy = self.app.text("本地模型未能完成回答，请检查模型或稍后重试。", "The local model could not finish. Check the model or try again later.")
          }
        } else { copy = QFProfileContentController.errorText(error, app: self.app) }
        self.messages[index].notice = copy
        self.activeMessageID = nil; self.requestTask = nil; self.renderTask?.cancel(); self.renderTask = nil
        self.conversationStore.save(self.messages); self.updateSendButton()
        if self.followLatest { self.renderMessages() }
        else { self.deferredStreamRender = true; self.jumpButton.isHidden = false }
        // A failed image request remains editable; never silently retry it as text-only.
        if let imageData, self.input.text.isEmpty, self.selectedImageData == nil {
          self.selectedImageData = imageData; self.selectedImageMimeType = mimeType; self.selectedImage = UIImage(data: imageData)
          self.input.text = value; self.textViewDidChange(self.input)
          self.attachment.text = self.app.text("添加图片", "Add image"); self.attachment.isHidden = false; self.removeAttachment.isHidden = false
          self.refreshImagePreview()
        }
      }
    }
  }

  private func setProcess(stage: String, index: Int) {
    let stage = stage == "context" ? "preparing" : stage
    if messages[index].process?.last?.stage == stage { return }
    if let count = messages[index].process?.count, count > 0 { messages[index].process?[count - 1].state = "complete" }
    messages[index].process = (messages[index].process ?? []) + [.init(stage: stage, state: "running")]
    scheduleStreamRender()
  }
  private func answerBegan(id: UUID) {
    // Respect a user's deliberate inspection. Otherwise the actual answer gets
    // the space as soon as it starts; private reasoning is never manufactured.
    if !manuallyExpandedProcess.contains(id) { expandedProcess.remove(id) }
  }
  private func finishProcess(index: Int, state: String) {
    messages[index].state = state
    messages[index].process = messages[index].process?.map { original in
      var step = original; if step.state == "running" { step.state = state == "complete" ? "complete" : state }; return step
    }
    if let cell = messagesScroll.cellForRow(at: IndexPath(row: index, section: 0)) as? QFAssistantChatCell {
      cell.finishProcessing(state: state, app: app, expanded: expandedProcess.contains(messages[index].id))
    }
  }
  private func completeMessage(index: Int) {
    if viewIfLoaded?.window != nil, applicationState() == .active {
      let id = messages[index].id
      var reveal = reveals[id] ?? QFAssistantTextReveal(initial: displayedText(for: id)); reveal.receive(messages[index].text); reveals[id] = reveal
      startTextReveal()
    } else {
      // A background completion must not leave an unstarted presentation buffer
      // masking the complete answer when the App returns to the foreground.
      reveals.removeValue(forKey: messages[index].id)
    }
    finishProcess(index: index, state: "complete")
    onCharacterIntent?(QFAssistantCharacterIntent.from(text: messages[index].text))
    activeMessageID = nil; requestTask = nil; renderTask?.cancel(); renderTask = nil
    conversationStore.save(messages); updateSendButton()
    if followLatest { renderMessages() } else { deferredStreamRender = true; jumpButton.isHidden = false }
  }
  private func updateSendButton() {
    let running = activeMessageID != nil
    // Sending/generation and dictation have separate controls and state.
    send.setImage(UIImage(systemName: running ? "stop.circle.fill" : "arrow.up.circle.fill"), for: .normal)
    send.accessibilityLabel = running ? app.text("停止生成", "Stop generating") : app.text("发送", "Send")
    send.isEnabled = running || (!voice.isBusy && (!input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedImage != nil))
    send.alpha = send.isEnabled ? 1 : 0.35
    modeButton.isEnabled = !running && !voice.isBusy
    photo.isEnabled = !running && !voice.isBusy; mic.isEnabled = !running && !voice.isBusy
    removeAttachment.isEnabled = !voice.isBusy
    mic.setImage(UIImage(systemName: voiceMode ? "keyboard" : "mic"), for: .normal)
    mic.accessibilityLabel = voiceMode ? app.text("键盘输入", "Keyboard input") : app.text("发送语音", "Voice input")
    mic.accessibilityValue = voiceMode ? app.text("语音输入模式", "Voice input mode") : app.text("文字输入模式", "Text input mode")
    input.isHidden = voiceMode; inputPlaceholder.isHidden = voiceMode || !input.text.isEmpty
    voicePanel.isHidden = !voiceMode
    voiceTranscript.isHidden = !voiceMode
    cancelVoice.isHidden = !voice.isBusy
    let title: String
    switch voice.phase {
    case .idle: title = app.text("按住说话", "Hold to talk")
    case .authorizing: title = app.text("正在准备麦克风…", "Preparing microphone…")
    case .recording:
      title = voice.cancelArmed ? app.text("松开取消", "Release to cancel") : app.text("松开转文字，上滑取消", "Release to transcribe, slide up to cancel")
    case .finishing: title = app.text("正在整理文字…", "Finishing transcription…")
    }
    holdToTalk.setTitle(title, for: .normal)
    holdToTalk.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
    holdToTalk.titleLabel?.adjustsFontSizeToFitWidth = true; holdToTalk.titleLabel?.minimumScaleFactor = 0.75
    holdToTalk.setTitleColor(voice.cancelArmed ? QFUI.danger : QFUI.primary, for: .normal)
    holdToTalk.backgroundColor = (voice.cancelArmed ? QFUI.danger : QFUI.primary).withAlphaComponent(voice.isBusy ? 0.15 : 0.07)
    holdToTalk.isEnabled = !running && voice.phase != .finishing
    holdToTalk.accessibilityLabel = title
    holdToTalk.accessibilityHint = app.text("说话时文字会实时显示，松手后可编辑再发送", "Speech appears live. Release to edit before sending.")
    voiceTranscript.text = voice.transcript.isEmpty ? app.text("说话时文字会实时显示", "Your words appear here as you speak") : voice.transcript
    voiceTranscript.textColor = voice.transcript.isEmpty ? QFUI.secondary : QFUI.text
    voiceTranscript.accessibilityLabel = app.text("实时转写", "Live transcription")
    voiceTranscript.accessibilityValue = voice.transcript
    if !voiceTranscript.isDragging && !voiceTranscript.isDecelerating && !voiceTranscript.text.isEmpty { voiceTranscript.scrollRangeToVisible(NSRange(location: (voiceTranscript.text as NSString).length, length: 0)) }
    let height = input.sizeThatFits(CGSize(width: max(1, input.bounds.width), height: .greatestFiniteMagnitude)).height
    composerHeight?.update(offset: voiceMode ? QFAssistantChatLayout.composerMaxHeight : min(QFAssistantChatLayout.composerMaxHeight, max(44, height)))
  }
  private func append(role: String, text: String, sources: [QFAgentSource] = [], actions: [QFAgentAction] = [], notice: String = "", imageID: String? = nil) {
    messages.append(.init(id: UUID(), role: role, text: text, createdAt: Date(), sources: sources, actions: actions, notice: notice, imageID: imageID))
    conversationStore.save(messages); renderMessages()
  }

  @objc private func selectPhoto() {
    cancelRequest(); attachmentScope = QFAssistantAgent.scope(app)
    var config = PHPickerConfiguration(photoLibrary: .shared()); config.filter = .images; config.selectionLimit = 1
    let picker = PHPickerViewController(configuration: config); picker.delegate = self; present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let binding = attachmentScope, binding == QFAssistantAgent.scope(app) else { return }
    let generation = requestGeneration
    guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
    provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
      Task { @MainActor in
        guard let self, let image = object as? UIImage, self.requestGeneration == generation,
          QFAssistantAgent.scope(self.app) == binding else { return }
        self.selectedImage = image
        let prepared = image.preparingThumbnail(of: CGSize(width: 1600, height: 1600)) ?? image
        self.selectedImage = prepared
        guard let bytes = prepared.jpegData(compressionQuality: 0.82), bytes.count <= 8 * 1024 * 1024 else {
          self.selectedImage = nil
          QFOperationHUD.toast(self.app.text("图片加载失败", "Image failed to load"), in: self.view); return
        }
        self.selectedImageData = bytes
        self.selectedImageMimeType = "image/jpeg"
        self.attachment.text = self.app.text("已选择图片，将在发送时提取文字", "Image selected; text will be extracted when sending")
        self.attachment.isHidden = false; self.removeAttachment.isHidden = false
        self.updateSendButton()
        self.refreshImagePreview()
        self.extractText(from: image)
      }
    }
  }

  private func extractText(from image: UIImage) {
    guard let cgImage = image.cgImage else { return }
    let binding = QFAssistantAgent.scope(app), generation = requestGeneration
    let request = VNRecognizeTextRequest { [weak self] request, _ in
      let text = (request.results as? [VNRecognizedTextObservation] ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      Task { @MainActor in
        guard let self, self.requestGeneration == generation, QFAssistantAgent.scope(self.app) == binding,
          !self.voice.isBusy, self.input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.input.text = text; self.textViewDidChange(self.input)
        self.attachment.text = self.app.text("图片文字已提取，可编辑后发送", "Image text extracted; edit before sending")
      }
    }
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = true
    DispatchQueue.global(qos: .userInitiated).async {
      try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
    }
  }

  private func setupVoicePanel() {
    composer.addSubview(voicePanel)
    voicePanel.snp.makeConstraints { $0.edges.equalTo(input) }
    voicePanel.isHidden = true
    voiceTranscript.font = .preferredFont(forTextStyle: .body)
    voiceTranscript.adjustsFontForContentSizeCategory = true
    voiceTranscript.textColor = QFUI.text; voiceTranscript.backgroundColor = .clear
    voiceTranscript.isEditable = false; voiceTranscript.isSelectable = true
    voiceTranscript.textContainerInset = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
    voiceTranscript.accessibilityIdentifier = "assistant.voice-live-transcript"
    voicePanel.addSubview(voiceTranscript)
    voicePanel.addSubview(holdToTalk); voicePanel.addSubview(cancelVoice)
    holdToTalk.snp.makeConstraints { $0.leading.trailing.bottom.equalToSuperview(); $0.height.equalTo(44) }
    voiceTranscript.snp.makeConstraints { $0.leading.top.equalToSuperview(); $0.trailing.equalTo(cancelVoice.snp.leading); $0.bottom.equalTo(holdToTalk.snp.top) }
    cancelVoice.snp.makeConstraints { $0.top.trailing.equalToSuperview(); $0.size.equalTo(44) }
    cancelVoice.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
    cancelVoice.tintColor = QFUI.secondary; cancelVoice.accessibilityLabel = app.text("取消", "Cancel")
    cancelVoice.accessibilityIdentifier = "assistant.voice-cancel"
    cancelVoice.addAction(UIAction { [weak self] _ in self?.cancelVoiceHold() }, for: .touchUpInside)
    holdToTalk.layer.cornerRadius = 14
    holdToTalk.titleLabel?.font = .preferredFont(forTextStyle: .body)
    holdToTalk.titleLabel?.adjustsFontForContentSizeCategory = true
    holdToTalk.accessibilityIdentifier = "assistant.voice-hold"
    let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleVoiceHold(_:)))
    hold.minimumPressDuration = 0.12; hold.allowableMovement = .greatestFiniteMagnitude
    holdToTalk.addGestureRecognizer(hold)
    // VoiceOver offers an equivalent two-activation start/finish interaction.
    holdToTalk.addAction(UIAction { [weak self] _ in
      guard UIAccessibility.isVoiceOverRunning, let self else { return }
      if self.voice.phase == .recording { self.releaseVoiceHold() }
      else if !self.voice.isBusy { self.beginVoiceHold() }
    }, for: .touchUpInside)
  }

  @objc private func toggleVoiceMode() {
    stopCapture()
    voiceMode.toggle()
    if voiceMode { input.resignFirstResponder() }
    updateSendButton(); textViewDidChange(input)
    if !voiceMode { input.becomeFirstResponder() }
    else { requestVoicePermissions() }
  }

  private func requestVoicePermissions() {
    let binding = QFAssistantAgent.scope(app)
    guard AVAudioSession.sharedInstance().recordPermission != .granted || SFSpeechRecognizer.authorizationStatus() != .authorized else { return }
    AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
      Task { @MainActor in
        guard let self, self.voiceMode, self.canCapture, self.applicationState() == .active, QFAssistantAgent.scope(self.app) == binding else { return }
        guard granted else { self.voiceFailed(self.app.text("请允许麦克风权限", "Allow microphone access")); return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
          Task { @MainActor in
            guard let self, self.voiceMode, self.canCapture, self.applicationState() == .active, QFAssistantAgent.scope(self.app) == binding else { return }
            guard status == .authorized else {
              self.voiceFailed(self.app.text("语音转写不可用，请输入文字。", "Voice transcription is unavailable. Please type your message.")); return
            }
            QFOperationHUD.toast(self.app.text("语音权限已就绪，按住说话", "Voice permissions ready. Hold to talk."), in: self.view)
          }
        }
      }
    }
  }

  @objc private func handleVoiceHold(_ gesture: UILongPressGestureRecognizer) {
    guard !UIAccessibility.isVoiceOverRunning else { return }
    // Measure in the window: expanding the transcript must not move the cancel threshold.
    let location = gesture.location(in: view.window)
    switch gesture.state {
    case .began:
      holdOrigin = location; beginVoiceHold()
    case .changed:
      let armed = location.y < holdOrigin.y - 64
      if voice.cancelArmed != armed {
        voice.setCancelArmed(armed); UISelectionFeedbackGenerator().selectionChanged(); updateSendButton()
      }
    case .ended: releaseVoiceHold()
    case .cancelled, .failed: cancelVoiceHold()
    default: break
    }
  }

  private func beginVoiceHold() {
    guard AVAudioSession.sharedInstance().recordPermission == .granted, SFSpeechRecognizer.authorizationStatus() == .authorized else {
      QFOperationHUD.toast(app.text("请先允许语音权限，再按住说话", "Allow voice permissions, then hold to talk"), in: view)
      requestVoicePermissions(); return
    }
    guard canCapture, activeMessageID == nil, voiceMode,
      let token = voice.begin(draft: input.text ?? "") else { return }
    let binding = QFAssistantAgent.scope(app)
    updateSendButton()
    // Both permissions are obtained before opening the engine; a released hold
    // invalidates this token, so returning from a system prompt cannot record later.
    AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
      Task { @MainActor in
        guard let self, self.voice.isCurrent(token), QFAssistantAgent.scope(self.app) == binding else { return }
        guard granted else {
          self.voiceFailed(self.app.text("请允许麦克风权限", "Allow microphone access")); return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
          Task { @MainActor in
            guard let self, self.voice.isCurrent(token), QFAssistantAgent.scope(self.app) == binding else { return }
            guard status == .authorized else {
              self.voiceFailed(self.app.text("语音转写不可用，请输入文字。", "Voice transcription is unavailable. Please type your message.")); return
            }
            // A permission sheet ends the touch. Never resume a stale hold.
            guard self.canCapture, self.applicationState() == .active else { self.stopCapture(); return }
            self.startVoiceCapture(token: token, binding: binding)
          }
        }
      }
    }
  }

  private func startVoiceCapture(token: UUID, binding: QFAgentScope) {
    do {
      guard voice.start(token: token) else { return }
      try beginSpeechRecognition(token: token, binding: binding)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
      try session.setActive(true); ownsAudioSession = true
      let node = audioEngine.inputNode, format = node.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0, let request = speechRequest else {
        throw NSError(domain: "AssistantRecordingUnavailable", code: 1)
      }
#if DEBUG
      let probe = debugAudioProbe; probe.reset()
#endif
      node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        request.append(buffer)
#if DEBUG
        probe.append(Int(buffer.frameLength))
#endif
      }
      audioTapInstalled = true
      audioEngine.prepare(); try audioEngine.start()
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      updateSendButton()
      transcriptionDeadline = Task { [weak self] in
        do { try await Task.sleep(nanoseconds: 55_000_000_000) } catch { return }
        guard let self, self.voice.isCurrent(token), self.voice.phase == .recording else { return }
        self.releaseVoiceHold()
      }
    } catch {
      let localUnavailable = (error as NSError).domain == "AssistantLocalSpeechUnavailable"
      voiceFailed(localUnavailable
        ? app.text("此设备暂不支持本地语音识别，请输入文字。", "On-device speech recognition is unavailable. Please type your message.")
        : app.text("无法开始录音", "Could not start recording"))
    }
  }

  private func beginSpeechRecognition(token: UUID, binding: QFAgentScope) throws {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)),
      recognizer.isAvailable else { throw NSError(domain: "AssistantSpeechUnavailable", code: 1) }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    request.taskHint = .dictation
    speechRequest = request
    transcription = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor in
        guard let self, self.voice.isCurrent(token), QFAssistantAgent.scope(self.app) == binding, self.canCapture else { return }
        if let result {
          self.voice.receive(result.bestTranscription.formattedString, token: token)
          self.updateSendButton()
#if DEBUG
          self.debugVoicePartials.append(["text": self.voice.transcript, "beforeEndAudio": self.voice.phase == .recording, "final": result.isFinal])
#endif
          if result.isFinal { self.commitVoice(token: token); return }
        }
        if error != nil {
          if !self.voice.transcript.isEmpty { self.commitVoice(token: token) }
          else { self.voiceFailed(self.app.text("语音转写不可用，请输入文字。", "Voice transcription is unavailable. Please type your message.")) }
        }
      }
    }
  }

  private func releaseVoiceHold() {
    guard voice.isBusy, voice.phase != .finishing else { return }
    guard voice.release() else { stopCapture(); updateSendButton(); return }
    stopMicrophone()
    speechRequest?.endAudio()
    transcriptionDeadline?.cancel()
    // Render the latest partial immediately; allow a short final correction,
    // instead of making the user wait for a complete file transcription.
    updateSendButton()
    transcriptionDeadline = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 1_200_000_000) } catch { return }
      guard let self, let token = self.currentVoiceToken else { return }
      self.commitVoice(token: token)
    }
  }

  private var currentVoiceToken: UUID? { voice.currentToken }

  private func commitVoice(token: UUID) {
    guard voice.isCurrent(token) else { return }
    if voice.cancelArmed { cancelVoiceHold(); return }
    let draft = voice.complete(token: token)
    stopCapture()
    voiceMode = false
    if let draft {
      input.text = draft
      attachment.text = app.text("语音已转为文字，可编辑后发送", "Voice converted to text; edit before sending")
      attachment.isHidden = false
      UIAccessibility.post(notification: .announcement, argument: attachment.text)
    } else {
      QFOperationHUD.toast(app.text("未听清，请再说一次", "Didn't catch that. Please try again."), in: view)
    }
    textViewDidChange(input)
  }

  private func cancelVoiceHold() {
    guard voice.isBusy else { return }
    stopCapture()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    QFOperationHUD.toast(app.text("已取消录音", "Recording cancelled"), in: view)
  }

  private func interruptVoiceCapture() {
    guard voice.isBusy else { return }
    if voice.phase == .authorizing || voice.cancelArmed || voice.transcript.isEmpty { stopCapture() }
    else if let token = currentVoiceToken { commitVoice(token: token) }
  }

  private func voiceFailed(_ message: String) {
    stopCapture(); voiceMode = false; textViewDidChange(input)
    QFOperationHUD.toast(message, in: view)
  }

  private func stopMicrophone() {
    audioEngine.stop()
    if audioTapInstalled { audioEngine.inputNode.removeTap(onBus: 0); audioTapInstalled = false }
    if ownsAudioSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
      ownsAudioSession = false
    }
  }


#if DEBUG
  func debugBeginStreaming(text: String) -> Task<Void, Never> {
    let id = UUID()
    messages = [.init(id: id, role: "assistant", text: text, createdAt: Date(), state: "streaming",
      process: [.init(stage: "generating", state: "running")])]
    activeMessageID = id
    let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
    requestTask = task
    renderMessages()
    return task
  }
  func debugCompleteStreaming(text: String) {
    guard let id = activeMessageID, let index = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[index].text = text; completeMessage(index: index)
  }
  func debugOpenMemory() { openMemory() }
  func debugClose() { closeChat() }
  func debugEndScene() { endScene() }
  var debugVisibleAnswer: String { messages.first.map { displayedText(for: $0.id) } ?? "" }
  var debugMessageAccessibility: String? { input.accessibilityLabel }
#endif

  private var canCapture: Bool {
    viewIfLoaded?.window != nil && (navigationController?.topViewController === self) && !isBeingDismissed
      && presentedViewController == nil && applicationState() != .background
  }

  private func stopCapture() {
    voice.cancel()
    stopMicrophone()
    speechRequest?.endAudio(); speechRequest = nil
    transcription?.cancel(); transcription = nil
    transcriptionDeadline?.cancel(); transcriptionDeadline = nil
    updateSendButton()
  }
  private func refreshImagePreview() {
    imagePreview.image = selectedImage
    previewHeight?.update(offset: selectedImage == nil ? 0 : 84)
    previewHolder.isHidden = selectedImage == nil
    updateSendButton()
  }
  @objc private func previewSelectedImage() {
    guard let image = selectedImage else { return }
    stopCapture(); present(QFContentImagePreviewController(image: image, app: app), animated: true)
  }
}

@MainActor
private final class QFDigitalAssistantMemoryViewController: UIViewController {
  private let app: QFAppSession
  private let input = UITextField()
  private let nudgeSwitch = UISwitch()
  private let remoteNudgeSwitch = UISwitch()
  private let list = UIStackView()
  private let hud = QFOperationHUD()
  private var remoteSettings: QFAssistantNotificationSettings?
  init(app: QFAppSession) { self.app = app; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = QFUI.background
    let close = QFTabUI.iconButton("xmark", label: app.text("关闭", "Close"), size: 18) { [weak self] in self?.dismiss(animated: true) }
    let title = QFTabUI.label(app.text("助手记忆", "Assistant memory"), size: 22, weight: .semibold)
    let detail = QFTabUI.label(app.text("只保存你明确确认的偏好，随时可以删除。", "Only explicitly confirmed preferences are saved and can be deleted anytime."), size: 13, color: QFUI.secondary, lines: 0)
    let nudgeTitle = QFTabUI.label(app.text("每日助手提醒", "Daily assistant reminders"), size: 15, weight: .medium)
    let nudgeDetail = QFTabUI.label(app.text("仅使用本机通知，不会把库存或对话内容放进通知。", "Uses local notifications only; private inventory and chat content stay out of notifications."), size: 12, color: QFUI.secondary, lines: 0)
    let nudgeCopy = QFTabUI.stack([nudgeTitle, nudgeDetail], spacing: 3)
    let nudgeRow = QFTabUI.stack([nudgeCopy, nudgeSwitch], axis: .horizontal, spacing: 12)
    nudgeRow.alignment = .center
    nudgeSwitch.isOn = QFDigitalAssistantNudgeScheduler.isEnabled(for: app)
    nudgeSwitch.accessibilityLabel = app.text("每日助手提醒", "Daily assistant reminders")
    nudgeSwitch.addAction(UIAction { [weak self] _ in self?.toggleNudges() }, for: .valueChanged)
    let remoteTitle = QFTabUI.label(app.text("云端助手提醒", "Cloud assistant reminders"), size: 15, weight: .medium)
    let remoteDetail = QFTabUI.label(app.text("需要个推配置并遵守免打扰时段；通知不包含库存或对话内容。", "Requires Getui configuration and respects quiet hours; notifications never include inventory or chat content."), size: 12, color: QFUI.secondary, lines: 0)
    let remoteCopy = QFTabUI.stack([remoteTitle, remoteDetail], spacing: 3)
    let remoteRow = QFTabUI.stack([remoteCopy, remoteNudgeSwitch], axis: .horizontal, spacing: 12)
    remoteRow.alignment = .center
    remoteNudgeSwitch.isOn = false
    remoteNudgeSwitch.accessibilityLabel = app.text("云端助手提醒", "Cloud assistant reminders")
    remoteNudgeSwitch.addAction(UIAction { [weak self] _ in self?.toggleRemoteNudges() }, for: .valueChanged)
    let save = QFTabUI.button(app.text("记住", "Remember"), color: .white, background: QFUI.primary) { [weak self] in self?.save() }
    input.placeholder = app.text("例如：我不吃香菜", "For example: I do not eat cilantro")
    input.backgroundColor = QFUI.surface; input.layer.cornerRadius = 14; input.clearButtonMode = .whileEditing
    input.accessibilityIdentifier = "assistant.memory.input"
    list.axis = .vertical; list.spacing = 10
    let scroll = UIScrollView(); scroll.addSubview(list)
    view.addSubview(close); view.addSubview(title); view.addSubview(detail); view.addSubview(nudgeRow); view.addSubview(remoteRow); view.addSubview(input); view.addSubview(save); view.addSubview(scroll)
    close.snp.makeConstraints { $0.top.equalTo(view.safeAreaLayoutGuide).inset(12); $0.trailing.equalToSuperview().inset(12); $0.size.equalTo(44) }
    title.snp.makeConstraints { $0.leading.equalToSuperview().inset(20); $0.top.equalTo(view.safeAreaLayoutGuide).inset(16); $0.trailing.lessThanOrEqualTo(close.snp.leading).offset(-8) }
    detail.snp.makeConstraints { $0.leading.trailing.equalToSuperview().inset(20); $0.top.equalTo(title.snp.bottom).offset(8) }
    nudgeRow.snp.makeConstraints { $0.leading.trailing.equalToSuperview().inset(20); $0.top.equalTo(detail.snp.bottom).offset(14) }
    remoteRow.snp.makeConstraints { $0.leading.trailing.equalToSuperview().inset(20); $0.top.equalTo(nudgeRow.snp.bottom).offset(12) }
    input.snp.makeConstraints { $0.leading.equalToSuperview().inset(20); $0.top.equalTo(remoteRow.snp.bottom).offset(14); $0.height.equalTo(48); $0.trailing.equalTo(save.snp.leading).offset(-8) }
    save.snp.makeConstraints { $0.trailing.equalToSuperview().inset(20); $0.centerY.equalTo(input); $0.width.equalTo(76); $0.height.equalTo(44) }
    scroll.snp.makeConstraints { $0.leading.trailing.equalToSuperview().inset(20); $0.top.equalTo(input.snp.bottom).offset(18); $0.bottom.equalTo(view.safeAreaLayoutGuide).inset(16) }
    list.snp.makeConstraints { $0.edges.equalToSuperview(); $0.width.equalTo(scroll.snp.width) }
    load()
  }
  private func toggleNudges() {
    let desired = nudgeSwitch.isOn
    QFDigitalAssistantNudgeScheduler.setEnabled(desired, for: app) { [weak self] success in
      guard let self else { return }
      if !success {
        nudgeSwitch.setOn(false, animated: true)
        QFOperationHUD.toast(app.text("通知权限未开启，提醒没有启用。", "Notification permission is off; reminders stay disabled."), in: view)
      }
    }
  }
  private func toggleRemoteNudges() {
    guard let current = remoteSettings else {
      remoteNudgeSwitch.setOn(false, animated: true)
      QFOperationHUD.toast(app.text("云端提醒设置尚未加载。", "Cloud reminder settings are still loading."), in: view)
      return
    }
    let enabled = remoteNudgeSwitch.isOn
    let timezone = current.timezone == "UTC" ? (TimeZone.current.identifier) : current.timezone
    let draft = QFAssistantNotificationSettingsDraft(
      enabled: enabled, dailyEnabled: enabled, inactiveEnabled: enabled,
      timezone: timezone, quietStart: current.quietStart, quietEnd: current.quietEnd,
      maxPerDay: current.maxPerDay, expectedRevision: current.revision)
    Task { [weak self] in
      guard let self else { return }
      do {
        let value = try await app.saveAssistantNotificationSettings(draft)
        remoteSettings = value
        QFGetuiPushService.shared.setAssistantRemoteEnabled(value.enabled, scope: app.contentScope)
      } catch {
        remoteNudgeSwitch.setOn(current.enabled, animated: true)
        QFOperationHUD.toast(QFProfileContentController.errorText(error, app: app), in: view)
      }
    }
  }
  private func load() {
    Task { [weak self] in
      guard let self else { return }
      do {
        let page = try await app.assistantMemories(); render(page.items)
        do {
          let settings = try await app.assistantNotificationSettings()
          remoteSettings = settings
          remoteNudgeSwitch.setOn(settings.enabled, animated: false)
          QFGetuiPushService.shared.setAssistantRemoteEnabled(settings.enabled, scope: app.contentScope)
        } catch {
          // V60 may be rolled out after the client. Keep memory management
          // usable and leave the remote switch off until the endpoint exists.
          remoteSettings = nil
          remoteNudgeSwitch.setOn(false, animated: false)
        }
      }
      catch { QFOperationHUD.toast(QFProfileContentController.errorText(error, app: app), in: view) }
    }
  }
  private func render(_ memories: [QFAssistantMemory]) {
    QFTabUI.clear(list)
    if memories.isEmpty { list.addArrangedSubview(QFTabUI.empty(app.text("还没有已保存记忆", "No saved memories"), detail: app.text("只有你点击“记住”的内容会出现在这里。", "Only items you explicitly remember appear here."))); return }
    for memory in memories {
      let remove = QFTabUI.iconButton("trash", label: app.text("删除记忆", "Delete memory"), size: 17) { [weak self] in self?.remove(memory) }
      let row = QFTabUI.stack([QFTabUI.label(memory.content, size: 15, lines: 0), remove], axis: .horizontal, spacing: 8)
      list.addArrangedSubview(QFTabUI.card(row, padding: 12, border: true))
    }
  }
  private func save() {
    let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { return }
    hud.show(in: view, text: app.text("正在保存", "Saving"))
    Task { [weak self] in
      guard let self else { return }
      do { _ = try await app.saveAssistantMemory(QFAssistantMemoryDraft(content: text, memoryType: "PREFERENCE", remember: true)); input.text = ""; load() }
      catch { QFOperationHUD.toast(QFProfileContentController.errorText(error, app: app), in: view) }
      hud.hide()
    }
  }
  private func remove(_ memory: QFAssistantMemory) {
    Task { [weak self] in
      guard let self else { return }
      do { try await app.deleteAssistantMemory(memory.id); load() }
      catch { QFOperationHUD.toast(QFProfileContentController.errorText(error, app: app), in: view) }
    }
  }
}

/// A transparent 3D digital human. Hunyuan assets use their imported skinned mesh,
/// bind-pose action controller and morph channels; the small humanoid hierarchy remains
/// the deterministic renderer fallback when the asset cannot be converted.
@MainActor
final class QFAssistantRigView: UIView {
  private let sceneView = SCNView(frame: .zero)
  private let scene = SCNScene()
  private let character = SCNNode()
  private var head = SCNNode()
  private var leftArm = SCNNode()
  private var rightArm = SCNNode()
  private var leftElbow = SCNNode()
  private var rightElbow = SCNNode()
  private var leftLeg = SCNNode()
  private var rightLeg = SCNNode()
  private var mouthLine = SCNNode()
  private var mouthOpen = SCNNode()
  private var leftBrow = SCNNode()
  private var rightBrow = SCNNode()
  private var leftEye = SCNNode()
  private var rightEye = SCNNode()
  private var leftPupil = SCNNode()
  private var rightPupil = SCNNode()
  private var modelAsset: QFAssistantModelAsset?
  private var importedBoneBindTransforms: [String: simd_float4x4] = [:]
  private var importedBoneBendAxes: [String: SIMD3<Float>] = [:]
  private var importedBonePitchAxes: [String: SIMD3<Float>] = [:]
  private var poseTask: Task<Void, Never>?
  private var actionTask: Task<Void, Never>?
  private var actionIsPlaying = false
  private var blinkTask: Task<Void, Never>?
  private var isAnimationEnabled = false
  private var actionStrength: Float = 1
  private var waveDirection: Float = 1
  private var importedEyelids: [(cover: SCNNode, line: SCNNode)] = []
  private var currentEmotion: QFAssistantEmotion = .calm
  private var manualControl = false
  private(set) var selectedPose: QFAssistantPose?
  private(set) var selectedFace: QFAssistantFaceSelection?
  var interfaceLanguage: QFInterfaceLanguage = .simplifiedChinese

  enum QFAssistantEmotion: String, CaseIterable {
    case happy, thinking, calm, excited, sad, angry, shy
  }

  enum QFAssistantPose: CaseIterable, Hashable {
    case welcome, wave, thinking, calm, excited, sad, angry, coverFace, flustered, stomp
  }

  convenience init() { self.init(frame: .zero) }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    accessibilityIdentifier = "assistant.3d-character"
    accessibilityTraits = .image

    sceneView.backgroundColor = .clear
    sceneView.isOpaque = false
    sceneView.allowsCameraControl = false
    sceneView.autoenablesDefaultLighting = false
    sceneView.preferredFramesPerSecond = 30
    sceneView.antialiasingMode = .multisampling4X
    sceneView.scene = scene
    addSubview(sceneView)
    sceneView.snp.makeConstraints { $0.edges.equalToSuperview() }

    buildScene()
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    poseTask?.cancel()
    actionTask?.cancel()
    blinkTask?.cancel()
  }

  private func material(_ color: UIColor, roughness: CGFloat = 0.72, metalness: CGFloat = 0) -> SCNMaterial {
    let material = SCNMaterial()
    material.lightingModel = .physicallyBased
    material.diffuse.contents = color
    material.roughness.contents = NSNumber(value: Float(roughness))
    material.metalness.contents = NSNumber(value: Float(metalness))
    return material
  }

  private func makeNode(_ geometry: SCNGeometry, material: SCNMaterial, name: String, position: SCNVector3 = SCNVector3(0, 0, 0)) -> SCNNode {
    geometry.materials = [material]
    let node = SCNNode(geometry: geometry)
    node.name = name
    node.position = position
    return node
  }

  private func capsule(_ radius: CGFloat, height: CGFloat, color: UIColor, name: String, position: SCNVector3) -> SCNNode {
    makeNode(SCNCapsule(capRadius: radius, height: height), material: material(color), name: name, position: position)
  }

  private func sphere(_ radius: CGFloat, color: UIColor, name: String, position: SCNVector3, scale: SCNVector3 = SCNVector3(1, 1, 1)) -> SCNNode {
    let node = makeNode(SCNSphere(radius: radius), material: material(color), name: name, position: position)
    node.scale = scale
    return node
  }

  private func buildScene() {
    if loadHunyuanModelAsset() { return }
    if loadLegacyCharacterModelAsset() { return }
    buildProceduralScene()
  }

  private func configureSceneEnvironment() {
    scene.background.contents = UIColor.clear
    // Keep the small floating character legible on white recipe cards. The
    // imported PBR texture already contains strong albedo contrast, so the
    // previous 820/480/180 omni stack clipped most facial and clothing detail.
    scene.lightingEnvironment.intensity = 0.10

    let cameraNode = SCNNode()
    let camera = SCNCamera()
    camera.fieldOfView = 31
    camera.usesOrthographicProjection = true
    camera.orthographicScale = 1.10
    camera.zNear = 0.05
    camera.zFar = 100
    cameraNode.camera = camera
    cameraNode.position = SCNVector3(0, 0.90, 5.15)
    cameraNode.look(at: SCNVector3(0, 0.90, 0))
    scene.rootNode.addChildNode(cameraNode)
    sceneView.pointOfView = cameraNode

    let keyNode = SCNNode()
    let key = SCNLight(); key.type = .omni; key.intensity = 300; key.color = UIColor(white: 1, alpha: 1)
    keyNode.light = key; keyNode.position = SCNVector3(2.4, 3.2, 4.4); scene.rootNode.addChildNode(keyNode)
    let fillNode = SCNNode()
    let fill = SCNLight(); fill.type = .omni; fill.intensity = 90; fill.color = UIColor(red: 0.82, green: 0.90, blue: 1, alpha: 1)
    fillNode.light = fill; fillNode.position = SCNVector3(-2.2, 1.2, 2.2); scene.rootNode.addChildNode(fillNode)
    let ambientNode = SCNNode()
    let ambient = SCNLight(); ambient.type = .ambient; ambient.intensity = 35; ambient.color = UIColor(white: 0.94, alpha: 1)
    ambientNode.light = ambient; scene.rootNode.addChildNode(ambientNode)
  }

  private func loadHunyuanModelAsset() -> Bool {
    let bundle = Bundle(identifier: "com.talka.qiafanyoupu") ?? .main
    guard case let .loaded(asset) = QFAssistantModelAsset.load(bundle: bundle) else { return false }
    configureSceneEnvironment()
    modelAsset = asset
    importedBoneBindTransforms = asset.nodeMap.bones.reduce(into: [:]) { result, entry in
      result[entry.key] = entry.value.simdTransform
    }
    for (name, node) in asset.nodeMap.bones {
      let bend = node.convertVector(SCNVector3(0, 1, 0), from: asset.rootNode)
      let pitch = node.convertVector(SCNVector3(1, 0, 0), from: asset.rootNode)
      importedBoneBendAxes[name] = simd_normalize(SIMD3<Float>(bend.x, bend.y, bend.z))
      importedBonePitchAxes[name] = simd_normalize(SIMD3<Float>(pitch.x, pitch.y, pitch.z))
    }
    character.position = SCNVector3(0, -0.02, 0)
    character.name = "assistant.character"
    character.addChildNode(asset.rootNode)
    scene.rootNode.addChildNode(character)
    head = asset.nodeMap.head
    leftArm = asset.nodeMap.leftArm[0]
    leftElbow = asset.nodeMap.leftArm[1]
    rightArm = asset.nodeMap.rightArm[0]
    rightElbow = asset.nodeMap.rightArm[1]
    leftLeg = asset.nodeMap.leftLeg[0]
    rightLeg = asset.nodeMap.rightLeg[0]
    leftBrow = asset.nodeMap.face.leftBrow
    rightBrow = asset.nodeMap.face.rightBrow
    leftEye = asset.nodeMap.face.leftEye
    rightEye = asset.nodeMap.face.rightEye
    buildImportedEyelids(asset)
    attachBadgeArt(to: asset.nodeMap.bones["chest"]!, sourceRoot: asset.rootNode)
    setEmotion(.calm)
    return true
  }

  private func buildImportedEyelids(_ asset: QFAssistantModelAsset) {
    // The source eyes contain painted lashes/irises. Flattening their entire
    // mesh folds that texture into black triangles. Separate eyelids cover
    // the eyes during a blink while remaining attached to the real head bone.
    for (side, x) in [("L", Float(-0.069)), ("R", Float(0.065))] {
      let eyeRoot = SCNNode()
      eyeRoot.name = "assistant.eyelid.\(side)"
      head.addChildNode(eyeRoot)
      eyeRoot.position = head.convertPosition(SCNVector3(x, -0.135, 0.716), from: asset.rootNode)
      eyeRoot.simdOrientation = simd_quatf(asset.rootNode.simdConvertTransform(simd_float4x4(1), to: head))
      let cover = SCNNode(geometry: SCNSphere(radius: 1))
      let skin = SCNMaterial(); skin.lightingModel = .constant
      skin.diffuse.contents = UIColor(red: 0.985, green: 0.843, blue: 0.718, alpha: 1)
      cover.geometry?.materials = [skin]
      cover.opacity = 0
      cover.scale = SCNVector3(0.046, 0.024, 0.0001)
      eyeRoot.addChildNode(cover)
      let crease = UIBezierPath()
      crease.move(to: CGPoint(x: -0.033, y: 0.002))
      crease.addQuadCurve(to: CGPoint(x: 0.033, y: 0.002), controlPoint: CGPoint(x: 0, y: -0.011))
      crease.addLine(to: CGPoint(x: 0.033, y: 0.004))
      crease.addQuadCurve(to: CGPoint(x: -0.033, y: 0.004), controlPoint: CGPoint(x: 0, y: -0.008))
      crease.close()
      let line = SCNNode(geometry: SCNShape(path: crease, extrusionDepth: 0.001))
      let ink = SCNMaterial(); ink.lightingModel = .constant
      ink.diffuse.contents = UIColor(red: 0.24, green: 0.11, blue: 0.07, alpha: 1)
      line.geometry?.materials = [ink]
      line.eulerAngles.x = .pi / 2
      line.position.y = -0.025
      line.opacity = 0
      eyeRoot.addChildNode(line)
      importedEyelids.append((cover, line))
    }
  }

  private func loadLegacyCharacterModelAsset() -> Bool {
    guard let asset = NSDataAsset(name: "assistant-character"),
      let source = SCNSceneSource(data: asset.data, options: nil),
      let loadedScene = source.scene(options: nil)
    else { return false }
    let modelRoot = loadedScene.rootNode.clone()
    func node(_ name: String) -> SCNNode? { modelRoot.childNode(withName: name, recursively: true) }
    guard let loadedHead = node("assistant.head"),
      let loadedLeftArm = node("assistant.left-arm"),
      let loadedRightArm = node("assistant.right-arm"),
      let loadedLeftElbow = node("assistant.left-elbow"),
      let loadedRightElbow = node("assistant.right-elbow"),
      let loadedLeftLeg = node("assistant.left-leg"),
      let loadedRightLeg = node("assistant.right-leg"),
      let loadedMouthLine = node("assistant.mouth-line"),
      let loadedMouthOpen = node("assistant.mouth-open"),
      let loadedLeftBrow = node("assistant.left-brow"),
      let loadedRightBrow = node("assistant.right-brow"),
      let loadedLeftEye = node("assistant.left-eye"),
      let loadedRightEye = node("assistant.right-eye")
    else { return false }
    configureSceneEnvironment()
    character.position = SCNVector3(0, -0.02, 0)
    character.name = "assistant.character"
    character.addChildNode(modelRoot)
    scene.rootNode.addChildNode(character)
    head = loadedHead; leftArm = loadedLeftArm; rightArm = loadedRightArm
    leftElbow = loadedLeftElbow; rightElbow = loadedRightElbow
    leftLeg = loadedLeftLeg; rightLeg = loadedRightLeg
    mouthLine = loadedMouthLine; mouthOpen = loadedMouthOpen
    leftBrow = loadedLeftBrow; rightBrow = loadedRightBrow
    leftEye = loadedLeftEye; rightEye = loadedRightEye
    leftPupil = node("assistant.left-pupil") ?? SCNNode()
    rightPupil = node("assistant.right-pupil") ?? SCNNode()
    attachBadgeArt(to: character)
    setEmotion(.calm)
    return true
  }

  private func attachBadgeArt(to parent: SCNNode, sourceRoot: SCNNode? = nil) {
    guard let badgeImage = UIImage(named: "assistant-badge") else { return }
    let badgeMaterial = SCNMaterial()
    badgeMaterial.lightingModel = .constant
    badgeMaterial.diffuse.contents = badgeImage
    badgeMaterial.transparencyMode = .aOne
    badgeMaterial.isDoubleSided = true
    let badgeArt = SCNNode(geometry: SCNPlane(width: sourceRoot == nil ? 0.19 : 0.065, height: sourceRoot == nil ? 0.19 : 0.065))
    badgeArt.name = "assistant.badge-art"
    badgeArt.geometry?.materials = [badgeMaterial]
    parent.addChildNode(badgeArt)
    if let sourceRoot {
      // Coordinates are in the corrected source mesh's Z-up space. The chest
      // owns the locator so the badge follows the torso rather than hovering
      // at the old procedural character's pelvis coordinate.
      badgeArt.position = parent.convertPosition(SCNVector3(-0.060, -0.145, 0.490), from: sourceRoot)
      badgeArt.simdOrientation = simd_quatf(sourceRoot.simdConvertTransform(simd_float4x4(1), to: parent)) * simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
    } else {
      badgeArt.position = SCNVector3(0, 0.40, 0.322)
    }
  }

  private func buildProceduralScene() {
    configureSceneEnvironment()

    character.position = SCNVector3(0, -0.02, 0)
    character.name = "assistant.character"
    scene.rootNode.addChildNode(character)

    // Keep the fallback on the static mascot palette as well: peach hair, cream
    // cooking blouse, dark-green apron and orange scarf accents. This is only a
    // renderer fallback when the bundled SCN asset cannot be decoded.
    let skin = UIColor(red: 0.98, green: 0.74, blue: 0.62, alpha: 1)
    let hair = UIColor(red: 1.00, green: 0.76, blue: 0.54, alpha: 1)
    let jacket = UIColor(red: 0.96, green: 0.87, blue: 0.71, alpha: 1)
    let apron = UIColor(red: 0.12, green: 0.28, blue: 0.17, alpha: 1)
    let dark = UIColor(red: 0.05, green: 0.07, blue: 0.04, alpha: 1)
    let lip = UIColor(red: 0.72, green: 0.17, blue: 0.18, alpha: 1)

    let torso = makeNode(SCNBox(width: 0.76, height: 1.02, length: 0.46, chamferRadius: 0.16), material: material(jacket), name: "assistant.torso", position: SCNVector3(0, 0.31, 0))
    character.addChildNode(torso)
    let apronNode = makeNode(SCNBox(width: 0.53, height: 0.68, length: 0.05, chamferRadius: 0.04), material: material(apron), name: "assistant.apron", position: SCNVector3(0, 0.24, 0.25))
    character.addChildNode(apronNode)
    let collar = makeNode(SCNCone(topRadius: 0.18, bottomRadius: 0.30, height: 0.20), material: material(apron), name: "assistant.collar", position: SCNVector3(0, 0.78, 0))
    character.addChildNode(collar)
    let badge = makeNode(SCNCylinder(radius: 0.11, height: 0.035), material: material(UIColor(red: 0.90, green: 0.45, blue: 0.20, alpha: 1), metalness: 0.25), name: "assistant.badge", position: SCNVector3(0, 0.40, 0.29))
    badge.eulerAngles.x = .pi / 2
    character.addChildNode(badge)
    if let badgeImage = UIImage(named: "assistant-badge") {
      let badgeMaterial = SCNMaterial()
      badgeMaterial.lightingModel = .constant
      badgeMaterial.diffuse.contents = badgeImage
      badgeMaterial.transparencyMode = .aOne
      badgeMaterial.isDoubleSided = true
      let badgeArt = SCNNode(geometry: SCNPlane(width: 0.19, height: 0.19))
      badgeArt.name = "assistant.badge-art"
      badgeArt.geometry?.materials = [badgeMaterial]
      badgeArt.position = SCNVector3(0, 0.40, 0.322)
      character.addChildNode(badgeArt)
    }

    head.position = SCNVector3(0, 1.33, 0)
    head.name = "assistant.head"
    character.addChildNode(head)
    let headMesh = sphere(0.42, color: skin, name: "assistant.face", position: SCNVector3(0, 0, 0), scale: SCNVector3(0.94, 1.08, 0.90))
    head.addChildNode(headMesh)
    let hairMesh = sphere(0.44, color: hair, name: "assistant.hair", position: SCNVector3(0, 0.20, -0.02), scale: SCNVector3(1.00, 0.60, 0.94))
    head.addChildNode(hairMesh)
    let fringe = makeNode(SCNBox(width: 0.58, height: 0.19, length: 0.08, chamferRadius: 0.07), material: material(hair), name: "assistant.fringe", position: SCNVector3(0, 0.30, 0.31))
    fringe.eulerAngles.z = -0.08
    head.addChildNode(fringe)

    let eyeWhite = material(UIColor.white)
    let pupilMaterial = material(dark, roughness: 0.38)
    leftEye.addChildNode(makeNode(SCNSphere(radius: 0.079), material: eyeWhite, name: "assistant.left-eye-white", position: SCNVector3(0, 0, 0)))
    rightEye.addChildNode(makeNode(SCNSphere(radius: 0.079), material: eyeWhite, name: "assistant.right-eye-white", position: SCNVector3(0, 0, 0)))
    leftEye.position = SCNVector3(-0.14, 0.06, 0.36); rightEye.position = SCNVector3(0.14, 0.06, 0.36)
    leftEye.scale = SCNVector3(1, 0.78, 0.42); rightEye.scale = SCNVector3(1, 0.78, 0.42)
    leftPupil.addChildNode(makeNode(SCNSphere(radius: 0.038), material: pupilMaterial, name: "assistant.left-pupil", position: SCNVector3(0, 0, 0.055)))
    rightPupil.addChildNode(makeNode(SCNSphere(radius: 0.038), material: pupilMaterial, name: "assistant.right-pupil", position: SCNVector3(0, 0, 0.055)))
    leftEye.addChildNode(leftPupil); rightEye.addChildNode(rightPupil)
    head.addChildNode(leftEye); head.addChildNode(rightEye)

    let browGeometry = SCNBox(width: 0.19, height: 0.035, length: 0.035, chamferRadius: 0.014)
    leftBrow.geometry = browGeometry; leftBrow.geometry?.materials = [material(hair)]
    rightBrow.geometry = browGeometry.copy() as? SCNGeometry; rightBrow.geometry?.materials = [material(hair)]
    leftBrow.position = SCNVector3(-0.14, 0.20, 0.37); rightBrow.position = SCNVector3(0.14, 0.20, 0.37)
    head.addChildNode(leftBrow); head.addChildNode(rightBrow)
    head.addChildNode(sphere(0.047, color: skin, name: "assistant.nose", position: SCNVector3(0, -0.02, 0.40), scale: SCNVector3(0.65, 0.90, 0.68)))

    mouthLine.geometry = SCNBox(width: 0.20, height: 0.027, length: 0.025, chamferRadius: 0.012)
    mouthLine.geometry?.materials = [material(lip, roughness: 0.55)]
    mouthLine.position = SCNVector3(0, -0.16, 0.38)
    mouthOpen.geometry = SCNSphere(radius: 0.07)
    mouthOpen.geometry?.materials = [material(lip, roughness: 0.55)]
    mouthOpen.position = SCNVector3(0, -0.16, 0.38)
    mouthOpen.scale = SCNVector3(1.22, 0.72, 0.38)
    mouthOpen.isHidden = true
    head.addChildNode(mouthLine); head.addChildNode(mouthOpen)

    buildArm(leftArm, elbow: leftElbow, side: -1, skin: skin, jacket: jacket, parent: character)
    buildArm(rightArm, elbow: rightElbow, side: 1, skin: skin, jacket: jacket, parent: character)
    buildLeg(leftLeg, side: -1, skin: skin, parent: character)
    buildLeg(rightLeg, side: 1, skin: skin, parent: character)
    setEmotion(.calm)
  }

  private func buildArm(_ arm: SCNNode, elbow: SCNNode, side: Float, skin: UIColor, jacket: UIColor, parent: SCNNode) {
    arm.position = SCNVector3(0.49 * side, 0.66, 0)
    arm.name = side < 0 ? "assistant.left-arm" : "assistant.right-arm"
    parent.addChildNode(arm)
    arm.addChildNode(capsule(0.115, height: 0.61, color: jacket, name: "assistant.upper-arm", position: SCNVector3(0, -0.30, 0)))
    elbow.position = SCNVector3(0, -0.61, 0)
    elbow.name = side < 0 ? "assistant.left-elbow" : "assistant.right-elbow"
    arm.addChildNode(elbow)
    elbow.addChildNode(capsule(0.095, height: 0.57, color: skin, name: "assistant.forearm", position: SCNVector3(0, -0.28, 0)))
    elbow.addChildNode(sphere(0.12, color: skin, name: "assistant.hand", position: SCNVector3(0, -0.59, 0), scale: SCNVector3(0.86, 1.08, 0.86)))
  }

  private func buildLeg(_ leg: SCNNode, side: Float, skin: UIColor, parent: SCNNode) {
    leg.position = SCNVector3(0.20 * side, -0.19, 0)
    leg.name = side < 0 ? "assistant.left-leg" : "assistant.right-leg"
    parent.addChildNode(leg)
    leg.addChildNode(capsule(0.14, height: 0.77, color: UIColor(red: 0.13, green: 0.22, blue: 0.32, alpha: 1), name: "assistant.trouser", position: SCNVector3(0, -0.39, 0)))
    leg.addChildNode(makeNode(SCNBox(width: 0.27, height: 0.14, length: 0.48, chamferRadius: 0.05), material: material(UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)), name: "assistant.shoe", position: SCNVector3(0, -0.84, 0.08)))
  }

  private func startBlinking() {
    guard blinkTask == nil, selectedFace?.holdsEyes != true, !UIAccessibility.isReduceMotionEnabled else { return }
    blinkTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        let delay = UInt64(Int.random(in: 2600...5200)) * 1_000_000
        try? await Task.sleep(nanoseconds: delay)
        guard !Task.isCancelled else { return }
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0.09
        self?.setBlink(left: true, right: true, weight: 1)
        SCNTransaction.commit()
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0.12
        self?.setBlink(left: true, right: true, weight: 0)
        SCNTransaction.commit()
      }
    }
  }

  private func setBlink(left: Bool, right: Bool, weight: CGFloat) {
    let clampedWeight = min(max(weight, 0), 1)
    guard let modelAsset else {
      if left { leftEye.scale.y = clampedWeight > 0 ? 0.10 : 0.78 }
      if right { rightEye.scale.y = clampedWeight > 0 ? 0.10 : 0.78 }
      return
    }
    for (index, enabled) in [left, right].enumerated() where enabled {
      if importedEyelids.indices.contains(index) {
        let lid = importedEyelids[index]
        lid.cover.opacity = clampedWeight > 0 ? 1 : 0
        lid.cover.scale.z = Float(max(0.0001, clampedWeight * 0.034))
        lid.cover.position.z = Float((1 - clampedWeight) * 0.034)
        lid.line.opacity = max(0, (clampedWeight - 0.65) / 0.35)
      }
      let name = index == 0 ? "face_blink_L" : "face_blink_R"
      if let channel = modelAsset.nodeMap.morphChannels[name] {
        channel.morpher.setWeight(clampedWeight * 0.08, forTargetAt: channel.index)
      }
    }
  }

  func beginRigAnimation() {
    isAnimationEnabled = true
    sceneView.isPlaying = true
    scene.isPaused = false
    startBlinking()
    if manualControl {
      setEmotion(currentEmotion)
      return
    }
    poseTask?.cancel()
    actionTask?.cancel()
    actionTask = nil
    actionIsPlaying = false
    if modelAsset != nil {
      // The corrected USDZ carries the rest skin. One controller owns all
      // bone writes and chooses bounded variations from compatible families.
      apply(pose: .calm)
      guard !UIAccessibility.isReduceMotionEnabled else { return }
      poseTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: UInt64(Int.random(in: 4_000...7_000)) * 1_000_000)
          guard !Task.isCancelled, let self else { return }
          if !self.actionIsPlaying { self.apply(pose: Bool.random() ? .calm : .thinking) }
        }
      }
      return
    }
    guard !UIAccessibility.isReduceMotionEnabled else { return }
    poseTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        let pose: QFAssistantPose = Bool.random() ? .calm : .thinking
        self?.apply(pose: pose)
        try? await Task.sleep(nanoseconds: UInt64(Int.random(in: 3_600...6_200)) * 1_000_000)
      }
    }
  }

  func playGreeting() {
    playSceneAction(.greeting)
  }

  func playExcited() {
    playSceneAction(.positive)
  }

  /// A chosen expression remains in effect while actions are previewed. Chat
  /// callbacks cannot replace manual choices until the user resumes automatic.
  func selectPose(_ pose: QFAssistantPose) {
    manualControl = true
    selectedPose = pose
    isAnimationEnabled = true
    scene.isPaused = false; sceneView.isPlaying = true
    startBlinking()
    playSceneAction(.idle, preferredPose: pose)
  }

  func selectExpression(_ face: QFAssistantFaceSelection) {
    manualControl = true
    selectedFace = face
    poseTask?.cancel(); poseTask = nil
    blinkTask?.cancel(); blinkTask = nil
    isAnimationEnabled = true
    scene.isPaused = false; sceneView.isPlaying = true
    setBlink(left: true, right: true, weight: 0)
    setEmotion(face.emotion)
    if !face.holdsEyes { startBlinking() }
  }

  func resumeAutomaticAnimation() {
    manualControl = false
    selectedPose = nil; selectedFace = nil
    blinkTask?.cancel(); blinkTask = nil
    setBlink(left: true, right: true, weight: 0)
    if let channel = modelAsset?.nodeMap.morphChannels["face_talk"] { channel.morpher.setWeight(0, forTargetAt: channel.index) }
    beginRigAnimation()
  }

  func playSceneAction(_ intent: QFAssistantCharacterIntent, preferredPose: QFAssistantPose? = nil) {
    guard isAnimationEnabled, !manualControl || preferredPose != nil else { return }
    actionStrength = Float.random(in: 0.90...1.10)
    poseTask?.cancel()
    actionTask?.cancel()
    character.removeAllActions()
    actionIsPlaying = true

    let candidates: [QFAssistantPose]
    switch intent {
    case .idle: candidates = [.calm, .thinking]
    case .greeting: candidates = [.wave, .welcome]
    case .thinking: candidates = [.thinking, .calm]
    case .positive: candidates = [.excited, .welcome, .wave]
    case .sad: candidates = [.sad, .coverFace]
    case .awkward: candidates = [.flustered, .thinking]
    case .angry: candidates = [.angry, .stomp]
    }
    let pose = preferredPose ?? candidates.randomElement() ?? .calm
    let steps = actionSteps(for: pose)
    apply(pose: steps.first?.0 ?? pose)
    actionTask = Task { @MainActor [weak self] in
      for (index, step) in steps.enumerated() {
        guard !Task.isCancelled else { return }
        if index > 0 { self?.apply(pose: step.0) }
        try? await Task.sleep(nanoseconds: UInt64(step.1 * Double.random(in: 0.9...1.1) * 1_000_000_000))
        guard !Task.isCancelled else { return }
      }
      let finalHold = UIAccessibility.isReduceMotionEnabled ? 0.20 : Double.random(in: 0.30...0.70)
      try? await Task.sleep(nanoseconds: UInt64(finalHold * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      self.actionIsPlaying = false
      self.actionTask = nil
      if self.manualControl { self.apply(pose: .calm) }
      else { self.beginRigAnimation() }
    }
  }

  private func actionSteps(for pose: QFAssistantPose) -> [(QFAssistantPose, TimeInterval)] {
    if UIAccessibility.isReduceMotionEnabled { return [(pose, 0.25)] }
    switch pose {
    case .wave:
      return [(.wave, 0.30), (.wave, 0.22), (.wave, 0.22), (.wave, 0.22), (.calm, 0.24)]
    case .coverFace:
      return [(.sad, 0.22), (.coverFace, 0.78), (.sad, 0.25)]
    case .flustered:
      return [(.flustered, 0.28), (.thinking, 0.18), (.flustered, 0.28), (.thinking, 0.16)]
    case .stomp:
      return [(.stomp, 0.24), (.calm, 0.16), (.stomp, 0.24), (.calm, 0.14)]
    case .excited:
      return [(.excited, 0.34), (.calm, 0.16), (.excited, 0.30)]
    case .thinking:
      return [(.thinking, 0.80)]
    case .sad:
      return [(.sad, 0.65)]
    case .welcome:
      return [(.welcome, 0.55), (.calm, 0.22)]
    case .calm:
      return [(.calm, 0.55)]
    case .angry:
      return [(.angry, 0.55)]
    }
  }

  private func apply(pose: QFAssistantPose) {
    if pose == .wave { waveDirection *= -1 }
    if modelAsset != nil {
      applyImportedPose(pose)
      return
    }
    let emotion: QFAssistantEmotion
    switch pose {
    case .welcome: emotion = .happy
    case .wave: emotion = .happy
    case .thinking: emotion = .thinking
    case .calm: emotion = .calm
    case .excited: emotion = .excited
    case .sad: emotion = .sad
    case .angry: emotion = .angry
    case .coverFace: emotion = .sad
    case .flustered: emotion = .shy
    case .stomp: emotion = .angry
    }
    setEmotion(emotion)
    SCNTransaction.begin()
    SCNTransaction.animationDuration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.62
    head.eulerAngles = SCNVector3(0, pose == .thinking ? -0.12 : (pose == .sad ? 0.10 : 0), pose == .sad ? -0.04 : 0)
    leftArm.eulerAngles = SCNVector3(0, 0, 0); rightArm.eulerAngles = SCNVector3(0, 0, 0)
    leftElbow.eulerAngles = SCNVector3(0, 0, 0); rightElbow.eulerAngles = SCNVector3(0, 0, 0)
    leftLeg.eulerAngles = SCNVector3(0, 0, 0); rightLeg.eulerAngles = SCNVector3(0, 0, 0)
    switch pose {
    case .welcome:
      leftArm.eulerAngles.z = -0.10; rightArm.eulerAngles.z = 0.10
    case .wave:
      rightArm.eulerAngles.z = -0.70; rightElbow.eulerAngles.z = -0.82 + waveDirection * 0.12
      leftArm.eulerAngles.z = 0.12
    case .thinking:
      rightArm.eulerAngles.z = -0.95; rightElbow.eulerAngles.z = 1.28
      leftArm.eulerAngles.z = 0.18; head.eulerAngles.x = -0.10
    case .calm:
      leftArm.eulerAngles.z = 0.05; rightArm.eulerAngles.z = -0.05
    case .excited:
      leftArm.eulerAngles.z = 0.68; rightArm.eulerAngles.z = -0.68
      leftElbow.eulerAngles.z = 0.38; rightElbow.eulerAngles.z = -0.38
      leftLeg.eulerAngles.z = -0.08; rightLeg.eulerAngles.z = 0.08
    case .sad:
      leftArm.eulerAngles.z = -0.24; rightArm.eulerAngles.z = 0.24
      leftElbow.eulerAngles.z = 0.16; rightElbow.eulerAngles.z = -0.16
    case .angry:
      leftArm.eulerAngles.z = 0.34; rightArm.eulerAngles.z = -0.34
      leftElbow.eulerAngles.z = -0.22; rightElbow.eulerAngles.z = 0.22
      head.eulerAngles.y = 0.14
    case .coverFace:
      leftArm.eulerAngles.z = 0.84; rightArm.eulerAngles.z = -0.84
      leftElbow.eulerAngles.z = 1.12; rightElbow.eulerAngles.z = -1.12
      head.eulerAngles.x = -0.10
    case .flustered:
      leftArm.eulerAngles.z = 0.50; rightArm.eulerAngles.z = -0.50
      leftElbow.eulerAngles.z = 0.76; rightElbow.eulerAngles.z = -0.76
    case .stomp:
      leftArm.eulerAngles.z = 0.26; rightArm.eulerAngles.z = -0.26
      leftLeg.eulerAngles.z = -0.16; rightLeg.eulerAngles.z = 0.16
    }
    SCNTransaction.commit()
  }

  /// Applies a small local rotation delta on top of each imported bind pose.
  /// The Hunyuan bones carry non-identity rest orientations, so assigning
  /// absolute zero Euler angles would stretch the skinned mesh. This path keeps
  /// the bind transform and owns all imported bone writes while an action runs.
  private func applyImportedPose(_ pose: QFAssistantPose) {
    let emotion: QFAssistantEmotion
    switch pose {
    case .welcome: emotion = .happy
    case .calm: emotion = .calm
    case .wave: emotion = .happy
    case .thinking: emotion = .thinking
    case .excited: emotion = .excited
    case .sad, .coverFace: emotion = .sad
    case .angry, .stomp: emotion = .angry
    case .flustered: emotion = .shy
    }
    setEmotion(emotion)

    SCNTransaction.begin()
    SCNTransaction.animationDuration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.16
    for (name, node) in modelAsset?.nodeMap.bones ?? [:] {
      guard let bind = importedBoneBindTransforms[name] else { continue }
      node.simdTransform = bind
    }
    func delta(_ name: String, _ radians: Float, axis: SIMD3<Float> = SIMD3<Float>(0, 1, 0), compose: Bool = false) {
      guard let node = modelAsset?.nodeMap.bones[name], let bind = importedBoneBindTransforms[name] else { return }
      // Local Y is the length of a Blender bone. Rotating around it twists the
      // limb; convert the source bend/pitch axes to each bone's REST frame.
      let localAxis = axis.x == 1 ? importedBonePitchAxes[name] : importedBoneBendAxes[name]
      let rotation = simd_float4x4(simd_quatf(angle: radians, axis: localAxis ?? axis))
      node.simdTransform = compose ? bind * rotation * simd_inverse(bind) * node.simdTransform : bind * rotation
    }
    switch pose {
    case .welcome:
      delta("upper_arm.L", 0.35 * actionStrength); delta("upper_arm.R", -0.35 * actionStrength)
      delta("forearm.L", 0.20); delta("forearm.R", -0.20)
    case .wave:
      delta("upper_arm.R", -1.10 * actionStrength)
      delta("forearm.R", -0.90 * actionStrength + waveDirection * 0.10)
      delta("hand.R", waveDirection * 0.28)
      delta("upper_arm.L", 0.08)
    case .thinking:
      delta("upper_arm.R", -1.55); delta("forearm.R", -1.28); delta("head", -0.07, axis: SIMD3<Float>(1, 0, 0))
      delta("upper_arm.L", 0.12)
    case .calm:
      delta("upper_arm.L", Float.random(in: -0.05...0.05)); delta("upper_arm.R", Float.random(in: -0.05...0.05))
    case .excited:
      delta("upper_arm.L", Float.random(in: 0.46...0.68)); delta("upper_arm.R", Float.random(in: -0.68 ... -0.46))
      delta("forearm.L", Float.random(in: 0.24...0.42)); delta("forearm.R", Float.random(in: -0.42 ... -0.24))
    case .sad:
      delta("head", Float.random(in: -0.15 ... -0.08), axis: SIMD3<Float>(1, 0, 0))
      delta("upper_arm.L", Float.random(in: -0.20 ... -0.10)); delta("upper_arm.R", Float.random(in: 0.10...0.20))
      delta("forearm.L", Float.random(in: 0.10...0.22)); delta("forearm.R", Float.random(in: -0.22 ... -0.10))
    case .angry:
      delta("chest", Float.random(in: 0.05...0.10), axis: SIMD3<Float>(1, 0, 0))
      delta("upper_arm.L", Float.random(in: 0.24...0.38)); delta("upper_arm.R", Float.random(in: -0.38 ... -0.24))
      delta("forearm.L", Float.random(in: -0.26 ... -0.14)); delta("forearm.R", Float.random(in: 0.14...0.26))
    case .coverFace:
      delta("upper_arm.L", Float.random(in: 2.42...2.54)); delta("forearm.L", Float.random(in: 0.60...0.72))
      delta("upper_arm.R", Float.random(in: -2.54 ... -2.42)); delta("forearm.R", Float.random(in: -0.72 ... -0.60))
      delta("upper_arm.L", 0.55, axis: SIMD3<Float>(1, 0, 0), compose: true)
      delta("upper_arm.R", 0.55, axis: SIMD3<Float>(1, 0, 0), compose: true)
      delta("head", Float.random(in: -0.16 ... -0.08), axis: SIMD3<Float>(1, 0, 0))
    case .flustered:
      let strength = Float.random(in: 0.82...1.12)
      delta("upper_arm.L", 0.50 * strength); delta("forearm.L", 0.78 * strength)
      delta("upper_arm.R", -0.50 * strength); delta("forearm.R", -0.78 * strength)
      delta("hand.L", Float.random(in: -0.24...0.24), axis: SIMD3<Float>(1, 0, 0))
      delta("hand.R", Float.random(in: -0.24...0.24), axis: SIMD3<Float>(1, 0, 0))
    case .stomp:
      delta("chest", Float.random(in: 0.06...0.11), axis: SIMD3<Float>(1, 0, 0))
      let side = Bool.random() ? "L" : "R"
      let hip = Float.random(in: -0.60 ... -0.45)
      let knee = Float.random(in: 0.65...0.80)
      let pitchAxis = SIMD3<Float>(1, 0, 0)
      delta("thigh.\(side)", hip, axis: pitchAxis)
      delta("shin.\(side)", knee, axis: pitchAxis)
      delta("foot.\(side)", -(hip + knee), axis: pitchAxis)
      delta("upper_arm.L", Float.random(in: 0.16...0.28)); delta("upper_arm.R", Float.random(in: -0.28 ... -0.16))
    }
    SCNTransaction.commit()
  }

  private func setEmotion(_ next: QFAssistantEmotion) {
    let next = selectedFace?.emotion ?? next
    currentEmotion = next
    let title = selectedFace ?? {
      switch next {
      case .happy: return QFAssistantFaceSelection.smile
      case .thinking: return .thinking
      case .calm: return .neutral
      case .excited: return .surprised
      case .sad: return .sad
      case .angry: return .angry
      case .shy: return .shy
      }
    }()
    accessibilityValue = title.title(language: interfaceLanguage)
    if let selectedFace, selectedFace.holdsEyes {
      setBlink(left: selectedFace != .rightEyeClosed, right: selectedFace != .leftEyeClosed, weight: 1)
    }
    if modelAsset != nil {
      setModelEmotion(next)
      if let channel = modelAsset?.nodeMap.morphChannels["face_talk"] { channel.morpher.setWeight(selectedFace == .mouthOpen ? 1 : 0, forTargetAt: channel.index) }
      return
    }
    SCNTransaction.begin()
    SCNTransaction.animationDuration = 0.24
    mouthOpen.isHidden = next != .excited || next == .sad
    mouthLine.isHidden = next == .excited
    switch next {
    case .happy, .excited:
      leftBrow.eulerAngles.z = 0.10; rightBrow.eulerAngles.z = -0.10
      mouthLine.position.y = -0.16
      mouthLine.scale = SCNVector3(1.18, 1, 1)
    case .thinking, .shy:
      leftBrow.eulerAngles.z = -0.16; rightBrow.eulerAngles.z = -0.05
      mouthLine.position.y = -0.17; mouthLine.scale = SCNVector3(0.78, 1, 1)
    case .calm:
      leftBrow.eulerAngles.z = 0; rightBrow.eulerAngles.z = 0
      mouthLine.position.y = -0.16; mouthLine.scale = SCNVector3(1, 1, 1)
    case .sad:
      leftBrow.eulerAngles.z = -0.18; rightBrow.eulerAngles.z = 0.18
      mouthOpen.isHidden = true; mouthLine.isHidden = false
      mouthLine.position.y = -0.19; mouthLine.scale = SCNVector3(0.74, 1, 1)
    case .angry:
      leftBrow.eulerAngles.z = 0.28; rightBrow.eulerAngles.z = -0.28
      mouthLine.position.y = -0.15; mouthLine.scale = SCNVector3(0.82, 1, 1)
    }
    if selectedFace == .mouthOpen { mouthOpen.isHidden = false; mouthLine.isHidden = true }
    SCNTransaction.commit()
  }

  private func setModelEmotion(_ next: QFAssistantEmotion) {
    guard let modelAsset else { return }
    SCNTransaction.begin()
    SCNTransaction.animationDuration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.16
    for channel in modelAsset.nodeMap.morphChannels.values where !channel.name.hasPrefix("face_blink") && channel.name != "face_talk" {
      channel.morpher.setWeight(0, forTargetAt: channel.index)
    }
    let morphName: String
    switch next {
    case .happy: morphName = "face_happy"
    case .excited: morphName = "face_surprised"
    case .thinking: morphName = "face_thinking"
    case .sad: morphName = "face_sad"
    case .angry: morphName = "face_angry"
    case .shy: morphName = "face_shy"
    case .calm: morphName = "face_neutral"
    }
    if morphName != "face_neutral", let channel = modelAsset.nodeMap.morphChannels[morphName] {
      channel.morpher.setWeight(1, forTargetAt: channel.index)
    }
    switch next {
    case .happy, .excited:
      leftBrow.eulerAngles.z = 0.10; rightBrow.eulerAngles.z = -0.10
    case .thinking, .shy:
      leftBrow.eulerAngles.z = -0.16; rightBrow.eulerAngles.z = -0.05
    case .calm:
      leftBrow.eulerAngles.z = 0; rightBrow.eulerAngles.z = 0
    case .sad:
      leftBrow.eulerAngles.z = -0.18; rightBrow.eulerAngles.z = 0.18
    case .angry:
      leftBrow.eulerAngles.z = 0.28; rightBrow.eulerAngles.z = -0.28
    }
    SCNTransaction.commit()
  }

  func stopRigAnimation() {
    isAnimationEnabled = false
    poseTask?.cancel(); poseTask = nil
    actionTask?.cancel(); actionTask = nil
    blinkTask?.cancel(); blinkTask = nil
    actionIsPlaying = false
    character.removeAllActions()
    sceneView.isPlaying = false
    scene.isPaused = true
    setBlink(left: true, right: true, weight: 0)
    SCNTransaction.begin(); SCNTransaction.animationDuration = 0.18
    if modelAsset != nil {
      for (name, node) in modelAsset?.nodeMap.bones ?? [:] {
        if let bind = importedBoneBindTransforms[name] { node.simdTransform = bind }
      }
      SCNTransaction.commit()
      return
    }
    head.eulerAngles = SCNVector3(0, 0, 0)
    leftArm.eulerAngles = SCNVector3(0, 0, 0); rightArm.eulerAngles = SCNVector3(0, 0, 0)
    leftElbow.eulerAngles = SCNVector3(0, 0, 0); rightElbow.eulerAngles = SCNVector3(0, 0, 0)
    leftLeg.eulerAngles = SCNVector3(0, 0, 0); rightLeg.eulerAngles = SCNVector3(0, 0, 0)
    SCNTransaction.commit()
  }

  #if DEBUG
  var isAnimatingForValidation: Bool { isAnimationEnabled || poseTask != nil || actionTask != nil || blinkTask != nil }
  func renderValidationWaveTimeline() async -> [UIImage] {
    beginRigAnimation()
    let renderer = SCNRenderer(device: sceneView.device, options: nil)
    renderer.scene = scene; renderer.pointOfView = sceneView.pointOfView
    let start = CACurrentMediaTime()
    _ = renderer.snapshot(atTime: start, with: CGSize(width: 480, height: 560), antialiasingMode: .multisampling4X)
    playSceneAction(.greeting, preferredPose: .wave)
    var frames: [UIImage] = []
    for _ in 0..<40 {
      try? await Task.sleep(nanoseconds: 50_000_000)
      guard !Task.isCancelled else { break }
      frames.append(renderer.snapshot(atTime: CACurrentMediaTime(), with: CGSize(width: 480, height: 560), antialiasingMode: .multisampling4X))
    }
    stopRigAnimation()
    return frames
  }
  /// Validation uses this exact scene, camera, material, rig and chest locator;
  /// a loader-only assertion cannot establish that a character looks correct.
  func renderValidationPose(_ pose: QFAssistantPose) -> UIImage {
    blinkTask?.cancel(); blinkTask = nil
    stopRigAnimation()
    scene.isPaused = false
    SCNTransaction.begin()
    SCNTransaction.disableActions = true
    apply(pose: pose)
    SCNTransaction.commit()
    SCNTransaction.flush()
    let renderer = SCNRenderer(device: sceneView.device, options: nil)
    renderer.scene = scene; renderer.pointOfView = sceneView.pointOfView
    return renderer.snapshot(atTime: 0, with: CGSize(width: 480, height: 560), antialiasingMode: .multisampling4X)
  }

  func renderValidationExpression(_ emotion: QFAssistantEmotion, blink: CGFloat = 0) -> UIImage {
    stopRigAnimation()
    scene.isPaused = false
    SCNTransaction.begin(); SCNTransaction.disableActions = true
    setEmotion(emotion)
    // A manual closed-eye selection owns eyelids just as it does in the app.
    if selectedFace?.holdsEyes != true { setBlink(left: true, right: true, weight: blink) }
    SCNTransaction.commit(); SCNTransaction.flush()
    let renderer = SCNRenderer(device: sceneView.device, options: nil)
    renderer.scene = scene; renderer.pointOfView = sceneView.pointOfView
    return renderer.snapshot(atTime: 1, with: CGSize(width: 480, height: 560), antialiasingMode: .multisampling4X)
  }
  #endif
}
