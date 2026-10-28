import Foundation
import UniformTypeIdentifiers
import UIKit
import XCTest

@testable import QiafanYoupu

/// Exercises the shared production copy logic with task-owned named boards.
/// This does not exercise alert tapping, the general board, or Handoff.
@MainActor
final class QFHouseholdInvitationClipboardTests: XCTestCase {
  private let textType = UTType.utf8PlainText.identifier

  private func withBoard(_ body: (UIPasteboard) async throws -> Void) async throws {
    let name = UIPasteboard.Name(rawValue: "QFHouseholdInvitationClipboardTests." + UUID().uuidString)
    let board = try XCTUnwrap(UIPasteboard(name: name, create: true),
      "The platform must provide the named pasteboard; do not turn this failure into a skip")
    defer { UIPasteboard.remove(withName: name) }
    try await body(board)
  }

  func testFractionalAndWholeSecondDeadlinesCopyUTF8Content() async throws {
    try await withBoard { board in
      let token = "offline-fixture-口令-é-🍅"
      for deadline in ["2100-01-01T00:00:00.125Z", "2100-01-01T00:00:00Z"] {
        let before = board.changeCount
        XCTAssertTrue(QFHouseholdInvitationClipboard.copy(
          token: token, expiresAt: deadline, to: board, now: Date(timeIntervalSince1970: 0)))
        XCTAssertGreaterThan(board.changeCount, before)
        XCTAssertEqual(board.numberOfItems, 1)
        XCTAssertTrue(board.types.contains(self.textType))
        XCTAssertEqual(board.string, token)
        XCTAssertEqual(board.value(forPasteboardType: self.textType) as? String, token)
        let bytes = try XCTUnwrap(board.data(forPasteboardType: self.textType))
        XCTAssertEqual(String(data: bytes, encoding: .utf8), token)
      }
    }
  }

  func testInvalidPastAndExactDeadlineDoNotChangeExistingBoard() async throws {
    try await withBoard { board in
      let sentinel = "sentinel-owned-by-this-test"
      board.setItems([[self.textType: sentinel]], options: [:])
      let before = board.changeCount
      let now = Date(timeIntervalSince1970: 0)
      for deadline in ["not-an-iso-date", "", "1969-12-31T23:59:59Z", "1970-01-01T00:00:00Z"] {
        XCTAssertFalse(QFHouseholdInvitationClipboard.copy(
          token: "must-not-overwrite", expiresAt: deadline, to: board, now: now), deadline)
        XCTAssertEqual(board.changeCount, before, deadline)
        XCTAssertEqual(board.numberOfItems, 1, deadline)
        XCTAssertEqual(board.string, sentinel, deadline)
        XCTAssertEqual(board.value(forPasteboardType: self.textType) as? String, sentinel, deadline)
      }
    }
  }

  func testSameDeadlineAllowsOnlyTheEarlierPolicyTime() async throws {
    try await withBoard { board in
      // 2100-01-01 00:00:00 UTC, derived independently of the production parser.
      let deadline = Date(timeIntervalSince1970: 4_102_444_800)
      let source = "2100-01-01T00:00:00Z"
      XCTAssertTrue(QFHouseholdInvitationClipboard.copy(
        token: "before-deadline", expiresAt: source, to: board,
        now: deadline.addingTimeInterval(-1)))
      XCTAssertEqual(board.string, "before-deadline")
      board.setItems([[self.textType: "policy-sentinel"]], options: [:])
      let before = board.changeCount
      for time in [deadline, deadline.addingTimeInterval(1)] {
        XCTAssertFalse(QFHouseholdInvitationClipboard.copy(
          token: "too-late", expiresAt: source, to: board, now: time))
        XCTAssertEqual(board.changeCount, before)
        XCTAssertEqual(board.string, "policy-sentinel")
      }
    }
  }

  func testSystemExpiresShortLivedNamedBoardContent() async throws {
    try await withBoard { board in
      let deadline = Date().addingTimeInterval(3)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let token = "short-lived-offline-fixture"
      XCTAssertTrue(QFHouseholdInvitationClipboard.copy(
        token: token, expiresAt: formatter.string(from: deadline), to: board))
      XCTAssertEqual(board.string, token)
      let timeout = ProcessInfo.processInfo.systemUptime + 8
      while board.string != nil && ProcessInfo.processInfo.systemUptime < timeout {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      // No app timer clears the board. Unsupported system expiry must fail here.
      XCTAssertNil(board.string, "The system did not expire the named board within the bounded observation")
      XCTAssertFalse(board.hasStrings)
      XCTAssertEqual(board.numberOfItems, 0)
    }
  }
}
