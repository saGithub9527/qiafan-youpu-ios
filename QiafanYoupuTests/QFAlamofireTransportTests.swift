import Foundation
import XCTest
import UIKit

@testable import QiafanYoupu

private enum QFTransportAction {
  case response(Int, [String: String], Data)
  case failure(Error)
  case wait
}

private final class QFTransportRoute {
  private let lock = NSLock()
  private var requests: [URLRequest] = []
  let action: (URLRequest) -> QFTransportAction
  let onStop: (() -> Void)?

  init(
    onStop: (() -> Void)? = nil,
    action: @escaping (URLRequest) -> QFTransportAction
  ) {
    self.onStop = onStop
    self.action = action
  }

  func receive(_ request: URLRequest) -> QFTransportAction {
    lock.lock()
    requests.append(request)
    lock.unlock()
    return action(request)
  }

  func snapshot() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}

/// Each test owns a separate hostname, including when the suite runs in parallel.
private final class QFAlamofireTestProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var routes: [String: QFTransportRoute] = [:]
  private var route: QFTransportRoute?

  static func register(_ route: QFTransportRoute?, host: String) {
    lock.lock()
    defer { lock.unlock() }
    routes[host] = route
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    let route = Self.routes[request.url?.host ?? ""]
    Self.lock.unlock()
    self.route = route
    guard let route else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    switch route.receive(request) {
    case .response(let status, let headers, let data):
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    case .failure(let error):
      client?.urlProtocol(self, didFailWithError: error)
    case .wait:
      break
    }
  }

  override func stopLoading() { route?.onStop?() }
}

final class QFAlamofireTransportTests: XCTestCase {
  func testAssistantRequestCapturesHouseholdAndTimezoneWithoutClientAuthorityFields() throws {
    let family = UUID().uuidString.lowercased()
    let payload = QFAssistantChatRequest(text: "今天晚餐吃什么？", allowCloud: true, allowWeb: true,
      history: [.init(role: "user", content: "之前的问题")], householdId: family, timeZone: "Asia/Shanghai")
    let (body, type) = try payload.encoded(imageData: nil, mimeType: "image/jpeg")
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(type, "application/json")
    XCTAssertEqual(Set(object.keys), ["text", "allowCloud", "allowWeb", "history", "householdId", "timeZone"])
    XCTAssertEqual(object["allowWeb"] as? Bool, true)
    XCTAssertEqual(object["householdId"] as? String, family)
    XCTAssertEqual(object["timeZone"] as? String, "Asia/Shanghai")
    XCTAssertNil(object["userId"]); XCTAssertNil(object["model"])
  }

  func testAssistantPersonalImageRequestPreservesTimezoneHistoryAndImage() throws {
    let payload = QFAssistantChatRequest(text: "图片中的食材", allowCloud: true, allowWeb: false,
      history: [.init(role: "assistant", content: "历史回答")], householdId: nil, timeZone: "America/Los_Angeles")
    let bytes = Data([0x89, 0x50, 0x4E, 0x47])
    let (body, type) = try payload.encoded(imageData: bytes, mimeType: "image/png")
    let wire = String(decoding: body, as: UTF8.self)
    XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
    XCTAssertTrue(wire.contains("name=\"timeZone\"\r\n\r\nAmerica/Los_Angeles"))
    XCTAssertTrue(wire.contains("name=\"history\""))
    XCTAssertTrue(wire.contains("name=\"allowWeb\"\r\n\r\nfalse"))
    XCTAssertTrue(wire.contains("filename=\"image.png\""))
    XCTAssertNotNil(body.range(of: bytes))
    XCTAssertFalse(wire.contains("name=\"householdId\""))
    let personal = try payload.encoded(imageData: nil, mimeType: "image/png")
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: personal.body) as? [String: Any])
    XCTAssertNil(object["householdId"])
    XCTAssertEqual(object["allowWeb"] as? Bool, false)
    XCTAssertThrowsError(try payload.encoded(imageData: bytes, mimeType: "image/gif"))
  }

  func testLegacyChatRequestOmitsUnsupportedWebConsentForBothWireFormats() throws {
    let payload = QFAssistantChatRequest(text: "hello", allowCloud: true, history: [], householdId: nil, timeZone: "UTC")
    let plain = try payload.encoded(imageData: nil, mimeType: "image/jpeg")
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: plain.body) as? [String: Any])
    XCTAssertNil(object["allowWeb"])
    let multipart = try payload.encoded(imageData: Data([0xFF, 0xD8]), mimeType: "image/jpeg")
    XCTAssertFalse(String(decoding: multipart.body, as: UTF8.self).contains("name=\"allowWeb\""))
  }

  @MainActor
  private func withConversation(_ body: (QFAppSession, QFDigitalAssistantConversationViewController, UIWindow, @escaping (UIApplication.State) -> Void) async throws -> Void) async throws {
    let app = QFAppSession(api: makeClient(), keychain: QFKeychainStore(service: service))
    app.setInterfaceLanguage("zh-Hans")
    var state = UIApplication.State.active
    let chat = QFDigitalAssistantConversationViewController(app: app, applicationState: { state })
    let nav = UINavigationController(rootViewController: chat)
    let window: UIWindow
    if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
      window = UIWindow(windowScene: scene)
    } else { window = UIWindow(frame: UIScreen.main.bounds) }
    let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
    window.rootViewController = nav; window.makeKeyAndVisible()
    window.layoutIfNeeded(); chat.view.layoutIfNeeded()
    let zhKey = "qf.assistant.conversation.v2.\(QFAssistantAgent.scope(app).cacheKey)"
    defer {
      chat.debugEndScene(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
      UserDefaults.standard.removeObject(forKey: zhKey)
      UserDefaults.standard.removeObject(forKey: "qf.assistant.conversation.v2.\(QFAssistantAgent.scope(app).cacheKey)")
    }
    try await body(app, chat, window, { state = $0 })
  }

  @MainActor
  func testAssistantBackgroundCompletionReappearsWithFullAnswer() async throws {
    try await withConversation { _, chat, _, setState in
      _ = chat.debugBeginStreaming(text: "已生成的开头")
      setState(.background)
      chat.debugCompleteStreaming(text: "已生成的开头，以及后台完成的完整回答。")
      setState(.active)
      NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
      try await Task.sleep(nanoseconds: 100_000_000)
      XCTAssertEqual(chat.debugVisibleAnswer, "已生成的开头，以及后台完成的完整回答。")
    }
  }

  @MainActor
  func testAssistantMemorySheetStopsCaptureButKeepsSubmittedAnswerRunning() async throws {
    try await withConversation { _, chat, _, _ in
      let task = chat.debugBeginStreaming(text: "")
      defer { task.cancel() }
      // Speech recognition now streams audio in memory; the permission token remains the lifecycle boundary.
      let permissionToken = try XCTUnwrap(chat.debugBeginCapture())
      chat.debugOpenMemory()
      XCTAssertFalse(chat.debugCaptureIsCurrent(permissionToken), "Late permission/transcription callbacks must lose authority")
      XCTAssertFalse(task.isCancelled, "Opening a feature must preserve a submitted generation")
      chat.presentedViewController?.dismiss(animated: false)
    }
  }

  @MainActor
  func testAssistantClosingStopsCaptureButKeepsSubmittedAnswerRunning() async throws {
    try await withConversation { _, chat, _, _ in
      let task = chat.debugBeginStreaming(text: "")
      defer { task.cancel() }
      // Speech recognition now streams audio in memory; the permission token remains the lifecycle boundary.
      let permissionToken = try XCTUnwrap(chat.debugBeginCapture())
      chat.debugClose()
      XCTAssertFalse(chat.debugCaptureIsCurrent(permissionToken))
      XCTAssertFalse(task.isCancelled)
    }
  }

  @MainActor
  func testAssistantReusedControllerRefreshesLanguageAndFailureAccessibility() async throws {
    try await withConversation { app, chat, _, _ in
      XCTAssertEqual(chat.title, "饮食助手")
      app.setInterfaceLanguage("en")
      try await Task.sleep(nanoseconds: 100_000_000)
      XCTAssertEqual(chat.title, "Diet assistant")
      XCTAssertEqual(chat.navigationItem.leftBarButtonItem?.accessibilityLabel, "Close")
      XCTAssertEqual(chat.debugMessageAccessibility, "Message")
      let cell = QFAssistantChatCell(style: .default, reuseIdentifier: nil)
      @MainActor func button(_ view: UIView) -> UIView? {
        if view.accessibilityIdentifier == "assistant.process.toggle" { return view }
        return view.subviews.lazy.compactMap { button($0) }.first
      }
      var item = QFAssistantLocalMessage(id: UUID(), role: "assistant", text: "", createdAt: Date(), state: "complete", process: [.init(stage: "generating", state: "complete")])
      cell.configure(item, app: app, expanded: false, actionTitle: { _ in "" })
      XCTAssertEqual(button(cell)?.accessibilityValue, "Completed")
      item.state = "failed"
      cell.configure(item, app: app, expanded: false, actionTitle: { _ in "" })
      XCTAssertEqual(button(cell)?.accessibilityValue, "Generation failed")
    }
  }

  private struct Fixture: Decodable {
    let value: String
  }

  private var service: String!
  private var host: String!
  private var configuration: URLSessionConfiguration!
  private var route: QFTransportRoute!

  override func setUp() {
    super.setUp()
    let id = UUID().uuidString.lowercased()
    service = "com.talka.qiafanyoupu.transport-tests.\(id)"
    host = "transport-\(id).invalid"
    configuration = .ephemeral
    configuration.protocolClasses = [QFAlamofireTestProtocol.self]
  }

  override func tearDownWithError() throws {
    QFAlamofireTestProtocol.register(nil, host: host)
    route = nil
    configuration = nil
    try QFKeychainStore(service: service).remove("device-id")
    try super.tearDownWithError()
  }

  private func stub(
    onStop: (() -> Void)? = nil,
    action: @escaping (URLRequest) -> QFTransportAction
  ) {
    route = QFTransportRoute(onStop: onStop, action: action)
    QFAlamofireTestProtocol.register(route, host: host)
  }

  @MainActor
  private func makeClient() -> QFAPIClient {
    let api = QFAPIClient(
      environment: QFAPIEnvironment(
        name: "test", baseURL: URL(string: "https://\(host!)/api/v1")),
      identity: QFDeviceIdentity(service: service), transportConfiguration: configuration)
    #if DEBUG
      api.recordsRequests = false
    #endif
    return api
  }

  @MainActor
  func testServiceUnavailableIsOneRequestAndKeepsBusinessEnvelope() async throws {
    let data = envelope(NSNull(), code: 50300, message: "fixture service unavailable")
    stub { _ in .response(503, self.headers, data) }
    let api = makeClient()
    let operation = UUID()
    do {
      let _: Fixture = try await api.send(
        path: "auth/quick/sessions", method: "POST", body: Data("{}".utf8),
        operationID: operation)
      XCTFail("503 cannot authenticate or trigger an automatic retry")
    } catch let error as QFAPIError {
      XCTAssertEqual(error.code, 50300)
      XCTAssertEqual(error.message, "fixture service unavailable")
      XCTAssertEqual(error.requestId, "fixture-request-id")
    }
    let requests = route.snapshot()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "")
    XCTAssertEqual(
      requests.first?.value(forHTTPHeaderField: "Idempotency-Key"),
      operation.uuidString.lowercased())
  }

  @MainActor
  func testTransportFailureUnwrapsOriginalURLErrorWithoutRetry() async throws {
    stub { _ in .failure(URLError(.timedOut)) }
    do {
      let _: Fixture = try await makeClient().send(path: "app/config")
      XCTFail("The transport failure must be exposed")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .timedOut)
    }
    XCTAssertEqual(route.snapshot().count, 1)
  }

  @MainActor
  func testTaskCancellationStopsUnderlyingRequest() async throws {
    let started = expectation(description: "The URL loading task starts")
    let stopped = expectation(description: "Cancellation stops the URL loading task")
    stub(onStop: { stopped.fulfill() }) { _ in
      started.fulfill()
      return .wait
    }
    let api = makeClient()
    let request = Task { () throws -> Fixture in try await api.send(path: "app/config") }
    await fulfillment(of: [started], timeout: 3)
    request.cancel()
    await fulfillment(of: [stopped], timeout: 3)
    do {
      _ = try await request.value
      XCTFail("A cancelled task must not return a successful response")
    } catch is CancellationError {}
    XCTAssertEqual(route.snapshot().count, 1)
  }

  @MainActor
  func testAlreadyCancelledTaskDoesNotSendARequest() async throws {
    stub { _ in .response(200, self.headers, self.envelope(["value": "unexpected"])) }
    let api = makeClient()
    let task = Task { () throws -> Fixture in
      withUnsafeCurrentTask { $0?.cancel() }
      return try await api.send(path: "app/config")
    }
    do {
      _ = try await task.value
      XCTFail("Pre-cancelled work must not reach the transport")
    } catch is CancellationError {}
    XCTAssertTrue(route.snapshot().isEmpty)
  }

  @MainActor
  func testRedirectPolicyRejectsSameAndCrossOriginDestinations() throws {
    let transport = QFAPIClient.makeTransport(configuration: configuration)
    let handler = try XCTUnwrap(transport.redirectHandler)
    XCTAssertNil(transport.interceptor)
    XCTAssertNil(transport.session.configuration.urlCredentialStorage)
    let original = URL(string: "https://\(host!)/api/v1/app/config")!
    let foundationSession = URLSession(configuration: .ephemeral)
    defer { foundationSession.invalidateAndCancel() }
    // The suspended task is only callback context; no network request is started.
    let task = foundationSession.dataTask(with: original)
    for target in ["https://\(host!)/redirected", "https://different-origin.invalid/redirected"] {
      var redirected = URLRequest(url: URL(string: target)!)
      redirected.setValue("Bearer fixture-authorization", forHTTPHeaderField: "Authorization")
      let response = HTTPURLResponse(
        url: original, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": target])!
      var didDecide = false
      handler.task(task, willBeRedirectedTo: redirected, for: response) { request in
        didDecide = true
        XCTAssertNil(request, "The installed policy must never forward credentials on redirect")
      }
      XCTAssertTrue(didDecide)
    }
  }

  @MainActor
  func testHTTPRedirectStatusIsReturnedWithoutRetry() async throws {
    stub { _ in .response(302, ["Location": "https://different-origin.invalid/redirected"], Data())
    }
    let api = makeClient()
    api.accessToken = "fixture-authorization"
    do {
      let _: Fixture = try await api.send(path: "app/config")
      XCTFail("Redirects must be returned to the caller instead of followed")
    } catch let error as QFAPIError {
      XCTAssertEqual(error.code, 302)
    }
    XCTAssertEqual(route.snapshot().count, 1)
  }

  @MainActor
  func testResponsesLargerThanTwoMiBAreRejectedBeforeDecoding() async throws {
    let oversized = envelope(["value": String(repeating: "a", count: 2 * 1024 * 1024)])
    stub { _ in .response(200, self.headers, oversized) }
    do {
      let _: Fixture = try await makeClient().send(path: "app/config")
      XCTFail("The existing response size limit must remain enforced")
    } catch let error as QFAPIError {
      XCTAssertEqual(error.code, 50000)
    }
  }

  @MainActor
  func testCacheAndResponseCookiesAreNotReused() async throws {
    let cache = URLCache(memoryCapacity: 1024 * 1024, diskCapacity: 0, diskPath: nil)
    configuration.urlCache = cache
    configuration.requestCachePolicy = .returnCacheDataElseLoad
    configuration.httpShouldSetCookies = true
    configuration.httpCookieStorage = .shared
    let api = makeClient()
    let request = try api.makeRequest(
      path: "app/config", method: "GET", body: nil, operationID: nil)
    var responseHeaders = headers
    responseHeaders["Cache-Control"] = "public, max-age=3600"
    responseHeaders["Set-Cookie"] = "fixture_session=fixture-cookie; Path=/; Secure"
    let cachedResponse = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: responseHeaders)!
    cache.storeCachedResponse(
      CachedURLResponse(response: cachedResponse, data: envelope(["value": "cached"])), for: request
    )
    stub { _ in .response(200, responseHeaders, self.envelope(["value": "network"])) }
    let first: Fixture = try await api.send(path: "app/config")
    let second: Fixture = try await api.send(path: "app/config")
    XCTAssertEqual(first.value, "network")
    XCTAssertEqual(second.value, "network")
    XCTAssertEqual(route.snapshot().count, 2)
    XCTAssertTrue(route.snapshot().allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    XCTAssertFalse(
      HTTPCookieStorage.shared.cookies?.contains { $0.domain == host } ?? false,
      "The API must not store response cookies in the shared cookie jar")
  }

  #if DEBUG
    @MainActor
    func testAlamofireResponseKeepsRawDebugFixtureValues() async throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "QFTransportLogs-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = QFRequestLogStore(directoryURL: directory)
      let body = envelope([
        "value": "fixture result", "accessToken": "fixture-access-token",
        "accessTokenExpiresIn": 7200, "refreshToken": "fixture-refresh-token",
        "refreshTokenExpiresIn": 2_592_000, "passwordConfigured": false,
      ])
      stub { _ in .response(200, self.headers, body) }
      let api = makeClient()
      api.recordsRequests = true
      api.requestLogStore = store
      api.accessToken = "fixture-request-authorization"
      let result: Fixture = try await api.send(
        path: "auth/quick/sessions", method: "POST",
        body: Data(#"{"deviceCredential":"fixture-device-credential"}"#.utf8))
      XCTAssertEqual(result.value, "fixture result")
      let entry = try XCTUnwrap(store.entries.first)
      XCTAssertEqual(entry.statusCode, 200)
      XCTAssertNotNil(entry.finishedAt)
      XCTAssertNil(entry.errorDescription)
      XCTAssertEqual(
        entry.requestHeaders.first { $0.key.lowercased() == "authorization" }?.value,
        "Bearer fixture-request-authorization")
      XCTAssertTrue(entry.requestBody.contains("fixture-device-credential"))
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(entry.responseBody.utf8)) as? [String: Any])
      let data = try XCTUnwrap(object["data"] as? [String: Any])
      XCTAssertEqual(data["accessToken"] as? String, "fixture-access-token")
      XCTAssertEqual(data["refreshToken"] as? String, "fixture-refresh-token")
      XCTAssertEqual(data["accessTokenExpiresIn"] as? Int, 7200)
      XCTAssertEqual(data["refreshTokenExpiresIn"] as? Int, 2_592_000)
      XCTAssertEqual(data["passwordConfigured"] as? Bool, false)
      XCTAssertFalse(entry.responseBody.contains("[REDACTED]"))
    }
  #endif

  @MainActor
  func testAssistantPreStreamHTTP401AllowsOneSessionRefresh() async throws {
    let body = envelope(NSNull(), code: 40100, message: "expired fixture")
    do {
      _ = try await assistantStream(status: 401, contentType: "application/json", data: body)
      XCTFail("A pre-stream HTTP 401 must expose an explicit authentication-rejection marker")
    } catch let rejection as QFAssistantStreamHTTPUnauthorized {
      XCTAssertEqual(rejection.failure.code, 40100)
      XCTAssertEqual(rejection.failure.message, "expired fixture")
    }
    XCTAssertEqual(route.snapshot().count, 1)
  }

  @MainActor
  func testAssistantPreStreamHTTP401WithoutJsonKeepsTheSameRefreshGate() async throws {
    do {
      _ = try await assistantStream(status: 401, contentType: "application/json", data: Data())
      XCTFail("An empty HTTP 401 is still an HTTP authentication rejection")
    } catch let rejection as QFAssistantStreamHTTPUnauthorized {
      XCTAssertEqual(rejection.failure.code, 40100)
    }
    XCTAssertEqual(route.snapshot().count, 1)
  }

  @MainActor
  func testAssistantBodyCode401DoesNotAuthorizeRefreshForOtherHttpStatuses() async throws {
    for status in [200, 403, 429, 503] {
      do {
        _ = try await assistantStream(status: status, contentType: "application/json",
          data: envelope(NSNull(), code: 40100, message: "body must not authorize a replay"))
        XCTFail("Only HTTP 401 may authorize the refresh gate")
      } catch let failure as QFAPIError {
        XCTAssertEqual(failure.code, 40100)
      }
      XCTAssertEqual(route.snapshot().count, 1)
    }
  }

  @MainActor
  func testAssistantFirstSseError401CannotBecomeAReplayableHttpFailure() async throws {
    let wire = "event: error\ndata: {\"code\":40100,\"message\":\"already streaming\"}\n\n"
    do {
      _ = try await assistantStream(status: 200, contentType: "text/event-stream", data: Data(wire.utf8))
      XCTFail("A terminal SSE error must be returned without automatic replay authority")
    } catch let failure as QFAPIError {
      XCTAssertEqual(failure.code, 40100)
      XCTAssertEqual(failure.message, "already streaming")
    }
    XCTAssertEqual(route.snapshot().count, 1)
  }

  @MainActor
  func testAssistantUnknownSseEventAlsoBlocksReplayEvenWithHttp401() async throws {
    let wire = "event: future-event\ndata: {}\n\nevent: error\ndata: {\"code\":40100,\"message\":\"terminal\"}\n\n"
    do {
      _ = try await assistantStream(status: 401, contentType: "text/event-stream", data: Data(wire.utf8))
      XCTFail("Every SSE event, including an unknown one, must close the HTTP refresh gate")
    } catch let failure as QFAPIError { XCTAssertEqual(failure.code, 40100) }
    XCTAssertEqual(route.snapshot().count, 1)
  }

  @MainActor
  func testAssistantSseDoneOnNon2xxCannotBecomeSuccessOrRefreshAuthority() async throws {
    let wire = "event: done\ndata: {\"answer\":\"untrusted success\"}\n\n"
    do {
      _ = try await assistantStream(status: 401, contentType: "text/event-stream", data: Data(wire.utf8))
      XCTFail("Non-2xx SSE cannot return success or authorize replay after an event")
    } catch let failure as QFAPIError { XCTAssertEqual(failure.code, 40100) }
    XCTAssertEqual(route.snapshot().count, 1)
  }

  @MainActor
  func testAssistantAdvertisedResumeKeepsOperationBodyAndCursorWithoutDuplicatingText() async throws {
    let initial = "id: 1\nevent: delta\ndata: {\"text\":\"你好\"}\n\nid: 2\nevent: delta\ndata: {\"text\":\""
    let recovered = "id: 1\nevent: delta\ndata: {\"text\":\"你好\"}\n\nid: 2\nevent: delta\ndata: {\"text\":\"！\"}\n\nid: 3\nevent: done\ndata: {\"answer\":\"你好！\"}\n\n"
    stub { request in
      let wire = request.value(forHTTPHeaderField: "X-QF-Stream-Resume") == "1" ? recovered : initial
      return .response(200, ["Content-Type":"text/event-stream","X-QF-Stream-Resume":"1"], Data(wire.utf8))
    }
    let transport = QFAPIClient.makeTransport(configuration: configuration, requestTimeout: 3, resourceTimeout: 5)
    defer { transport.session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: "https://\(host!)/api/v1/me/assistant/chat/stream")!)
    request.httpMethod = "POST"; request.httpBody = Data("fixture".utf8); request.setValue("fixed-job", forHTTPHeaderField: "Idempotency-Key")
    var text = ""
    let result = try await QFAssistantStreamRun(language: "en", onEvent: { if case .delta(let delta) = $0 { text += delta } }).start(transport: transport, request: request)
    XCTAssertEqual(result.answer, "你好！"); XCTAssertEqual(text, "你好！")
    let requests = route.snapshot(); XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Last-Event-ID"), "1")
    XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Idempotency-Key"), "fixed-job")
    XCTAssertEqual(requests.first?.httpBody, requests.last?.httpBody)
  }

  @MainActor
  func testAssistantLegacyServerEofCannotTriggerAnotherBillablePost() async throws {
    let wire = "event: delta\ndata: {\"text\":\"partial\"}\n\n"
    do {
      _ = try await assistantStream(status: 200, contentType: "text/event-stream", data: Data(wire.utf8))
      XCTFail("EOF without done must remain incomplete")
    } catch {}
    XCTAssertEqual(route.snapshot().count, 1)
  }

  @MainActor
  private func assistantStream(status: Int, contentType: String, data: Data) async throws -> QFAssistantStreamResult {
    stub { _ in .response(status, ["Content-Type": contentType], data) }
    let transport = QFAPIClient.makeTransport(configuration: configuration, requestTimeout: 3, resourceTimeout: 5)
    defer { transport.session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: "https://\(host!)/api/v1/me/assistant/chat/stream")!)
    request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
    return try await QFAssistantStreamRun(language: "en", onEvent: { _ in }).start(transport: transport, request: request)
  }

  @MainActor
  func testAssistantConnectivityWaitingDoesNotChangeStandardTransportOrSource() {
    configuration.waitsForConnectivity = false
    let ordinary = QFAPIClient.makeTransport(configuration: configuration)
    let assistant = QFAPIClient.makeTransport(configuration: configuration, requestTimeout: 45, resourceTimeout: 240, waitsForConnectivity: true)
    defer { ordinary.session.invalidateAndCancel(); assistant.session.invalidateAndCancel() }
    XCTAssertFalse(configuration.waitsForConnectivity)
    XCTAssertFalse(ordinary.session.configuration.waitsForConnectivity)
    XCTAssertTrue(assistant.session.configuration.waitsForConnectivity)
    XCTAssertEqual(assistant.session.configuration.timeoutIntervalForResource, 240)
  }

  private var headers: [String: String] {
    ["Content-Type": "application/json", "Request-Id": "fixture-request-id"]
  }

  private func envelope(_ data: Any, code: Int = 0, message: String = "fixture success") -> Data {
    try! JSONSerialization.data(withJSONObject: [
      "code": code, "message": message, "requestId": "fixture-request-id", "data": data,
    ])
  }
}
