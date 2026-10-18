import Foundation

public struct QFSSEEvent: Equatable, Sendable {
  public let name: String
  public let id: String
  public let data: String
  public init(name: String, id: String, data: String) { self.name = name; self.id = id; self.data = data }
}

/// Serial-use adapter around unchanged LaunchDarkly parsers. HTTP, cancellation,
/// authentication and terminal-event semantics belong to the existing API client.
public final class QFSSEDecoder: EventHandler {
  public enum Failure: Error { case sizeLimit }
  private let lines = UTF8LineParser()
  private lazy var parser = EventParser(handler: self, initialEventId: "", initialRetry: 1)
  private var events: [QFSSEEvent] = []
  private var firstLine = true
  private var bytes = 0
  private let maximumBytes: Int
  public init(maximumBytes: Int = 4 * 1024 * 1024) { self.maximumBytes = maximumBytes }
  public func append(_ data: Data) throws -> [QFSSEEvent] {
    guard data.count <= maximumBytes - bytes else { throw Failure.sizeLimit }
    bytes += data.count
    for var line in lines.append(data) {
      if firstLine { firstLine = false; if line.first == "\u{FEFF}" { line.removeFirst() } }
      parser.parse(line: line)
    }
    let result = events; events.removeAll(keepingCapacity: true); return result
  }
  public func onMessage(eventType: String, messageEvent: MessageEvent) {
    events.append(.init(name: eventType, id: messageEvent.lastEventId, data: messageEvent.data))
  }
  public func onOpened() {}
  public func onClosed() {}
  public func onComment(comment: String) {}
  public func onError(error: Error) {}
}
