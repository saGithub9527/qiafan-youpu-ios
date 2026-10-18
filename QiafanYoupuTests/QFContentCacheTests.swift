import Foundation
import XCTest

@testable import QiafanYoupu

/// A transport that can finish after cancellation, as a response already received by a real client can.
/// Tests release every continuation explicitly; no network, sleeps or scheduler polling are used.
@MainActor
private final class QFCacheReadGate<Value> {
  let started: XCTestExpectation
  private(set) var calls = 0
  private var continuation: CheckedContinuation<Value, Error>?
  private var result: Result<Value, Error>?

  init(_ description: String) { started = XCTestExpectation(description: description) }

  func fetch() async throws -> Value {
    calls += 1
    guard calls == 1 else { throw QFCacheFixtureError.unexpectedFetch }
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      started.fulfill()
      if let result {
        self.continuation = nil
        continuation.resume(with: result)
      }
    }
  }

  func finish(_ result: Result<Value, Error>) {
    guard self.result == nil else { return }
    self.result = result
    let pending = continuation
    continuation = nil
    pending?.resume(with: result)
  }
}

private enum QFCacheFixtureError: Error, Equatable { case sharedFailure, unexpectedFetch }

final class QFContentCacheTests: XCTestCase {
  @MainActor
  private func scope() -> String { "QFContentCacheTests." + UUID().uuidString }

  @MainActor
  private func removeSnapshots(_ scope: String) {
    // QFContentCache persists only these snapshots. Never clear unrelated app/test defaults.
    for path in ["me/public-profile", "me/content-summary", "me/interests", "me/settings"] {
      UserDefaults.standard.removeObject(forKey: "qf.content.snapshot." + scope + "|" + path)
    }
  }

  @MainActor
  private func profile(_ nickname: String, avatar: String? = nil) -> QFPublicProfile {
    QFPublicProfile(
      nickname: nickname, countryCode: "CN", regionCode: nil, bio: nil, avatarMediaId: avatar)
  }

  @MainActor
  private func assertCancelled<Value>(
    _ task: Task<Value, Error>, file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      _ = try await task.value
      XCTFail("An invalidated in-flight read returned stale data", file: file, line: line)
    } catch is CancellationError {
      // Expected even when the controlled transport itself completed successfully.
    } catch {
      XCTFail("Expected CancellationError, received \(error)", file: file, line: line)
    }
  }

  @MainActor
  func testConcurrentReadsShareOneFetchAndCacheTheResult() async throws {
    let cache = QFContentCache()
    let scope = self.scope()
    let gate = QFCacheReadGate<String>("first read reached transport")
    let first = Task {
      try await cache.read(scope: scope, path: "me/favorites", query: ["type": "RECIPE"]) {
        try await gate.fetch()
      }
    }
    await fulfillment(of: [gate.started], timeout: 1)
    let secondEntered = expectation(description: "second caller entered shared read")
    var duplicateFetches = 0
    let second = Task {
      secondEntered.fulfill()
      return try await cache.read(scope: scope, path: "me/favorites", query: ["type": "RECIPE"]) {
        duplicateFetches += 1
        return "unexpected second response"
      }
    }
    defer {
      first.cancel()
      second.cancel()
      gate.finish(.failure(CancellationError()))
    }
    await fulfillment(of: [secondEntered], timeout: 1)
    gate.finish(.success("shared response"))
    let firstValue = try await first.value
    let secondValue = try await second.value
    XCTAssertEqual(firstValue, "shared response")
    XCTAssertEqual(secondValue, "shared response")
    XCTAssertEqual(gate.calls, 1)
    XCTAssertEqual(duplicateFetches, 0)
    let cached: String = try await cache.read(
      scope: scope, path: "me/favorites", query: ["type": "RECIPE"]
    ) {
      throw QFCacheFixtureError.unexpectedFetch
    }
    XCTAssertEqual(cached, "shared response")
  }

  @MainActor
  func testSharedFailureReachesBothCallersAndIsNotCached() async throws {
    let cache = QFContentCache()
    let scope = self.scope()
    let gate = QFCacheReadGate<String>("failing shared transport started")
    let first = Task {
      try await cache.read(scope: scope, path: "me/works", query: [:]) { try await gate.fetch() }
    }
    await fulfillment(of: [gate.started], timeout: 1)
    let secondEntered = expectation(description: "second failure waiter entered")
    let second = Task {
      secondEntered.fulfill()
      return try await cache.read(scope: scope, path: "me/works", query: [:]) { () -> String in
        throw QFCacheFixtureError.unexpectedFetch
      }
    }
    defer {
      first.cancel()
      second.cancel()
      gate.finish(.failure(CancellationError()))
    }
    await fulfillment(of: [secondEntered], timeout: 1)
    gate.finish(.failure(QFCacheFixtureError.sharedFailure))
    for task in [first, second] {
      do {
        _ = try await task.value
        XCTFail("Expected the shared transport failure")
      } catch { XCTAssertEqual(error as? QFCacheFixtureError, .sharedFailure) }
    }
    let recovered: String = try await cache.read(scope: scope, path: "me/works", query: [:]) {
      "retry succeeded"
    }
    XCTAssertEqual(recovered, "retry succeeded")
  }

  @MainActor
  func testAccountsAndQueriesAreIsolatedWhileQueryKeyOrderingIsCanonical() async throws {
    let cache = QFContentCache()
    let owner = self.scope()
    let other = self.scope()
    var fetches = 0
    let first: String = try await cache.read(
      scope: owner, path: "catalog", query: ["type": "RECIPE", "q": "rice"]
    ) {
      fetches += 1
      return "owner rice"
    }
    let reordered: String = try await cache.read(
      scope: owner, path: "catalog", query: ["q": "rice", "type": "RECIPE"]
    ) {
      fetches += 1
      return "wrong duplicate"
    }
    let otherQuery: String = try await cache.read(
      scope: owner, path: "catalog", query: ["type": "RECIPE", "q": "soup"]
    ) {
      fetches += 1
      return "owner soup"
    }
    let otherAccount: String = try await cache.read(
      scope: other, path: "catalog", query: ["type": "RECIPE", "q": "rice"]
    ) {
      fetches += 1
      return "other rice"
    }
    XCTAssertEqual(
      [first, reordered, otherQuery, otherAccount],
      ["owner rice", "owner rice", "owner soup", "other rice"])
    XCTAssertEqual(fetches, 3)
  }

  @MainActor
  func testForceRefreshBypassesCachedValueAndStoresTheFreshResponse() async throws {
    let cache = QFContentCache()
    let scope = self.scope()
    cache.store("old", scope: scope, path: "catalog/RECIPE/item")
    let gate = QFCacheReadGate<String>("forced fetch started despite a cached value")
    let refreshing = Task {
      try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await cache.read(scope: scope, path: "catalog/RECIPE/item", query: [:]) {
          try await gate.fetch()
        }
      }
    }
    defer {
      refreshing.cancel()
      gate.finish(.failure(CancellationError()))
    }
    await fulfillment(of: [gate.started], timeout: 1)
    gate.finish(.success("fresh"))
    let fresh = try await refreshing.value
    let cached: String = try await cache.read(scope: scope, path: "catalog/RECIPE/item", query: [:])
    { throw QFCacheFixtureError.unexpectedFetch }
    XCTAssertEqual(fresh, "fresh")
    XCTAssertEqual(cached, "fresh")
    XCTAssertFalse(
      QFContentLoadingContext.forceRefresh, "Force refresh must stay within its task-local scope")
  }

  @MainActor
  func testSavingProfileCancelsOldSummaryAndRelatedWorksReads() async {
    let cache = QFContentCache()
    let scope = self.scope()
    defer { removeSnapshots(scope) }
    let summaryGate = QFCacheReadGate<String>("summary read in flight")
    let worksGate = QFCacheReadGate<String>("related works read in flight")
    let summary = Task {
      try await cache.read(scope: scope, path: "me/content-summary", query: [:]) {
        try await summaryGate.fetch()
      }
    }
    let works = Task {
      try await cache.read(
        scope: scope, path: "catalog/RECIPE/recipe-id/works", query: ["page": "0"]
      ) { try await worksGate.fetch() }
    }
    defer {
      summary.cancel()
      works.cancel()
      summaryGate.finish(.failure(CancellationError()))
      worksGate.finish(.failure(CancellationError()))
    }
    await fulfillment(of: [summaryGate.started, worksGate.started], timeout: 1)
    cache.didWrite(
      profile("New author", avatar: "new-avatar"), scope: scope, path: "me/public-profile")
    // Cancellation alone cannot stop an already completed response from a transport.
    summaryGate.finish(.success("old avatar"))
    worksGate.finish(.success("old author"))
    await assertCancelled(summary)
    await assertCancelled(works)
    XCTAssertNil(cache.peek(String.self, scope: scope, path: "me/content-summary"))
  }

  @MainActor
  func testLateProfileResponseAndItsJoinedReaderCannotReplaceSavedProfile() async {
    let cache = QFContentCache()
    let scope = self.scope()
    defer { removeSnapshots(scope) }
    let gate = QFCacheReadGate<QFPublicProfile>("old profile read in flight")
    let first = Task {
      try await cache.read(scope: scope, path: "me/public-profile", query: [:]) {
        try await gate.fetch()
      }
    }
    await fulfillment(of: [gate.started], timeout: 1)
    let secondEntered = expectation(description: "joined profile caller entered")
    let second = Task {
      secondEntered.fulfill()
      return try await cache.read(scope: scope, path: "me/public-profile", query: [:]) {
        () -> QFPublicProfile in
        throw QFCacheFixtureError.unexpectedFetch
      }
    }
    defer {
      first.cancel()
      second.cancel()
      gate.finish(.failure(CancellationError()))
    }
    await fulfillment(of: [secondEntered], timeout: 1)
    let saved = profile("Saved author", avatar: "saved-avatar")
    cache.didWrite(saved, scope: scope, path: "me/public-profile")
    gate.finish(.success(profile("Old author", avatar: "old-avatar")))
    await assertCancelled(first)
    await assertCancelled(second)
    XCTAssertEqual(cache.peek(QFPublicProfile.self, scope: scope, path: "me/public-profile"), saved)
    cache.clearMemory()
    XCTAssertEqual(
      cache.peek(QFPublicProfile.self, scope: scope, path: "me/public-profile"), saved,
      "The persisted snapshot must also keep the successful save")
  }

  @MainActor
  func testProfileInvalidationPreservesRecipeContentAndAnotherAccountsReads() async throws {
    let cache = QFContentCache()
    let owner = self.scope()
    let other = self.scope()
    defer {
      removeSnapshots(owner)
      removeSnapshots(other)
    }
    let detailGate = QFCacheReadGate<String>("recipe content read in flight")
    let otherGate = QFCacheReadGate<String>("other account summary read in flight")
    let detail = Task {
      try await cache.read(scope: owner, path: "catalog/RECIPE/recipe-id", query: [:]) {
        try await detailGate.fetch()
      }
    }
    let otherSummary = Task {
      try await cache.read(scope: other, path: "me/content-summary", query: [:]) {
        try await otherGate.fetch()
      }
    }
    defer {
      detail.cancel()
      otherSummary.cancel()
      detailGate.finish(.failure(CancellationError()))
      otherGate.finish(.failure(CancellationError()))
    }
    await fulfillment(of: [detailGate.started, otherGate.started], timeout: 1)
    cache.didWrite(profile("Changed author"), scope: owner, path: "me/public-profile")
    detailGate.finish(.success("unchanged recipe"))
    otherGate.finish(.success("other account"))
    let detailValue = try await detail.value
    let otherValue = try await otherSummary.value
    XCTAssertEqual(detailValue, "unchanged recipe")
    XCTAssertEqual(otherValue, "other account")
    let cachedRecipe: String = try await cache.read(
      scope: owner, path: "catalog/RECIPE/recipe-id", query: [:]
    ) { throw QFCacheFixtureError.unexpectedFetch }
    let cachedOther: String = try await cache.read(
      scope: other, path: "me/content-summary", query: [:]
    ) { throw QFCacheFixtureError.unexpectedFetch }
    XCTAssertEqual(cachedRecipe, "unchanged recipe")
    XCTAssertEqual(cachedOther, "other account")
  }
}
