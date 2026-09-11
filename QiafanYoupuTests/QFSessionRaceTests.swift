import Foundation
import XCTest

@testable import QiafanYoupu

private final class QFControlledRequest {
  let request: URLRequest
  private let owner: QFSessionRaceProtocol
  init(_ owner: QFSessionRaceProtocol) {
    self.owner = owner
    request = owner.request
  }
  func respond(_ data: Data, status: Int = 200) { owner.respond(data, status: status) }
  func fail(_ error: Error) { owner.fail(error) }
}

private final class QFSessionRaceProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var routes: [String: QFSessionRaceRouter] = [:]
  private let completionLock = NSLock()
  private var finished = false

  static func register(_ router: QFSessionRaceRouter, host: String) {
    lock.lock()
    defer { lock.unlock() }
    routes[host] = router
  }
  static func remove(host: String) {
    lock.lock()
    defer { lock.unlock() }
    routes.removeValue(forKey: host)
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    let router = Self.routes[request.url?.host ?? ""]
    Self.lock.unlock()
    guard let router else {
      fail(URLError(.unsupportedURL))
      return
    }
    router.receive(QFControlledRequest(self))
  }
  override func stopLoading() {
    completionLock.lock()
    finished = true
    completionLock.unlock()
  }
  private func claimCompletion() -> Bool {
    completionLock.lock()
    defer { completionLock.unlock() }
    guard !finished else { return false }
    finished = true
    return true
  }
  func respond(_ data: Data, status: Int) {
    guard claimCompletion() else { return }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  func fail(_ error: Error) {
    guard claimCompletion() else { return }
    client?.urlProtocol(self, didFailWithError: error)
  }
}

private final class QFSessionRaceRouter {
  private let lock = NSLock()
  private var requests: [QFControlledRequest] = []
  private var handler: ((QFControlledRequest) -> Void)?

  func setHandler(_ handler: @escaping (QFControlledRequest) -> Void) {
    lock.lock()
    self.handler = handler
    lock.unlock()
  }
  func receive(_ request: QFControlledRequest) {
    lock.lock()
    requests.append(request)
    let handler = handler
    lock.unlock()
    handler?(request)
  }
  func matching(_ suffix: String) -> [QFControlledRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests.filter { $0.request.url?.path.hasSuffix(suffix) == true }
  }
}

final class QFSessionRaceTests: XCTestCase {
  private var service: String!
  private var host: String!
  private var transportConfiguration: URLSessionConfiguration!
  private var router: QFSessionRaceRouter!

  override func setUp() {
    super.setUp()
    let id = UUID().uuidString.lowercased()
    service = "com.talka.qiafanyoupu.race-tests.\(id)"
    host = "race-\(id).invalid"
    router = QFSessionRaceRouter()
    QFSessionRaceProtocol.register(router, host: host)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QFSessionRaceProtocol.self]
    transportConfiguration = configuration
  }

  override func tearDownWithError() throws {
    QFSessionRaceProtocol.remove(host: host)
    let keychain = QFKeychainStore(service: service)
    for key in ["current", "device-id", "credential-test"] { try keychain.remove(key) }
    router = nil
    transportConfiguration = nil
    try super.tearDownWithError()
  }

  @MainActor
  private func makeSession() -> QFAppSession {
    let identity = QFDeviceIdentity(service: service)
    let api = QFAPIClient(
      environment: QFAPIEnvironment(name: "test", baseURL: URL(string: "https://\(host!)/api/v1")),
      identity: identity, transportConfiguration: transportConfiguration)
    #if DEBUG
      api.recordsRequests = false
    #endif
    return QFAppSession(api: api, identity: identity, keychain: QFKeychainStore(service: service))
  }

  private func handleCommon(_ request: QFControlledRequest) -> Bool {
    if request.request.url!.path.hasSuffix("app/config") {
      request.respond(
        envelope([
          "appName": "Test", "serviceRegion": "cn", "loginMethods": ["quick": true, "apple": true],
          "agreements": ["userAgreement": "test terms", "privacyPolicy": "test privacy"],
        ]))
      return true
    }
    if request.request.url!.path.hasSuffix("auth/quick/sessions") {
      request.respond(envelope(["session": tokens(1), "user": profile]))
      return true
    }
    return false
  }

  @MainActor
  func testLateOldTokenRejectionsShareOneRotation() async throws {
    let oldRequests = expectation(description: "Two requests use the original access token")
    oldRequests.expectedFulfillmentCount = 2
    let refreshRequest = expectation(description: "One refresh starts")
    let firstRetry = expectation(description: "First retry uses rotated access")
    let secondRetry = expectation(description: "Late rejection reuses rotated access")
    let router = self.router!
    router.setHandler { request in
      if self.handleCommon(request) { return }
      if request.request.url!.path.hasSuffix("refresh") {
        refreshRequest.fulfill()
        return
      }
      if request.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(self.token(1))" {
        oldRequests.fulfill()
      } else if router.matching("me").count == 3 {
        firstRetry.fulfill()
      } else {
        secondRetry.fulfill()
      }
    }
    let session = makeSession()
    await session.start()
    try await session.login(agreementAccepted: true)
    let first = Task { try await session.restoreUser() }
    let second = Task { try await session.restoreUser() }
    await fulfillment(of: [oldRequests], timeout: 3)
    let originals = router.matching("me")
    XCTAssertEqual(originals.count, 2)
    try XCTUnwrap(originals.first).respond(envelope(NSNull(), code: 40100), status: 401)
    await fulfillment(of: [refreshRequest], timeout: 3)
    try XCTUnwrap(router.matching("refresh").first).respond(envelope(tokens(3)))
    await fulfillment(of: [firstRetry], timeout: 3)
    try XCTUnwrap(originals.last).respond(envelope(NSNull(), code: 40100), status: 401)
    await fulfillment(of: [secondRetry], timeout: 3)
    XCTAssertEqual(router.matching("refresh").count, 1)
    let retries = router.matching("me").dropFirst(2)
    XCTAssertEqual(retries.count, 2)
    for request in retries {
      XCTAssertEqual(
        request.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token(3))")
      request.respond(envelope(profile))
    }
    try await first.value
    try await second.value
    XCTAssertEqual(session.user?.userId, "123")
  }

  @MainActor
  func testUnconfirmedRefreshReusesKeyAndTokenAcrossRetryAndRestart() async throws {
    let firstRefresh = expectation(description: "First refresh")
    let secondRefresh = expectation(description: "Retry after timeout")
    let restoredRefresh = expectation(description: "Restart replays pending refresh")
    let router = self.router!
    router.setHandler { request in
      if self.handleCommon(request) { return }
      if request.request.url!.path.hasSuffix("me") {
        request.respond(self.envelope(self.profile))
        return
      }
      switch router.matching("refresh").count {
      case 1: firstRefresh.fulfill()
      case 2: secondRefresh.fulfill()
      default: restoredRefresh.fulfill()
      }
    }
    let session = makeSession()
    await session.start()
    try await session.login(agreementAccepted: true)
    let initial = Task { try await session.refresh() }
    await fulfillment(of: [firstRefresh], timeout: 3)
    let first = try XCTUnwrap(router.matching("refresh").first)
    let key = try XCTUnwrap(first.request.value(forHTTPHeaderField: "Idempotency-Key"))
    XCTAssertEqual(try savedJSON()["pendingRefreshOperationID"] as? String, key.uppercased())
    first.fail(URLError(.timedOut))
    await assertTransportFailure(initial)

    let retry = Task { try await session.refresh() }
    await fulfillment(of: [secondRefresh], timeout: 3)
    let second = try XCTUnwrap(router.matching("refresh").last)
    XCTAssertEqual(second.request.value(forHTTPHeaderField: "Idempotency-Key"), key)
    second.fail(URLError(.networkConnectionLost))
    await assertTransportFailure(retry)

    // A successful but unreceived rotation may have extended expiry on the server already.
    var pendingRecord = try savedJSON()
    pendingRecord["refreshExpiresAt"] =
      Date(timeIntervalSince1970: 1).timeIntervalSinceReferenceDate
    try QFKeychainStore(service: service).write(
      JSONSerialization.data(withJSONObject: pendingRecord), account: "current")
    let restarted = makeSession()
    let startup = Task { await restarted.start() }
    await fulfillment(of: [restoredRefresh], timeout: 3)
    let replay = try XCTUnwrap(router.matching("refresh").last)
    XCTAssertEqual(replay.request.value(forHTTPHeaderField: "Idempotency-Key"), key)
    for request in router.matching("refresh") {
      XCTAssertEqual(try bodyJSON(request.request)["refreshToken"] as? String, token(2))
    }
    replay.respond(envelope(tokens(3)))
    await startup.value
    XCTAssertEqual(restarted.api.accessToken, token(3))
    XCTAssertNil(try savedJSON()["pendingRefreshOperationID"])
    XCTAssertEqual(restarted.user?.userId, "123")
  }

  @MainActor
  func testLogoutWaitsForRefreshAndBlocksNewSessionOperations() async throws {
    let refreshArrived = expectation(description: "Refresh is pending")
    let logoutEntered = expectation(description: "Logout joins pending refresh")
    let deletionArrived = expectation(description: "Logout uses new access")
    let router = self.router!
    router.setHandler { request in
      if self.handleCommon(request) { return }
      if request.request.httpMethod == "DELETE" {
        deletionArrived.fulfill()
      } else {
        refreshArrived.fulfill()
      }
    }
    let session = makeSession()
    await session.start()
    try await session.login(agreementAccepted: true)
    let credential = try QFDeviceIdentity(service: service).credential(environment: "test")
    let refresh = Task { try await session.refresh() }
    await fulfillment(of: [refreshArrived], timeout: 3)
    let logout = Task {
      logoutEntered.fulfill()
      try await session.logout()
    }
    await fulfillment(of: [logoutEntered], timeout: 3)
    do {
      try await session.login(agreementAccepted: true)
      XCTFail("Login must be blocked")
    } catch let error as QFAPIError { XCTAssertEqual(error.code, 40900) }
    do {
      try await session.refresh()
      XCTFail("New refresh must be blocked")
    } catch let error as QFAPIError { XCTAssertEqual(error.code, 40900) }
    XCTAssertTrue(router.matching("current").isEmpty)
    XCTAssertEqual(router.matching("refresh").count, 1)
    try XCTUnwrap(router.matching("refresh").first).respond(envelope(tokens(3)))
    await fulfillment(of: [deletionArrived], timeout: 3)
    let deletion = try XCTUnwrap(router.matching("current").first)
    XCTAssertEqual(
      deletion.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token(3))")
    deletion.respond(envelope(NSNull()))
    try await refresh.value
    try await logout.value
    XCTAssertNil(session.user)
    XCTAssertNil(try QFKeychainStore(service: service).read("current"))
    XCTAssertEqual(
      try QFDeviceIdentity(service: service).credential(environment: "test"), credential)
  }

  @MainActor
  func testLogoutUnauthorizedDoesNotPretendToRevokeSession() async throws {
    router.setHandler { request in
      if self.handleCommon(request) { return }
      if request.request.httpMethod == "DELETE" {
        request.respond(self.envelope(NSNull(), code: 40100), status: 401)
      } else {
        request.respond(self.envelope(NSNull(), code: 50300), status: 503)
      }
    }
    let session = makeSession()
    await session.start()
    try await session.login(agreementAccepted: true)
    do {
      try await session.logout()
      XCTFail("An unavailable confirmation does not prove revocation")
    } catch let error as QFAPIError { XCTAssertEqual(error.code, 50300) }
    XCTAssertNotNil(session.user)
    XCTAssertNotNil(try QFKeychainStore(service: service).read("current"))
    XCTAssertEqual(router.matching("refresh").count, 1)
  }

  @MainActor
  func testLostLogoutResponseCanConfirmInvalidSessionOnRetry() async throws {
    let router = self.router!
    router.setHandler { request in
      if self.handleCommon(request) { return }
      if request.request.httpMethod == "DELETE", router.matching("current").count == 1 {
        // Model a successful server revoke whose response never reaches the client.
        request.fail(URLError(.networkConnectionLost))
      } else {
        request.respond(self.envelope(NSNull(), code: 40100), status: 401)
      }
    }
    let session = makeSession()
    await session.start()
    try await session.login(agreementAccepted: true)
    do {
      try await session.logout()
      XCTFail("The unconfirmed revoke must report failure")
    } catch { XCTAssertTrue(error is URLError) }
    XCTAssertNotNil(session.user)
    try await session.logout()
    XCTAssertNil(session.user)
    XCTAssertNil(try QFKeychainStore(service: service).read("current"))
    XCTAssertEqual(router.matching("current").count, 2)
    XCTAssertEqual(router.matching("refresh").count, 1)
  }

  @MainActor
  func testLogoutUnauthorizedRecoversLiveSessionBeforeRetryingDeletion() async throws {
    let router = self.router!
    router.setHandler { request in
      if self.handleCommon(request) { return }
      if request.request.url!.path.hasSuffix("refresh") {
        request.respond(self.envelope(self.tokens(3)))
      } else if router.matching("current").count == 1 {
        request.respond(self.envelope(NSNull(), code: 40100), status: 401)
      } else {
        request.respond(self.envelope(NSNull()))
      }
    }
    let session = makeSession()
    await session.start()
    try await session.login(agreementAccepted: true)
    try await session.logout()
    XCTAssertEqual(router.matching("current").count, 2)
    XCTAssertEqual(router.matching("refresh").count, 1)
    XCTAssertEqual(
      router.matching("current").last?.request.value(forHTTPHeaderField: "Authorization"),
      "Bearer \(token(3))")
    XCTAssertNil(session.user)
    XCTAssertNil(try QFKeychainStore(service: service).read("current"))
  }

  @MainActor
  func testStaleProfileFailureCannotClearNewLogin() async throws {
    let oldProfile = expectation(description: "Old profile request is pending")
    router.setHandler { request in
      if self.handleCommon(request) { return }
      if request.request.url!.path.hasSuffix("me") {
        oldProfile.fulfill()
        return
      }
      request.respond(self.envelope(["session": self.tokens(5), "user": self.profile]))
    }
    let session = makeSession()
    await session.start()
    try await session.login(agreementAccepted: true)
    let restore = Task { try await session.restoreUser() }
    await fulfillment(of: [oldProfile], timeout: 3)
    try await session.login(authorizationCode: "isolated-test-code", agreementAccepted: true)
    try XCTUnwrap(router.matching("me").first).respond(envelope(NSNull(), code: 40300), status: 403)
    do {
      try await restore.value
      XCTFail("Stale restore should be cancelled")
    } catch is CancellationError {}
    XCTAssertEqual(session.api.accessToken, token(5))
    XCTAssertNotNil(session.user)
  }

  @MainActor
  func testMalformedExistingDeviceCredentialIsNeverOverwritten() throws {
    let keychain = QFKeychainStore(service: service)
    let identity = QFDeviceIdentity(service: service)
    for bytes in [Data([0xff, 0xfe]), Data("malformed-existing-credential".utf8)] {
      try keychain.write(bytes, account: "credential-test")
      XCTAssertThrowsError(try identity.credential(environment: "test"))
      XCTAssertEqual(try keychain.read("credential-test"), bytes)
    }
  }

  private func assertTransportFailure(_ task: Task<Void, Error>) async {
    do {
      try await task.value
      XCTFail("Expected an unconfirmed transport failure")
    } catch { XCTAssertTrue(error is URLError) }
  }
  private func savedJSON() throws -> [String: Any] {
    let data = try XCTUnwrap(QFKeychainStore(service: service).read("current"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
  private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 1024)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
      }
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
  private func token(_ byte: UInt8) -> String {
    Data(repeating: byte, count: 32).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
  private func tokens(_ first: UInt8) -> [String: Any] {
    [
      "accessToken": token(first), "refreshToken": token(first + 1),
      "accessTokenExpiresIn": 3600, "refreshTokenExpiresIn": 86400,
    ]
  }
  private var profile: [String: Any] {
    [
      "userId": "123", "systemAccount": "sys_test", "boundAccount": NSNull(),
      "accountNameBound": false, "passwordConfigured": false, "nickname": "测试用户",
      "avatarUrl": NSNull(), "countryCode": "CN", "regionCode": NSNull(), "bio": NSNull(),
      "appleBound": false,
    ]
  }
  private func envelope(_ data: Any, code: Int = 0) -> Data {
    try! JSONSerialization.data(withJSONObject: [
      "code": code, "message": "isolated test", "requestId": "test", "data": data,
    ])
  }
}
