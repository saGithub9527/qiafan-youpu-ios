import Foundation

/// The absence of a saved choice means enabled. Only an explicit switch action
/// persists a preference; reopening chat never overwrites the user's OFF value.
enum QFAssistantNetworkPreference {
  static func key(scope: String) -> String { "qf.assistant.local-network." + scope }
  static func isEnabled(defaults: UserDefaults = .standard, key: String) -> Bool {
    (defaults.object(forKey: key) as? Bool) ?? true
  }
}
