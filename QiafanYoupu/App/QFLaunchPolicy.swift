import Foundation

enum QFLaunchPolicy {
  static let completedKey = "qfyp.onboarding.completed"

  static func shouldShowWelcome(isDebug: Bool, completed: Bool) -> Bool {
    isDebug || !completed
  }
}

struct QFLaunchOptions {
  let showWelcome: Bool
  let initialTab: QFTab
  let previewSignedIn: Bool

  init(showWelcome: Bool, initialTab: QFTab, previewSignedIn: Bool) {
    self.showWelcome = showWelcome
    self.initialTab = initialTab
    self.previewSignedIn = previewSignedIn
  }

  init(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments)
  {
    var debug = false
    var skipWelcome = false
    var tab = QFTab.recipe
    var signedInPreview = false
    #if DEBUG
      debug = true
      if arguments.contains("-QFResetUIState"), let bundleID = Bundle.main.bundleIdentifier {
        defaults.removePersistentDomain(forName: bundleID)
      }
      skipWelcome = arguments.contains("-QFSkipWelcome")
      signedInPreview = arguments.contains("-QFPreviewSignedIn")
      if let index = arguments.firstIndex(of: "-QFStartTab"), arguments.indices.contains(index + 1)
      {
        tab = QFTab(rawValue: arguments[index + 1]) ?? .recipe
      }
    #endif
    showWelcome =
      !skipWelcome
      && QFLaunchPolicy.shouldShowWelcome(
        isDebug: debug, completed: defaults.bool(forKey: QFLaunchPolicy.completedKey))
    initialTab = tab
    previewSignedIn = signedInPreview
  }
}
