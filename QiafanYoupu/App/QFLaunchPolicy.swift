import Foundation

/// Product pause applies to Debug and Release; retained data is not removed.
enum QFAIAvailability {
  static let isEnabled = false

  static func permitsRequest(path: String, method: String) -> Bool {
    if isEnabled || method == "DELETE" { return true }
    let path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if path == "me/weekly-plan-proposals" || path.hasPrefix("me/weekly-plan-proposals/") {
      return method == "GET" // Existing plans remain readable; no new AI work.
    }
    if path == "me/assistant" || path.hasPrefix("me/assistant/") {
      return method == "GET" && ["me/assistant/credits", "me/assistant/memories", "me/assistant/notifications"].contains(path)
    }
    return true
  }
}

enum QFLaunchPolicy {
  /// Changing this key makes an existing installation review the materially updated privacy
  /// policy before an SDK with a new remote recipient can start.
  static let completedKey = "qfyp.onboarding.completed.privacy-1.4-2026-09-28"

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
