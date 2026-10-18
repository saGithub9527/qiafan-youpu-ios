import Foundation
import UIKit
import XCTest

@testable import QiafanYoupu

private final class QFCookingDraftURLProtocol: URLProtocol {
  static var observedPath: ((String) -> Void)?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let path = request.url?.path ?? ""
    Self.observedPath?(path)
    let value: Any
    if path.hasSuffix("app/config") {
      value = [
        "appName": "Test", "serviceRegion": "cn", "loginMethods": ["quick": true, "apple": true],
        "agreements": ["userAgreement": "test terms", "privacyPolicy": "test privacy"],
      ]
    } else if path.hasSuffix("auth/quick/sessions") {
      value = ["session": Self.tokens, "user": Self.profile]
    } else if path.hasSuffix("me/cooking-records") {
      value = ["items": [], "total": 0]
    } else if path.hasSuffix("me/content-summary") {
      value = ["favorites": 0, "cookingDays": 0, "publishedWorks": 0, "contributions": 0,
        "avatarMediaId": NSNull()]
    } else {
      value = NSNull()
    }
    let data = try! JSONSerialization.data(withJSONObject: [
      "code": 0, "message": "test", "requestId": "test", "data": value,
    ])
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}

  private static var tokens: [String: Any] {
    [
      "accessToken": token(1), "refreshToken": token(2),
      "accessTokenExpiresIn": 3600, "refreshTokenExpiresIn": 86400,
    ]
  }
  private static var profile: [String: Any] {
    [
      "userId": "cooking-test-user", "systemAccount": "sys_cooking_test",
      "boundAccount": NSNull(), "accountNameBound": false, "passwordConfigured": false,
      "nickname": "测试用户", "avatarUrl": NSNull(), "countryCode": "CN",
      "regionCode": NSNull(), "bio": NSNull(), "appleBound": false,
    ]
  }
  private static func token(_ byte: UInt8) -> String {
    Data(repeating: byte, count: 32).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

final class QFCookingDraftTests: XCTestCase {
  private var service: String!

  override func setUp() {
    super.setUp()
    service = "com.talka.qiafanyoupu.cooking-tests." + UUID().uuidString.lowercased()
  }

  override func tearDownWithError() throws {
    QFCookingDraftURLProtocol.observedPath = nil
    let keychain = QFKeychainStore(service: service)
    for key in ["current", "device-id", "credential-test"] { try keychain.remove(key) }
    try super.tearDownWithError()
  }

  @MainActor
  private func makeSession() async throws -> QFAppSession {
    let identity = QFDeviceIdentity(service: service)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QFCookingDraftURLProtocol.self]
    let api = QFAPIClient(
      environment: QFAPIEnvironment(
        name: "test", baseURL: URL(string: "https://cooking-drafts.invalid/api/v1")),
      identity: identity, transportConfiguration: configuration)
    #if DEBUG
      api.recordsRequests = false
    #endif
    let app = QFAppSession(
      api: api, identity: identity, keychain: QFKeychainStore(service: service))
    await app.start()
    try await app.login(agreementAccepted: true)
    return app
  }

  @MainActor
  private func allSubviews<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
    var result = root as? T == nil ? [] : [root as! T]
    for child in root.subviews { result.append(contentsOf: allSubviews(of: type, in: child)) }
    return result
  }

  @MainActor
  func testListModeRequiresVisibleDateSelectionBeforeBackfill() async throws {
    let summaryLoaded = expectation(description: "Cooking history rendered")
    QFCookingDraftURLProtocol.observedPath = { path in
      if path.hasSuffix("me/content-summary") { summaryLoaded.fulfill() }
    }
    let app = try await makeSession()
    let history = QFCookingHistoryViewController(app: app)
    let navigation = QFNavigationController(rootViewController: history)
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = navigation
    window.makeKeyAndVisible()
    history.loadViewIfNeeded()
    await fulfillment(of: [summaryLoaded], timeout: 2)
    for _ in 0..<20 { await Task.yield() }

    let mode = try XCTUnwrap(
      allSubviews(of: UISegmentedControl.self, in: history.view).first {
        $0.numberOfSegments == 2 && $0.titleForSegment(at: 0) == "月历"
      })
    let backfill = try XCTUnwrap(
      allSubviews(of: UIButton.self, in: history.view).first { $0.currentTitle == "补记做菜" })
    mode.selectedSegmentIndex = 1
    mode.sendActions(for: .valueChanged)
    backfill.sendActions(for: .touchUpInside)

    XCTAssertTrue(navigation.topViewController === history)
    let visibleMode = try XCTUnwrap(
      allSubviews(of: UISegmentedControl.self, in: history.view).first {
        $0.numberOfSegments == 2 && $0.titleForSegment(at: 0) == "月历"
      })
    XCTAssertEqual(visibleMode.selectedSegmentIndex, 0)
  }

  @MainActor
  func testConflictingIdentifierRemainsInSourceDraft() async throws {
    let app = try await makeSession()
    let sourceDate = "2026-09-10"
    let targetDate = "2026-09-11"
    var source = QFCookingRecord()
    source.id = UUID().uuidString.lowercased()
    source.date = targetDate
    source.title = "来源草稿"
    var target = source
    target.title = "目标草稿"
    defer {
      QFContentDraftStore.remove(app: app, kind: "cooking-batch-" + sourceDate)
      QFContentDraftStore.remove(app: app, kind: "cooking-batch-" + targetDate)
    }
    QFContentDraftStore.save([source], app: app, kind: "cooking-batch-" + sourceDate)
    QFContentDraftStore.save([target], app: app, kind: "cooking-batch-" + targetDate)

    _ = QFBatchCookingEditorViewController(app: app, date: sourceDate)

    XCTAssertEqual(
      QFContentDraftStore.load(
        [QFCookingRecord].self, app: app, kind: "cooking-batch-" + sourceDate),
      [source])
    XCTAssertEqual(
      QFContentDraftStore.load(
        [QFCookingRecord].self, app: app, kind: "cooking-batch-" + targetDate),
      [target])
  }

  @MainActor
  func testDraftStoreReportsSuccessfulWrite() async throws {
    let app = try await makeSession()
    defer { QFContentDraftStore.remove(app: app, kind: "reported-write") }
    let result = QFContentDraftStore.save("saved", app: app, kind: "reported-write")
    XCTAssertTrue(result)
    XCTAssertEqual(QFContentDraftStore.load(String.self, app: app, kind: "reported-write"), "saved")
  }

  @MainActor
  func testDraftStoreReportsOversizeFailureWithoutReplacingExistingDraft() async throws {
    let app = try await makeSession()
    defer { QFContentDraftStore.remove(app: app, kind: "oversize-write") }
    QFContentDraftStore.save("existing", app: app, kind: "oversize-write")
    let oversized = String(repeating: "a", count: 2 * 1024 * 1024 + 1)

    let result = QFContentDraftStore.save(oversized, app: app, kind: "oversize-write")

    XCTAssertFalse(result)
    XCTAssertEqual(QFContentDraftStore.load(String.self, app: app, kind: "oversize-write"), "existing")
  }
}
