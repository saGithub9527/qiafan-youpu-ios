import XCTest
@testable import QFSSE

final class DecoderTests: XCTestCase {
  func testByteSplitUnicodeCRLFAndMultiline() throws {
    let decoder = QFSSEDecoder()
    let data = Data("\u{FEFF}: heartbeat\r\nevent: delta\r\nid: 1\r\ndata: 你好\r\ndata: 世界\r\n\r\n".utf8)
    var events: [QFSSEEvent] = []
    for byte in data { events += try decoder.append(Data([byte])) }
    XCTAssertEqual(events, [.init(name: "delta", id: "1", data: "你好\n世界")])
  }
  func testMultipleEventsInOneChunkAndEmptyData() throws {
    let events = try QFSSEDecoder().append(Data("event: status\ndata: {}\n\nevent: done\ndata:\n\n".utf8))
    XCTAssertEqual(events.map(\.name), ["status", "done"])
    XCTAssertEqual(events.last?.data, "")
  }
  func testEOFDoesNotInventCompletedEvent() throws {
    XCTAssertTrue(try QFSSEDecoder().append(Data("event: delta\ndata: unfinished".utf8)).isEmpty)
  }
  func testStreamBudgetRejectsUnterminatedInput() throws {
    let decoder = QFSSEDecoder(maximumBytes: 12)
    XCTAssertTrue(try decoder.append(Data("data: small".utf8)).isEmpty)
    XCTAssertThrowsError(try decoder.append(Data(" too long".utf8)))
  }
  func testNullIDIsIgnored() throws {
    let events = try QFSSEDecoder().append(Data("id: safe\ndata: a\n\nid: bad\0id\ndata: b\n\n".utf8))
    XCTAssertEqual(events.map(\.id), ["safe", "safe"])
  }
}
