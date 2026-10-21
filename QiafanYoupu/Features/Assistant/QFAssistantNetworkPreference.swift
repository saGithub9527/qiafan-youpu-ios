import Foundation

/// Retrieval is automatic. Keep the legacy key/API for compatibility, but a
/// previously saved OFF must not disable the current product policy.
enum QFAssistantNetworkPreference {
  static func key(scope: String) -> String { "qf.assistant.local-network." + scope }
  static func isEnabled(defaults: UserDefaults = .standard, key: String) -> Bool {
    true
  }
}
