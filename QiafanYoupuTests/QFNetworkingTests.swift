import Foundation
import XCTest

@testable import QiafanYoupu

private final class QFTestTransport: URLProtocol {
  static let lock = NSLock()
  static var handler: ((URLRequest) throws -> (Int, Data))?
  static var requests: [URLRequest] = []
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    Self.requests.append(request)
    let handler = Self.handler
    Self.lock.unlock()
    do {
      guard let handler else { throw URLError(.badServerResponse) }
      let (status, data) = try handler(request)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json", "Request-Id": "test-request"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
  static func snapshot() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}

final class QFNetworkingTests: XCTestCase {
  private var service: String!
  private var transport: URLSession!

  override func setUp() {
    super.setUp()
    service = "com.talka.qiafanyoupu.tests.\(UUID().uuidString)"
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [QFTestTransport.self]
    transport = URLSession(configuration: config)
    QFTestTransport.lock.lock()
    QFTestTransport.requests = []
    QFTestTransport.handler = nil
    QFTestTransport.lock.unlock()
  }

  override func tearDownWithError() throws {
    transport.invalidateAndCancel()
    let keychain = QFKeychainStore(service: service)
    for key in ["device-id", "credential-test", "current"] { try keychain.remove(key) }
    QFTestTransport.handler = nil
    try super.tearDownWithError()
  }

  @MainActor
  private func makeSession() -> QFAppSession {
    let identity = QFDeviceIdentity(service: service)
    let api = QFAPIClient(
      environment: QFAPIEnvironment(
        name: "test", baseURL: URL(string: "https://example.invalid/api/v1")), identity: identity,
      transport: transport)
    return QFAppSession(api: api, identity: identity, keychain: QFKeychainStore(service: service))
  }

  @MainActor
  func testCommonHeadersAndDeviceIDAreStableWithoutUsingCredentialAsID() throws {
    let identity = QFDeviceIdentity(service: service)
    let api = QFAPIClient(
      environment: QFAPIEnvironment(
        name: "test", baseURL: URL(string: "https://example.invalid/api/v1")), identity: identity,
      transport: transport)
    let first = try api.makeRequest(path: "app/config", method: "GET", body: nil, operationID: nil)
    let operation = UUID()
    api.accessToken = token(1)
    let second = try api.makeRequest(
      path: "auth/quick/sessions", method: "POST", body: Data("{}".utf8), operationID: operation)
    XCTAssertEqual(first.value(forHTTPHeaderField: "App-Platform"), "IOS")
    XCTAssertNotNil(first.value(forHTTPHeaderField: "App-Version"))
    XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "")
    let device = try XCTUnwrap(first.value(forHTTPHeaderField: "Device-Id"))
    XCTAssertNotNil(UUID(uuidString: device))
    XCTAssertEqual(device, second.value(forHTTPHeaderField: "Device-Id"))
    XCTAssertEqual(device, try QFDeviceIdentity(service: service).deviceID())
    XCTAssertNotEqual(device, try identity.credential(environment: "test"))
    XCTAssertEqual(second.value(forHTTPHeaderField: "Authorization"), "Bearer \(token(1))")
    XCTAssertEqual(
      second.value(forHTTPHeaderField: "Idempotency-Key"), operation.uuidString.lowercased())
    XCTAssertEqual(second.url?.path, "/api/v1/auth/quick/sessions")
  }

  @MainActor
  func testSingleQuickRequestThenRestoresSessionWithoutCreatingAnotherAccount() async throws {
    QFTestTransport.handler = { request in
      let path = request.url!.path
      if path.hasSuffix("app/config") { return (200, self.response(self.config)) }
      if path.hasSuffix("auth/quick/sessions") {
        return (200, self.response(["session": self.tokens, "user": self.profile]))
      }
      if path.hasSuffix("me") { return (200, self.response(self.profile)) }
      return (404, self.response(NSNull(), code: 40400))
    }
    let session = makeSession()
    await session.start()
    try await session.login(agreementAccepted: true)
    XCTAssertEqual(session.user?.systemAccount, "sys_test_user")
    let savedCredential = try QFDeviceIdentity(service: service).credential(environment: "test")
    let restarted = makeSession()
    await restarted.start()
    XCTAssertEqual(restarted.user?.userId, "123")
    XCTAssertEqual(
      try QFDeviceIdentity(service: service).credential(environment: "test"), savedCredential)
    let requests = QFTestTransport.snapshot()
    XCTAssertEqual(
      requests.filter { $0.url?.path.hasSuffix("auth/quick/sessions") == true }.count, 1)
    XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("refresh") == true }.count, 0)
    XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token(1))")
  }

  @MainActor
  func testConsentAndServerSwitchPreventUnauthorizedLoginRequests() async throws {
    QFTestTransport.handler = { _ in (200, self.response(self.config)) }
    let session = makeSession()
    await session.start()
    do {
      try await session.login(agreementAccepted: false)
      XCTFail("Consent must gate login")
    } catch let error as QFAPIError { XCTAssertEqual(error.code, 40301) }
    XCTAssertEqual(QFTestTransport.snapshot().count, 1)
    var disabled = config
    disabled["loginMethods"] = ["quick": false, "apple": false]
    QFTestTransport.handler = { _ in (200, self.response(disabled)) }
    await session.loadConfiguration()
    do {
      try await session.login(agreementAccepted: true)
      XCTFail("Disabled method must remain closed")
    } catch let error as QFAPIError { XCTAssertEqual(error.code, 50300) }
    XCTAssertFalse(QFTestTransport.snapshot().contains { $0.httpMethod == "POST" })
  }

  @MainActor
  func testConcurrentExpiredSessionRefreshesOnceAndUsesRotatedToken() async throws {
    QFTestTransport.handler = { request in
      let path = request.url!.path
      if path.hasSuffix("app/config") { return (200, self.response(self.config)) }
      if path.hasSuffix("auth/quick/sessions") {
        var tokens = self.tokens
        tokens["accessTokenExpiresIn"] = 1
        return (200, self.response(["session": tokens, "user": self.profile]))
      }
      if path.hasSuffix("refresh") {
        var tokens = self.tokens
        tokens["accessToken"] = self.token(3)
        tokens["refreshToken"] = self.token(4)
        return (200, self.response(tokens))
      }
      if path.hasSuffix("me") {
        XCTAssertEqual(
          request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.token(3))")
        return (200, self.response(self.profile))
      }
      return (404, self.response(NSNull(), code: 40400))
    }
    let session = makeSession()
    await session.start()
    try await session.login(agreementAccepted: true)
    async let first: Void = session.restoreUser()
    async let second: Void = session.restoreUser()
    _ = try await (first, second)
    XCTAssertEqual(
      QFTestTransport.snapshot().filter { $0.url?.path.hasSuffix("refresh") == true }.count, 1)
    XCTAssertEqual(session.user?.userId, "123")
  }

  @MainActor
  func testNetworkFailureAndBusinessFailureNeverCreateLocalLoginState() async throws {
    QFTestTransport.handler = { request in
      if request.url!.path.hasSuffix("app/config") { return (200, self.response(self.config)) }
      return (503, self.response(NSNull(), code: 50300, message: "功能未开放"))
    }
    let session = makeSession()
    await session.start()
    do {
      try await session.login(agreementAccepted: true)
      XCTFail("503 cannot authenticate")
    } catch let error as QFAPIError { XCTAssertEqual(error.code, 50300) }
    XCTAssertNil(session.user)
    XCTAssertNil(try QFKeychainStore(service: service).read("current"))
    QFTestTransport.handler = { _ in throw URLError(.timedOut) }
    await session.loadConfiguration()
    XCTAssertNotNil(session.configurationError)
    XCTAssertNil(session.configuration)
  }

  @MainActor
  func testLogoutClearsSessionButPreservesDeviceCredential() async throws {
    QFTestTransport.handler = { request in
      if request.url!.path.hasSuffix("app/config") { return (200, self.response(self.config)) }
      if request.httpMethod == "DELETE" { return (200, self.response(NSNull())) }
      return (200, self.response(["session": self.tokens, "user": self.profile]))
    }
    let session = makeSession()
    await session.start()
    try await session.login(agreementAccepted: true)
    let credential = try QFDeviceIdentity(service: service).credential(environment: "test")
    try await session.logout()
    XCTAssertNil(session.user)
    XCTAssertNil(try QFKeychainStore(service: service).read("current"))
    XCTAssertEqual(
      try QFDeviceIdentity(service: service).credential(environment: "test"), credential)
  }

  func testAgreementContentFingerprintInvalidatesPriorChoice() throws {
    let first = try JSONDecoder().decode(
      QFServerConfig.self, from: JSONSerialization.data(withJSONObject: config))
    var second = config
    second["agreements"] = ["userAgreement": "changed", "privacyPolicy": "privacy"]
    let changed = try JSONDecoder().decode(
      QFServerConfig.self, from: JSONSerialization.data(withJSONObject: second))
    XCTAssertNotEqual(first.consentRevision, changed.consentRevision)
    let suite = UserDefaults(suiteName: service)!
    defer { suite.removePersistentDomain(forName: service) }
    QFAuthConsentStore.setAgreementChecked(true, revision: first.consentRevision!, defaults: suite)
    XCTAssertTrue(
      QFAuthConsentStore.isAgreementChecked(revision: first.consentRevision!, defaults: suite))
    XCTAssertFalse(
      QFAuthConsentStore.isAgreementChecked(revision: changed.consentRevision!, defaults: suite))
  }

  private func token(_ value: UInt8) -> String {
    Data(repeating: value, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  private var tokens: [String: Any] {
    [
      "accessToken": token(1), "refreshToken": token(2), "accessTokenExpiresIn": 3600,
      "refreshTokenExpiresIn": 86400,
    ]
  }
  private var profile: [String: Any] {
    [
      "userId": "123", "systemAccount": "sys_test_user", "boundAccount": NSNull(),
      "accountNameBound": false,
      "passwordConfigured": false, "nickname": "测试用户", "avatarUrl": NSNull(), "countryCode": "CN",
      "regionCode": NSNull(),
      "bio": NSNull(), "appleBound": false,
    ]
  }
  private var config: [String: Any] {
    [
      "appName": "恰饭有谱", "serviceRegion": "cn", "loginMethods": ["quick": true, "apple": true],
      "agreements": ["userAgreement": "test terms", "privacyPolicy": "test privacy"],
    ]
  }
  private func response(_ data: Any, code: Int = 0, message: String = "成功") -> Data {
    try! JSONSerialization.data(withJSONObject: [
      "code": code, "message": message, "requestId": "test", "data": data,
    ])
  }
}
