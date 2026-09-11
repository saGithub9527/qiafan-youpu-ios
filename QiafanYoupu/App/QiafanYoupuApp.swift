import SnapKit
import UIKit

@main
final class QFAppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    return true
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
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
  private let session = QFAppSession()
  private var startup: Task<Void, Never>?
  private var didScheduleCrashRecorder = false

  func scene(
    _ scene: UIScene, willConnectTo sceneSession: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: windowScene)
    window.overrideUserInterfaceStyle = .light
    window.tintColor = QFUI.orange
    window.rootViewController = QFRootViewController(app: session, options: QFLaunchOptions())
    self.window = window
    window.makeKeyAndVisible()
    if !QFRuntime.isUnitTest {
      startup = Task { [session] in await session.start() }
    }
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    guard !QFRuntime.isUnitTest, !didScheduleCrashRecorder else { return }
    didScheduleCrashRecorder = true

    // Keep crash-report decoding and disk maintenance away from the window's first frame.
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
      _ = QFCrashRecorder.shared.start()
    }
  }
}

enum QFTab: String, CaseIterable, Identifiable {
  case recipe, plan, ingredient, profile
  var id: String { rawValue }
  var title: String {
    switch self {
    case .recipe: return "菜谱"
    case .plan: return "计划"
    case .ingredient: return "食材"
    case .profile: return "我的"
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
  private var current: UIViewController?

  init(app: QFAppSession, options: QFLaunchOptions) {
    self.app = app
    self.options = options
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    if options.showWelcome {
      install(QFWelcomeViewController(app: app) { [weak self] in
        UserDefaults.standard.set(true, forKey: QFLaunchPolicy.completedKey)
        self?.showTabs()
      })
    } else {
      showTabs()
    }
  }

  private func showTabs() {
    install(QFMainTabViewController(app: app, options: options))
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
  }
}

@MainActor
private final class QFMainTabViewController: UIViewController {
  private let app: QFAppSession
  private let options: QFLaunchOptions
  private var pages: [QFTab: UIViewController] = [:]
  private var buttons: [QFTab: QFTabButton] = [:]
  private let contentView = UIView()
  private let bar = UIView()
  private var selected: QFTab

  init(app: QFAppSession, options: QFLaunchOptions) {
    self.app = app
    self.options = options
    selected = options.initialTab
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.addSubview(bar)
    bar.backgroundColor = .white
    bar.snp.makeConstraints {
      $0.leading.trailing.bottom.equalToSuperview()
      // Keep the tabs above a docked keyboard; the guide returns to the safe-area bottom when hidden.
      $0.top.equalTo(view.keyboardLayoutGuide.snp.top).offset(-56)
    }
    let tabStack = UIStackView()
    tabStack.axis = .horizontal
    tabStack.distribution = .fillEqually
    bar.addSubview(tabStack)
    tabStack.snp.makeConstraints {
      $0.top.centerX.equalToSuperview()
      $0.height.equalTo(56)
      $0.leading.greaterThanOrEqualToSuperview()
      $0.trailing.lessThanOrEqualToSuperview()
      $0.width.equalToSuperview().priority(999)
      $0.width.lessThanOrEqualTo(QFAdaptiveLayout.contentMaxWidth)
    }
    let divider = UIView()
    divider.backgroundColor = QFUI.border
    bar.addSubview(divider)
    divider.snp.makeConstraints { $0.leading.trailing.top.equalToSuperview(); $0.height.equalTo(0.5) }
    view.addSubview(contentView)
    contentView.snp.makeConstraints {
      $0.top.leading.trailing.equalTo(view.safeAreaLayoutGuide)
      $0.bottom.equalTo(bar.snp.top)
    }
    pages = [
      .recipe: QFRecipeViewController(app: app),
      .plan: QFPlanViewController(app: app),
      .ingredient: QFIngredientViewController(app: app),
      .profile: QFProfileViewController(app: app, previewSignedIn: options.previewSignedIn) {
        [weak self] in self?.showLogin()
      },
    ]
    for tab in QFTab.allCases {
      let button = QFTabButton(tab: tab)
      button.addAction(UIAction { [weak self] _ in self?.select(tab) }, for: .touchUpInside)
      buttons[tab] = button
      tabStack.addArrangedSubview(button)
      guard let page = pages[tab] else { continue }
      addChild(page)
      contentView.addSubview(page.view)
      page.view.snp.makeConstraints { $0.edges.equalToSuperview() }
      page.didMove(toParent: self)
    }
    select(selected)
    QFDiagnosticsPresenter.attach(to: self, app: app, bottomInset: 76)
  }

  private func select(_ tab: QFTab) {
    view.endEditing(true)
    selected = tab
    for item in QFTab.allCases {
      pages[item]?.view.isHidden = item != tab
      buttons[item]?.isSelected = item == tab
    }
  }

  private func showLogin() {
    guard presentedViewController == nil else { return }
    let controller = QFLoginViewController(app: app) { [weak self] in
      self?.dismiss(animated: true)
    }
    controller.modalPresentationStyle = .fullScreen
    present(controller, animated: true)
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
    stack.snp.makeConstraints { $0.center.equalToSuperview(); $0.leading.trailing.equalToSuperview() }
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

private enum QFRuntime {
  static var isUnitTest: Bool {
    #if DEBUG
      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
    #else
      false
    #endif
  }
}
