import Foundation

/// User gestures own the viewport until dragging and deceleration have finished.
/// Network/model updates must never turn following back on during that gesture.
struct QFAssistantScrollFollow {
  private(set) var followsLatest = true
  private(set) var isInteracting = false
  var canFollow: Bool { followsLatest && !isInteracting }
  mutating func beginDragging() { isInteracting = true; followsLatest = false }
  mutating func didScroll(distanceFromBottom: Double) {
    // Content height and offsets also change when a streaming cell lays out.
    // Only the end of a user gesture, or an explicit jump, may opt into follow.
  }
  mutating func keepReading() { followsLatest = false }
  mutating func finishGesture(distanceFromBottom: Double) {
    isInteracting = false
    followsLatest = distanceFromBottom <= 12
  }
  mutating func jumpToLatest() { followsLatest = true; isInteracting = false }
}

/// Presentation buffer only: consumes real received content, never invents tokens.
struct QFAssistantTextReveal {
  private(set) var visible = ""
  private var target = ""
  private var remainingFrames = 0
  init(initial: String = "") { visible = initial; target = initial }
  var isComplete: Bool { visible == target }
  mutating func receive(_ text: String) {
    guard text != target else { return }
    if !text.hasPrefix(visible) { visible = text } // authoritative correction / combined Unicode cluster
    target = text
    remainingFrames = 18
  }
  mutating func step(reduceMotion: Bool = false) {
    let pending = target.count - visible.count
    guard pending > 0 else { return }
    // At 60 fps the final received text catches up within 0.3 seconds. Slow
    // providers still reveal each arriving grapheme; a burst never adds seconds.
    let amount = reduceMotion ? pending : max(1, (pending + max(1, remainingFrames) - 1) / max(1, remainingFrames))
    visible = String(target.prefix(visible.count + amount))
    remainingFrames = max(0, remainingFrames - 1)
  }
}

/// Drawing-only appearance for newly appended text. No full-answer crossfade,
/// artificial words, or layout work is required on the intervening frames.
struct QFAssistantTextFade {
  struct Frame { let range: NSRange; let opacity: Double }
  private struct Segment { let range: NSRange; let start: TimeInterval }
  private var segments: [Segment] = []
  var isActive: Bool { !segments.isEmpty }
  mutating func append(_ range: NSRange, at time: TimeInterval) {
    guard range.length > 0 else { return }
    segments.append(.init(range: range, start: time))
    if segments.count > 32 {
      let first = segments.removeFirst(), second = segments.removeFirst()
      segments.insert(.init(range: NSUnionRange(first.range, second.range), start: first.start), at: 0)
    }
  }
  mutating func advance(at time: TimeInterval) -> [Frame] {
    let frames = segments.map { Frame(range: $0.range, opacity: min(1, max(0, (time - $0.start) / 0.18))) }
    segments = segments.filter { time - $0.start < 0.18 }
    return frames
  }
}
