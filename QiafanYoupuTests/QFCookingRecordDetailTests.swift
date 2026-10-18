import Foundation
import UIKit
import XCTest
@testable import QiafanYoupu

private enum QFDetailFixture {
  static let ingredient = "84000000-0000-0000-0000-000000000001"
  static let other = "84000000-0000-0000-0000-000000000002"
  static var record: QFCookingRecord {
    var value = QFCookingRecord(); value.id = "detail-record"; value.date = "2026-10-01"
    value.title = "汤"; value.inventoryMode = "ACTUAL_MATERIALS"; value.revision = 3
    value.materials = [.init(name: "番茄", amount: "100", unit: "g", ingredientId: ingredient)]
    return value
  }
  static let units = [
    QFMeasurementUnit(code: "g", dimension: "MASS", symbol: "g", name: "克", factorToBase: "1", decimalAllowed: true),
    QFMeasurementUnit(code: "kg", dimension: "MASS", symbol: "kg", name: "千克", factorToBase: "1000", decimalAllowed: true),
    QFMeasurementUnit(code: "ml", dimension: "VOLUME", symbol: "ml", name: "毫升", factorToBase: "1", decimalAllowed: true)
  ]
  static func cost(amount: String = "100", unit: String = "g", date: String = "2026-10-01", id: String = ingredient) -> QFCookingCost {
    .init(recordId: "detail-record", date: date, title: "汤", meal: "LUNCH", valuationRevision: 7,
      status: "COMPLETE", totals: [.init(currency: "CNY", total: "2.50"), .init(currency: "USD", total: "1.00")], pendingMaterialCount: 0,
      materials: [.init(ingredientId: id, name: "番茄", quantity: amount, unitCode: unit,
        totals: [.init(currency: "CNY", total: "2.50"), .init(currency: "USD", total: "1.00")], status: "COMPLETE", sources: [])])
  }
}

private final class QFDetailTransport: URLProtocol {
  private static let lock = NSLock()
  private static var requests: [URLRequest] = []
  static func reset() { lock.lock(); defer { lock.unlock() }; requests = [] }
  static var writes: Int { lock.lock(); defer { lock.unlock() }; return requests.filter { !["GET", nil].contains($0.httpMethod) && $0.url?.path.contains("cooking-records") == true }.count }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
    let path = request.url!.path, value: Any
    if path.hasSuffix("app/config") {
      value = ["appName": "Test", "serviceRegion": "cn", "loginMethods": ["quick": true, "apple": true], "agreements": ["userAgreement": "test", "privacyPolicy": "test"]]
    } else if path.hasSuffix("auth/quick/sessions") {
      let token = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
      value = ["session": ["accessToken": token, "refreshToken": token, "accessTokenExpiresIn": 3600, "refreshTokenExpiresIn": 86400],
        "user": ["userId": "detail-test-user", "systemAccount": "sys_detail_test", "accountNameBound": false,
          "passwordConfigured": false, "nickname": "测试", "countryCode": "CN", "appleBound": false]]
    } else if path.hasSuffix("measurement-units") {
      value = [["code": "g", "dimension": "MASS", "symbol": "g", "name": "克", "factorToBase": "1", "decimalAllowed": true]]
    } else if path.hasSuffix("/cost") {
      value = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(QFDetailFixture.cost()))
    } else if path.hasSuffix("catalog") {
      value = ["items": [["id": QFDetailFixture.other, "type": "INGREDIENT", "title": "胡萝卜", "subtitle": "", "materials": [], "steps": []]], "total": 1]
    } else { value = NSNull() }
    let data = try! JSONSerialization.data(withJSONObject: ["code": 0, "message": "test", "requestId": "test", "data": value])
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

final class QFCookingRecordDetailTests: XCTestCase {
  private var service = ""
  override func setUp() { super.setUp(); service = "com.talka.detail-tests." + UUID().uuidString; QFDetailTransport.reset() }
  override func tearDownWithError() throws {
    for key in ["current", "device-id", "credential-test"] { try QFKeychainStore(service: service).remove(key) }
    QFDetailTransport.reset(); try super.tearDownWithError()
  }
  func testAddReplaceRemoveStayLocalAndRequireNewAmount() throws {
    let record = QFDetailFixture.record
    var draft = QFCookingRecordEditDraft(record: record, language: "zh-Hans")
    XCTAssertTrue(draft.addMaterial(name: "胡萝卜", ingredientID: QFDetailFixture.other))
    XCTAssertEqual(draft.record.materials.count, 2); XCTAssertEqual(draft.record.materials[1].amount, "")
    XCTAssertTrue(draft.replaceMaterial(at: 0, expected: record.materials[0], name: "胡萝卜", ingredientID: QFDetailFixture.other))
    XCTAssertEqual(draft.record.materials[0].amount, ""); XCTAssertTrue(draft.hasChangedCostInputs)
    XCTAssertTrue(draft.removeMaterial(at: 1, expected: draft.record.materials[1]))
    XCTAssertNil(draft.pending); XCTAssertEqual(draft.baseline, record)
    let restored = try JSONDecoder().decode(QFCookingRecordEditDraft.self, from: JSONEncoder().encode(draft))
    XCTAssertEqual(restored.record, draft.record); XCTAssertEqual(restored.baseline.revision, 3)
  }
  func testFrozenRequestCannotAddReplaceOrRemoveAndReusesUUID() throws {
    var draft = QFCookingRecordEditDraft(record: QFDetailFixture.record, language: "zh-Hans")
    draft.record.materials[0].amount = "80"
    XCTAssertTrue(draft.prepare()); let body = try XCTUnwrap(draft.pending)
    let original = draft.record.materials[0]
    XCTAssertFalse(draft.addMaterial(name: "胡萝卜", ingredientID: QFDetailFixture.other))
    XCTAssertFalse(draft.replaceMaterial(at: 0, expected: original, name: "胡萝卜", ingredientID: QFDetailFixture.other))
    XCTAssertFalse(draft.removeMaterial(at: 0, expected: original))
    XCTAssertTrue(draft.prepare()); XCTAssertEqual(draft.pending?.requestId, body.requestId)
    XCTAssertEqual(draft.pending?.materials, body.materials)
    XCTAssertEqual(draft.pending?.date, body.date)
    XCTAssertEqual(draft.record.materials, [original]); XCTAssertEqual(body.expectedRevision, 3)
  }
  func testStalePickerCannotReplaceDifferentRowAndCapacityIsBounded() {
    var draft = QFCookingRecordEditDraft(record: QFDetailFixture.record, language: "zh-Hans")
    let original = draft.record.materials[0]
    draft.record.materials[0].amount = "90"
    XCTAssertFalse(draft.replaceMaterial(at: 0, expected: original, name: "胡萝卜", ingredientID: QFDetailFixture.other))
    XCTAssertFalse(draft.removeMaterial(at: 0, expected: original))
    draft.record.materials = Array(repeating: original, count: 40)
    XCTAssertFalse(draft.addMaterial(name: "胡萝卜", ingredientID: QFDetailFixture.other))
  }
  func testDateEditInvalidatesCostsButMealOnlyEditDoesNot() {
    var draft = QFCookingRecordEditDraft(record: QFDetailFixture.record, language: "zh-Hans")
    draft.record.meal = "DINNER"; XCTAssertFalse(draft.hasChangedCostInputs)
    draft.record.date = "2026-09-30"; XCTAssertTrue(draft.hasChangedCostInputs)
  }
  func testCostMatchAggregatesDuplicateIngredientsAndExactMassConversion() {
    var record = QFDetailFixture.record
    record.materials[0].amount = "0.04"; record.materials[0].unit = "kg"
    record.materials.append(.init(name: "番茄", amount: "60", unit: "g", ingredientId: QFDetailFixture.ingredient))
    XCTAssertTrue(QFCookingRecordCostMatch.matches(QFDetailFixture.cost(), record: record, units: QFDetailFixture.units))
    XCTAssertEqual(QFDetailFixture.cost().totals.map(\.currency), ["CNY", "USD"])
  }
  func testCostMatchRejectsStaleAmountDateAndWrongIngredient() {
    let record = QFDetailFixture.record
    XCTAssertFalse(QFCookingRecordCostMatch.matches(QFDetailFixture.cost(amount: "90"), record: record, units: QFDetailFixture.units))
    XCTAssertFalse(QFCookingRecordCostMatch.matches(QFDetailFixture.cost(date: "2026-09-30"), record: record, units: QFDetailFixture.units))
    XCTAssertFalse(QFCookingRecordCostMatch.matches(QFDetailFixture.cost(id: QFDetailFixture.other), record: record, units: QFDetailFixture.units))
  }
  func testCostMatchDoesNotInventDensityOrPackageConversion() {
    let record = QFDetailFixture.record
    XCTAssertFalse(QFCookingRecordCostMatch.matches(QFDetailFixture.cost(unit: "ml"), record: record, units: QFDetailFixture.units))
    XCTAssertFalse(QFCookingRecordCostMatch.matches(QFDetailFixture.cost(amount: "1", unit: "bag"), record: record, units: QFDetailFixture.units))
  }

  @MainActor private func app() async throws -> QFAppSession {
    let identity = QFDeviceIdentity(service: service), config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [QFDetailTransport.self]
    let api = QFAPIClient(environment: QFAPIEnvironment(name: "detail-test", baseURL: URL(string: "https://detail.invalid/api/v1")), identity: identity, transportConfiguration: config)
    api.recordsRequests = false
    let app = QFAppSession(api: api, identity: identity, keychain: QFKeychainStore(service: service))
    await app.start(); try await app.login(agreementAccepted: true)
    QFContentDraftStore.remove(app: app, kind: "cooking-edit.detail-record")
    return app
  }
  @MainActor private func views<T: UIView>(_ type: T.Type, _ root: UIView) -> [T] { ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, $0) } }
  @MainActor private func button(_ id: String, in root: UIView) throws -> UIButton { try XCTUnwrap(views(UIButton.self, root).first { $0.accessibilityIdentifier == id }) }
  @MainActor private func eventually(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    XCTAssertTrue(condition())
  }
  @MainActor private func host(_ controller: UIViewController) -> UIWindow {
    let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = controller; window.makeKeyAndVisible(); controller.loadViewIfNeeded(); window.layoutIfNeeded(); return window
  }
  @MainActor func testDetailLoadsKnownCostsThenHidesThemWhenAmountChanges() async throws {
    let app = try await app(), page = QFCookingRecordDetailViewController(app: app, record: QFDetailFixture.record)
    let window = host(page)
    defer { page.close(); window.isHidden = true; window.rootViewController = nil; QFContentDraftStore.remove(app: app, kind: "cooking-edit.detail-record") }
    try await eventually { self.views(UILabel.self, page.view).first { $0.accessibilityIdentifier == "cooking.detail.cost" }?.text?.contains("2.50") == true }
    let labels = views(UILabel.self, page.view)
    XCTAssertTrue(labels.first { $0.accessibilityIdentifier == "cooking.detail.material-cost.0" }?.text?.contains("2.50") == true)
    try button("cooking.detail.edit", in: page.view).sendActions(for: .touchUpInside)
    let field = try XCTUnwrap(views(UITextField.self, page.view).first { $0.accessibilityIdentifier == "cooking.detail.amount.0" })
    field.text = "75"; field.sendActions(for: .editingChanged)
    XCTAssertEqual(views(UILabel.self, page.view).first { $0.accessibilityIdentifier == "cooking.detail.cost" }?.text, app.text("保存后更新成本", "Cost updates after saving"))
    XCTAssertEqual(QFContentDraftStore.load(QFCookingRecordEditDraft.self, app: app, kind: "cooking-edit.detail-record")?.record.materials[0].amount, "75")
    XCTAssertEqual(QFDetailTransport.writes, 0)
  }
  @MainActor func testCatalogAdditionPersistsDraftWithoutWritingServer() async throws {
    let app = try await app(), page = QFCookingRecordDetailViewController(app: app, record: QFDetailFixture.record)
    let navigation = QFNavigationController(rootViewController: page), window = host(navigation)
    defer { page.close(); window.isHidden = true; window.rootViewController = nil; QFContentDraftStore.remove(app: app, kind: "cooking-edit.detail-record") }
    try await eventually { self.views(UIButton.self, page.view).first { $0.accessibilityIdentifier == "cooking.detail.edit" }?.isEnabled == true }
    try button("cooking.detail.edit", in: page.view).sendActions(for: .touchUpInside)
    try button("cooking.detail.add-material", in: page.view).sendActions(for: .touchUpInside)
    try await eventually { navigation.topViewController is QFCatalogSearchViewController }
    let picker = try XCTUnwrap(navigation.topViewController as? QFCatalogSearchViewController)
    let table = try XCTUnwrap(views(UITableView.self, picker.view).first)
    try await eventually { table.numberOfSections > 0 && table.numberOfRows(inSection: 0) == 1 && navigation.transitionCoordinator == nil }
    table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: 0, section: 0))
    try await eventually { navigation.topViewController === page && QFContentDraftStore.load(QFCookingRecordEditDraft.self, app: app, kind: "cooking-edit.detail-record")?.record.materials.count == 2 }
    let draft = try XCTUnwrap(QFContentDraftStore.load(QFCookingRecordEditDraft.self, app: app, kind: "cooking-edit.detail-record"))
    XCTAssertEqual(draft.record.materials.count, 2); XCTAssertEqual(draft.record.materials[1].ingredientId, QFDetailFixture.other)
    XCTAssertEqual(draft.record.materials[1].amount, ""); XCTAssertNil(draft.pending); XCTAssertEqual(QFDetailTransport.writes, 0)
  }
}
