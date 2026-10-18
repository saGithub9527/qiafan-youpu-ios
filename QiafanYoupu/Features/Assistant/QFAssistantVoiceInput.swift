import Foundation

/// A held dictation is a draft, never a submitted chat request. Tokens also
/// invalidate permission and recognition callbacks after release/cancel/scope change.
struct QFAssistantVoiceInput {
  enum Phase { case idle, authorizing, recording, finishing }
  private(set) var phase: Phase = .idle
  private(set) var transcript = ""
  private(set) var cancelArmed = false
  private var token: UUID?
  private var draft = ""
  var currentToken: UUID? { token }
  var isBusy: Bool { phase != .idle }
  func isCurrent(_ value: UUID) -> Bool { token == value && isBusy }
  mutating func begin(draft: String) -> UUID? {
    guard !isBusy else { return nil }
    let value = UUID(); token = value; self.draft = draft
    transcript = ""; cancelArmed = false; phase = .authorizing
    return value
  }
  mutating func start(token: UUID) -> Bool {
    guard isCurrent(token), phase == .authorizing else { return false }
    phase = .recording; return true
  }
  mutating func receive(_ text: String, token: UUID) {
    guard isCurrent(token), phase == .recording || phase == .finishing else { return }
    transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  mutating func setCancelArmed(_ value: Bool) {
    guard phase == .recording || phase == .authorizing else { return }
    cancelArmed = value
  }
  /// True means finish the existing recognizer. False means discard this hold.
  mutating func release() -> Bool {
    guard phase == .recording, !cancelArmed else { cancel(); return false }
    phase = .finishing; return true
  }
  mutating func complete(token: UUID) -> String? {
    guard isCurrent(token) else { return nil }
    let text = transcript
    let result = text.isEmpty ? nil : draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : draft + "\n" + text
    cancel(); return result
  }
  mutating func cancel() {
    token = nil; phase = .idle; transcript = ""; draft = ""; cancelArmed = false
  }
}

#if DEBUG
/// Numeric-only input tap observation for the bounded device check. No audio is
/// stored, returned in diagnostics, or sent to a network service.
final class QFAssistantVoiceBufferProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var frames = 0
  func reset() { lock.lock(); frames = 0; lock.unlock() }
  func append(_ count: Int) { lock.lock(); frames += count; lock.unlock() }
  var count: Int { lock.lock(); defer { lock.unlock() }; return frames }
}
#endif
