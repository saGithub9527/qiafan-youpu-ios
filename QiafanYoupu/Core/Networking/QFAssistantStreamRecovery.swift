import Foundation

enum QFAssistantStreamRecovery {
  /// Resubscribe only to a server which explicitly advertised the replay protocol.
  /// This must never restart a billable initial POST on an older server.
  static func delay(attempt: Int, supported: Bool, status: Int) -> UInt64? {
    guard supported, (0..<2).contains(attempt), [0, 200, 502, 503, 504].contains(status) else { return nil }
    return attempt == 0 ? 800_000_000 : 2_000_000_000
  }
}
