import UIKit
import DGCharts
import CoreImage
import XCTest
import MJRefresh
@testable import QiafanYoupu

private final class QFPurchaseTransport: URLProtocol {
  static let lock = NSLock()
  static var requests: [URLRequest] = []
  static var loseNextResponse = false
  static var negativeTrend = false
  static var receipt: [String: Any] = [:]
  static let receiptID = "94000000-0000-0000-0000-000000000001"
  static let ingredientID = "82000000-0000-0000-0000-000000000001"
  static let lineID = "95000000-0000-0000-0000-000000000001"
  static func reset() { lock.lock(); defer { lock.unlock() }; requests = []; loseNextResponse = false; negativeTrend = false; receipt = fixture() }
  static func fixture() -> [String: Any] {
    ["id": receiptID, "revision": 0, "householdId": NSNull(), "date": "2026-10-06", "time": NSNull(), "timeZone": "Asia/Shanghai", "merchant": "生鲜店", "currency": "CNY", "discount": "0", "knownSubtotal": "6.00", "paidAmount": "6.00", "pendingPriceCount": 0, "status": "POSTED", "source": "MANUAL", "refundTotal": "0", "netPaidAmount": "6.00", "adjustments": [], "items": [["id": lineID, "ingredientId": ingredientID, "name": "番茄", "quantity": "500", "unitCode": "g", "lineAmount": "6.00", "expiresOn": NSNull(), "location": "冷藏", "packageUnit": NSNull(), "packageSize": NSNull(), "packageContentUnit": NSNull(), "lotId": "96000000-0000-0000-0000-000000000001", "netAmount": "6.00"]]]
  }
  static func costFixture() -> [String: Any] {
    ["recordId": "97000000-0000-0000-0000-000000000001", "date": "2026-10-06", "title": "番茄炒蛋", "meal": "LUNCH", "valuationRevision": 2, "status": "PENDING", "totals": [["currency": "CNY", "total": "2.40"]], "pendingMaterialCount": 1, "materials": [["ingredientId": ingredientID, "name": "番茄", "quantity": "200", "unitCode": "g", "totals": [], "status": "PENDING", "sources": [["lotId": "96000000-0000-0000-0000-000000000001", "sourceId": "98000000-0000-0000-0000-000000000001", "originalQuantity": "500", "unitCode": "g", "date": NSNull(), "currency": NSNull(), "totalCost": NSNull(), "revision": 2]]]]]
  }
  static func body(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }; stream.open(); defer { stream.close() }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }; return data
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  static func shoppingFixture() -> [String: Any] {
    let item: [String: Any] = ["id":lineID,"ingredientId":ingredientID,"name":"番茄","quantityKind":"EXACT","quantityMin":"500","quantityMax":"500","unitCode":"g","requiresConfirmation":false,"checked":true,"revision":2,"received":false]
    return ["id":"55000000-0000-0000-0000-000000000001","startDate":"2026-10-06","endDate":"2026-10-06","status":"DRAFT","subtractInventory":true,"language":"zh-Hans","revision":3,"items":[item],"warnings":[],"createdAt":"2026-10-06T00:00:00Z","updatedAt":"2026-10-06T00:00:00Z"]
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let bytes = Self.body(request); var capture = request; capture.httpBody = bytes
    Self.lock.lock(); Self.requests.append(capture)
    let lose = Self.loseNextResponse && request.httpMethod == "PUT"
    if lose { Self.loseNextResponse = false }; Self.lock.unlock()
    if lose { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
    let path = request.url!.path; let value: Any
    if path.hasSuffix("app/config") {
      value = ["appName": "Test", "serviceRegion": "cn", "loginMethods": ["quick": true, "apple": true], "agreements": ["userAgreement": "test", "privacyPolicy": "test"]]
    } else if path.hasSuffix("auth/quick/sessions") {
      let token = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
      value = ["session": ["accessToken": token, "refreshToken": token, "accessTokenExpiresIn": 3600, "refreshTokenExpiresIn": 86400], "user": ["userId": "purchase-test-user", "systemAccount": "sys_purchase_test", "boundAccount": NSNull(), "accountNameBound": false, "passwordConfigured": false, "nickname": "测试用户", "avatarUrl": NSNull(), "countryCode": "CN", "regionCode": NSNull(), "bio": NSNull(), "appleBound": false]]
    } else if path.hasSuffix("cooking-statistics") {
      let q=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems ?? []
      let page=Int(q.first{$0.name=="page"}?.value ?? "0") ?? 0
      let titles = ["zh-Hans":"同名菜谱", "zh-Hant":"同名菜譜", "en":"Roasted seasonal vegetables", "ja":"季節の野菜のロースト", "ko":"제철 채소 구이", "ru":"Запечённые сезонные овощи", "es":"Verduras de temporada asadas", "fr":"Légumes de saison rôtis", "de":"Geröstetes saisonales Gemüse", "pt-BR":"Legumes da estação assados"]
      let localizedTitle = titles[request.value(forHTTPHeaderField:"Accept-Language") ?? "zh-Hans"] ?? "Recipe"
      let rows=(page*20..<min(page*20+20,25)).map { index -> [String:Any] in
        ["recipeId":String(format:"56000000-0000-0000-0000-%012d",index),"title":localizedTitle,"contentAvailable":true,"count":25-index,"lastCookedOn":"2026-10-06","totals":[["currency":"CNY","total":"10"]],"pendingCostCount":index==0 ? 1:0]
      }
      value=["startDate":"2026-10-01","endDate":"2026-10-31","summary":["cookingDays":21,"completedCount":300,"recipeCount":25],"items":rows,"total":25]
    } else if path.hasSuffix("cooking-records") { value=["items":[],"total":0]
    } else if path.hasSuffix("me/inventory") { value=["items":[],"total":0]
    } else if path.hasSuffix("shopping-lists") { value=["items":[Self.shoppingFixture()],"total":1]
    } else if path.contains("shopping-lists/") { value=Self.shoppingFixture()
    } else if path.hasSuffix("measurement-units") {
      value = [["code": "g", "dimension": "MASS", "symbol": "g", "name": "克", "factorToBase": "1", "decimalAllowed": true]]
    } else if path.contains("inventory/lots/") {
      let input = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
      value = ["id": request.url!.lastPathComponent, "ingredientId": Self.ingredientID, "ingredientName": "番茄", "contentAvailable": true, "unitCode": input["unitCode"] ?? "g", "initialQuantity": input["quantity"] ?? "500", "currentQuantity": input["quantity"] ?? "500", "location": input["location"] ?? "", "status": "ACTIVE", "revision": 0]
    } else if path.contains("purchase-receipts/") {
      if request.httpMethod == "PUT", let input = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
        for key in ["date", "merchant", "discount", "currency", "items"] { Self.receipt[key] = input[key] }
        Self.receipt["revision"] = (input["expectedRevision"] as? Int ?? -1) + 1
      }
      value = Self.receipt
    } else if path.hasSuffix("purchase-receipts") {
      value = ["items": [Self.receipt], "total": 1, "totals": [["currency": "CNY", "total": "6.00"]], "pendingPriceCount": 0]
    } else if path.hasSuffix("cooking-costs") {
      value = ["items": [Self.costFixture()], "total": 1, "totals": [["currency": "CNY", "total": "2.40"]], "pendingMaterialCount": 1]
    } else if path.hasSuffix("preparation-expenses") {
      value = ["startDate": "2026-10-05", "endDate": "2026-10-11", "purchaseTotals": [["currency": "CNY", "total": "6.00"], ["currency": "USD", "total": "3.00"]], "consumptionTotals": [], "purchaseCount": 1, "cookingCount": 0, "pendingPurchaseCount": 0, "pendingMaterialCount": 0, "trend": [["date": "2026-10-06", "totals": [["currency": "CNY", "total": Self.negativeTrend ? "-6.00" : "6.00"], ["currency": "USD", "total": "3.00"]]]]]
    } else { value = NSNull() }
    let data = try! JSONSerialization.data(withJSONObject: ["code": 0, "message": "test", "requestId": "test", "data": value])
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
final class QFPurchaseCostTests: XCTestCase {
  private var service = ""
  override func setUp() { super.setUp(); service = "com.talka.purchase-tests." + UUID().uuidString; QFPurchaseTransport.reset() }
  override func tearDownWithError() throws {
    for key in ["current", "device-id", "credential-test"] { try QFKeychainStore(service: service).remove(key) }
    QFPurchaseTransport.reset(); try super.tearDownWithError()
  }
  func testLocalScanHintsSurviveDraftRecoveryWithoutEnteringAPIRequest() throws {
    var draft = sampleDraft()
    draft.scanSellerID = "01234567"; draft.scanTotal = "340"
    let recovered = try JSONDecoder().decode(QFPurchaseReceiptDraft.self, from: JSONEncoder().encode(draft))
    XCTAssertEqual(recovered.scanSellerID, "01234567")
    XCTAssertEqual(recovered.scanTotal, "340")
    let request = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recovered.request())) as? [String: Any]
    XCTAssertNil(request?["scanSellerID"]); XCTAssertNil(request?["scanTotal"])
    var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
    old.removeValue(forKey: "scanSellerID"); old.removeValue(forKey: "scanTotal")
    let legacy = try JSONDecoder().decode(QFPurchaseReceiptDraft.self, from: JSONSerialization.data(withJSONObject: old))
    XCTAssertNil(legacy.scanSellerID); XCTAssertNil(legacy.scanTotal)
  }
  func testUnknownCostStaysNilAndCannotReceiveDiscount() throws {
    var draft = sampleDraft(); draft.items[0].lineAmount = nil
    XCTAssertNil(draft.paidAmount); XCTAssertEqual(draft.pendingCount, 1)
    XCTAssertNoThrow(try draft.request()); draft.discount = "1"; XCTAssertThrowsError(try draft.request())
  }
  func testExplicitZeroCostIsKnownRatherThanMissing() throws {
    var draft = sampleDraft(); draft.items[0].lineAmount = "0"
    XCTAssertEqual(draft.paidAmount, 0); XCTAssertEqual(draft.pendingCount, 0); XCTAssertNoThrow(try draft.request())
  }
  func testInvalidNumbersCurrencyAndDuplicateRowsRejected() throws {
    var draft = sampleDraft(); draft.items[0].quantity = "1e6"; XCTAssertThrowsError(try draft.request())
    draft = sampleDraft(); draft.currency = "ABC"; XCTAssertThrowsError(try draft.request())
    draft = sampleDraft(); draft.items.append(draft.items[0]); XCTAssertThrowsError(try draft.request())
    draft = sampleDraft(); draft.items[0].ingredientId = nil; XCTAssertThrowsError(try draft.request())
  }
  func testLocaleDecimalInputAndExactSubtotal() {
    XCTAssertEqual(QFPurchaseNumber.normalize(" 1,25 ", locale: Locale(identifier: "fr_FR")), "1.25")
    XCTAssertNil(QFPurchaseNumber.decimal("1,250"))
    var draft = sampleDraft(); draft.items[0].lineAmount = "0.1"; var second = draft.items[0]; second.id = UUID().uuidString; second.lineAmount = "0.2"; draft.items.append(second)
    XCTAssertEqual(draft.knownSubtotal, Decimal(string: "0.3"))
  }
  func testFrozenRequestPersistsExactBodyAndRevision() throws {
    var draft = sampleDraft(); draft.revision = 7; let body = try draft.request(); draft.pending = .init(body: body, language: "fr")
    let recovered = try JSONDecoder().decode(QFPurchaseReceiptDraft.self, from: JSONEncoder().encode(draft))
    XCTAssertEqual(recovered.pending?.body, body); XCTAssertEqual(recovered.pending?.body.expectedRevision, 7); XCTAssertEqual(recovered.pending?.language, "fr")
  }
  func testLegacyNullableIngredientIsReadable() throws {
    var legacy = QFPurchaseTransport.fixture(); legacy["source"] = "LEGACY"
    var items = legacy["items"] as! [[String: Any]]; items[0]["ingredientId"] = NSNull(); items[0]["lotId"] = NSNull(); legacy["items"] = items
    let value = try JSONDecoder().decode(QFPurchaseReceipt.self, from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertNil(value.items[0].ingredientId); XCTAssertNil(value.items[0].lotId)
  }
  func testEditingReceiptNeverEncodesServerAllocatedStockFields() throws {
    let receipt = try JSONDecoder().decode(QFPurchaseReceipt.self, from: JSONSerialization.data(withJSONObject: QFPurchaseTransport.fixture()))
    let request = try QFPurchaseReceiptDraft(receipt).request(), data = try JSONEncoder().encode(request)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let line = try XCTUnwrap((object["items"] as? [[String: Any]])?.first)
    XCTAssertNil(line["lotId"]); XCTAssertNil(line["netAmount"])
    XCTAssertEqual(try JSONDecoder().decode(QFPurchaseReceiptRequest.self, from: data), request)
  }
  func testProductPhotoDoesNotTreatReceiptQRAsProductBarcode() throws {
    let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
    filter.setValue(Data("https://merchant.example.invalid/receipt?id=123".utf8), forKey: "inputMessage")
    let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let cg = try XCTUnwrap(CIContext().createCGImage(output, from: output.extent))
    XCTAssertTrue(try QFProductBarcodeImageDecoder.barcodes(in: UIImage(cgImage: cg)).isEmpty)
    XCTAssertTrue(QFPurchaseTransport.requests.isEmpty)
  }
  private func sampleDraft() -> QFPurchaseReceiptDraft {
    var draft = QFPurchaseReceiptDraft(date: "2026-10-06", householdId: nil); draft.id = QFPurchaseTransport.receiptID
    draft.items = [.init(id: QFPurchaseTransport.lineID, ingredientId: QFPurchaseTransport.ingredientID, name: "番茄", quantity: "500", lineAmount: "6.00")]; return draft
  }
  @MainActor private func session() async throws -> QFAppSession {
    let identity = QFDeviceIdentity(service: service), config = URLSessionConfiguration.ephemeral; config.protocolClasses = [QFPurchaseTransport.self]
    let api = QFAPIClient(environment: QFAPIEnvironment(name: "purchase-test", baseURL: URL(string: "https://purchase.invalid/api/v1")), identity: identity, transportConfiguration: config); api.recordsRequests = false
    let app = QFAppSession(api: api, identity: identity, keychain: QFKeychainStore(service: service))
    await app.start(); try await app.login(agreementAccepted: true)
    QFContentDraftStore.remove(app: app, kind: "receipt.personal.new"); QFContentDraftStore.remove(app: app, kind: "receipt." + QFPurchaseTransport.receiptID)
    return app
  }
  @MainActor private func descendants<T: UIView>(_ type: T.Type, _ root: UIView) -> [T] { ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants(type, $0) } }
  @MainActor private func button(_ id: String, _ root: UIView) throws -> UIButton { try XCTUnwrap(descendants(UIButton.self, root).first { $0.accessibilityIdentifier == id }) }
  @MainActor private func eventually(_ condition: () -> Bool) async throws { let limit = Date().addingTimeInterval(4); while !condition() && Date() < limit { try await Task.sleep(nanoseconds: 20_000_000) }; XCTAssertTrue(condition()); if !condition() { throw NSError(domain: "PurchaseTestTimeout", code: 1) } }
  @MainActor private func show(_ controller: UIViewController) -> UIWindow {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = QFNavigationController(rootViewController: controller); window.makeKeyAndVisible(); controller.loadViewIfNeeded(); window.layoutIfNeeded(); return window
  }
  @MainActor func testEditingOnlyPersistsLocalDraftUntilSave() async throws {
    let app = try await session(); let draft = sampleDraft(); XCTAssertTrue(QFContentDraftStore.save(draft, app: app, kind: "receipt.personal.new"))
    let editor = QFPurchaseReceiptViewController(app: app); let window = show(editor); defer { window.isHidden = true; QFContentDraftStore.remove(app: app, kind: "receipt.personal.new") }
    let merchant = try XCTUnwrap(descendants(UITextField.self, editor.view).first { $0.accessibilityIdentifier == "purchase.merchant" }); merchant.text = "Updated shop"; merchant.sendActions(for: .editingChanged)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertFalse(QFPurchaseTransport.requests.contains { $0.httpMethod == "PUT" })
    let local = try XCTUnwrap(QFContentDraftStore.load(QFPurchaseReceiptDraft.self, app: app, kind: "receipt.personal.new")); XCTAssertEqual(local.merchant, "Updated shop")
    try button("purchase.receipt.save", editor.view).sendActions(for: .touchUpInside)
    try await eventually { QFPurchaseTransport.requests.filter { $0.httpMethod == "PUT" }.count == 1 }
    try await eventually { QFContentDraftStore.load(QFPurchaseReceiptDraft.self, app: app, kind: "receipt.personal.new") == nil }
  }
  @MainActor func testScannedItemsOpenLocalReviewDraftAndDoNotStockWithoutIngredientMapping() async throws {
    let app = try await session()
    let barcode = try XCTUnwrap(QFProductBarcode(value: "3017620422003", symbology: "EAN13"))
    let imported = QFReceiptImport(date: nil, currency: "CNY", sellerID: nil, invoiceTotal: nil,
      lines: [.scannedProduct(barcode: barcode, name: "番茄")])
    let editor = QFPurchaseReceiptViewController(app: app, imported: imported)
    let window = show(editor)
    defer { window.isHidden = true; QFContentDraftStore.remove(app: app, kind: "receipt.personal.new") }
    let local = try XCTUnwrap(QFContentDraftStore.load(QFPurchaseReceiptDraft.self, app: app, kind: "receipt.personal.new"))
    XCTAssertEqual(local.items.first?.name, "番茄")
    XCTAssertNil(local.items.first?.lineAmount)
    XCTAssertNil(local.items.first?.ingredientId)
    XCTAssertFalse(QFPurchaseTransport.requests.contains { $0.httpMethod == "PUT" })
    try button("purchase.receipt.save", editor.view).sendActions(for: .touchUpInside)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertFalse(QFPurchaseTransport.requests.contains { $0.httpMethod == "PUT" })
  }
  @MainActor func testNetworkRetryUsesSameRequestAndDisablesEditing() async throws {
    let app = try await session(); XCTAssertTrue(QFContentDraftStore.save(sampleDraft(), app: app, kind: "receipt.personal.new"))
    let editor = QFPurchaseReceiptViewController(app: app); let window = show(editor); defer { window.isHidden = true; QFContentDraftStore.remove(app: app, kind: "receipt.personal.new") }
    QFPurchaseTransport.loseNextResponse = true
    try button("purchase.receipt.save", editor.view).sendActions(for: .touchUpInside)
    try await eventually { QFPurchaseTransport.requests.filter { $0.httpMethod == "PUT" }.count == 1 }
    try await eventually { (try? self.button("purchase.receipt.save", editor.view).isEnabled) == true }
    let pending = try XCTUnwrap(QFContentDraftStore.load(QFPurchaseReceiptDraft.self, app: app, kind: "receipt.personal.new")?.pending)
    try button("purchase.receipt.save", editor.view).sendActions(for: .touchUpInside)
    try await eventually { QFPurchaseTransport.requests.filter { $0.httpMethod == "PUT" }.count == 2 }
    let writes = QFPurchaseTransport.requests.filter { $0.httpMethod == "PUT" }
    let first = try JSONDecoder().decode(QFPurchaseReceiptRequest.self, from: QFPurchaseTransport.body(writes[0])); let retry = try JSONDecoder().decode(QFPurchaseReceiptRequest.self, from: QFPurchaseTransport.body(writes[1]))
    XCTAssertEqual(first, retry); XCTAssertEqual(retry.requestId, pending.body.requestId)
  }
  @MainActor func testReceiptReadDoesNotMutateAndEditStaysInPlace() async throws {
    let app = try await session(); let receipt = try JSONDecoder().decode(QFPurchaseReceipt.self, from: JSONSerialization.data(withJSONObject: QFPurchaseTransport.fixture()))
    let controller = QFPurchaseReceiptViewController(app: app, receipt: receipt); let window = show(controller); defer { window.isHidden = true }
    try button("purchase.receipt.edit", controller.view).sendActions(for: .touchUpInside)
    XCTAssertEqual(controller.navigationController?.viewControllers.count, 1)
    XCTAssertNotNil(descendants(UITextField.self, controller.view).first { $0.accessibilityIdentifier == "purchase.merchant" })
    try button("purchase.receipt.edit", controller.view).sendActions(for: .touchUpInside)
    XCTAssertTrue(descendants(UITextField.self, controller.view).isEmpty)
    XCTAssertFalse(QFPurchaseTransport.requests.contains { $0.httpMethod == "PUT" })
  }
  @MainActor func testExpensesShowSeparateCurrenciesAndChart() async throws {
    let app = try await session(); let controller = QFPreparationExpensesViewController(app: app); let window = show(controller); defer { window.isHidden = true }
    try await eventually { self.descendants(UIView.self, controller.view).contains { $0.accessibilityIdentifier == "plan.expenses.chart" } }
    let texts = descendants(UILabel.self, controller.view).compactMap(\.text).joined(separator: " ")
    XCTAssertTrue(texts.contains("6.00")); XCTAssertTrue(texts.contains("3.00")); XCTAssertFalse(texts.contains("9.00"))
  }
  @MainActor func testRefundDraftOnlyPostsOnSaveAndCarriesRevision() async throws {
    let app = try await session(), key = "receipt-adjustment." + QFPurchaseTransport.receiptID
    QFContentDraftStore.remove(app: app, kind: key)
    let receipt = try JSONDecoder().decode(QFPurchaseReceipt.self, from: JSONSerialization.data(withJSONObject: QFPurchaseTransport.fixture()))
    var result: QFPurchaseReceipt?
    let controller = QFPurchaseAdjustmentViewController(app: app, receipt: receipt) { result = $0 }
    let window = show(controller); defer { window.isHidden = true; QFContentDraftStore.remove(app: app, kind: key) }
    let field = try XCTUnwrap(descendants(UITextField.self, controller.view).first { $0.accessibilityIdentifier == "purchase.refund." + QFPurchaseTransport.lineID })
    field.text = "1.00"; field.sendActions(for: .editingChanged)
    XCTAssertFalse(QFPurchaseTransport.requests.contains { $0.url?.path.hasSuffix("/adjustments") == true })
    try button("purchase.adjustment.save", controller.view).sendActions(for: .touchUpInside)
    try await eventually { result != nil }
    let write = try XCTUnwrap(QFPurchaseTransport.requests.first { $0.url?.path.hasSuffix("/adjustments") == true })
    let input = try JSONDecoder().decode(QFPurchaseAdjustmentRequest.self, from: QFPurchaseTransport.body(write))
    XCTAssertEqual(input.expectedRevision, receipt.revision); XCTAssertEqual(input.type, "REFUND")
    XCTAssertEqual(input.items[0].refundAmount, "1.00"); XCTAssertNil(input.items[0].quantity)
  }
  @MainActor func testManualInventoryWithCostRequiresConfirmedAcquisitionDate() async throws {
    let app = try await session(), key = "inventory-receive.personal." + QFPurchaseTransport.ingredientID
    var draft = QFInventoryReceiveDraft(); draft.quantity = "500"; draft.totalCost = "6"
    XCTAssertTrue(QFContentDraftStore.save(draft, app: app, kind: key))
    let ingredient = QFCatalogItem(id: QFPurchaseTransport.ingredientID, type: "INGREDIENT", title: "番茄", subtitle: "", mediaId: nil, materials: [], steps: [], minutes: nil, sourceName: nil, sourceUrl: nil, license: nil, licenseUrl: nil, attribution: nil)
    let controller = QFInventoryLotEditorViewController(app: app, ingredient: ingredient, householdID: nil) { _ in XCTFail("Unknown acquisition date must not commit priced stock") }
    let window = show(controller); defer { window.isHidden = true; QFContentDraftStore.remove(app: app, kind: key) }
    try button("inventory.receive.save", controller.view).sendActions(for: .touchUpInside)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertFalse(QFPurchaseTransport.requests.contains { $0.httpMethod == "PUT" })
  }
  @MainActor func testManualInventoryTransmitsConfirmedDateAndPriceTogether() async throws {
    let app = try await session(), key = "inventory-receive.personal." + QFPurchaseTransport.ingredientID
    var draft = QFInventoryReceiveDraft(); draft.quantity = "500"; draft.totalCost = "6"; draft.acquiredOn = "2026-10-05"
    XCTAssertTrue(QFContentDraftStore.save(draft, app: app, kind: key))
    let ingredient = QFCatalogItem(id: QFPurchaseTransport.ingredientID, type: "INGREDIENT", title: "番茄", subtitle: "", mediaId: nil, materials: [], steps: [], minutes: nil, sourceName: nil, sourceUrl: nil, license: nil, licenseUrl: nil, attribution: nil)
    var saved = false
    let controller = QFInventoryLotEditorViewController(app: app, ingredient: ingredient, householdID: nil) { _ in saved = true }
    let window = show(controller); defer { window.isHidden = true; QFContentDraftStore.remove(app: app, kind: key) }
    try button("inventory.receive.save", controller.view).sendActions(for: .touchUpInside)
    try await eventually { saved }
    let request = try XCTUnwrap(QFPurchaseTransport.requests.first { $0.httpMethod == "PUT" })
    let input = try JSONDecoder().decode(QFInventoryLotDraft.self, from: QFPurchaseTransport.body(request))
    XCTAssertEqual(input.acquiredOn, "2026-10-05"); XCTAssertEqual(input.currency, "CNY"); XCTAssertEqual(input.totalCost, "6")
    XCTAssertFalse(QFPurchaseTransport.requests.contains { $0.url?.path.contains("purchase-receipts") == true })
  }
  @MainActor func testRefundTrendExtendsBelowZero() async throws {
    let app = try await session(); QFPurchaseTransport.negativeTrend = true
    let controller = QFPreparationExpensesViewController(app: app); let window = show(controller); defer { window.isHidden = true }
    try await eventually { !self.descendants(BarChartView.self, controller.view).isEmpty }
    let chart = try XCTUnwrap(descendants(BarChartView.self, controller.view).first)
    XCTAssertLessThan(chart.leftAxis.axisMinimum, 0); XCTAssertEqual(chart.barData?.yMin, -6); XCTAssertEqual(chart.barData?.entryCount, 7)
  }

  func testLegacyUnlinkedMaterialCostStillDecodes() throws {
    var json = QFPurchaseTransport.costFixture()
    json["materials"] = [["ingredientId": NSNull(), "name": "自填材料", "quantity": "适量", "unitCode": "", "totals": [], "status": "UNVERIFIED", "sources": []]]
    let value = try JSONDecoder().decode(QFCookingCost.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertNil(value.materials[0].ingredientId)
  }
  @MainActor func testTenLanguageExpenseAndCostLayouts() async throws {
    let app = try await session(), original = app.interfaceLanguage
    defer { _ = app.setInterfaceLanguage(original) }
    let receipt = try JSONDecoder().decode(QFPurchaseReceipt.self, from: JSONSerialization.data(withJSONObject: QFPurchaseTransport.fixture()))
    let cost = try JSONDecoder().decode(QFCookingCost.self, from: JSONSerialization.data(withJSONObject: QFPurchaseTransport.costFixture()))
    func capture(_ controller: UIViewController, name: String) async throws {
      let window = show(controller); defer { window.isHidden = true; window.rootViewController = nil }
      try await Task.sleep(nanoseconds: 120_000_000); window.layoutIfNeeded()
      for field in descendants(UITextField.self, controller.view) { XCTAssertGreaterThan(field.bounds.width, 40, name) }
      let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
      attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    for code in ["zh-Hans", "zh-Hant", "en", "ja", "ko", "ru", "es", "fr", "de", "pt-BR"] {
      _ = app.setInterfaceLanguage(code)
      try await capture(QFPreparationExpensesViewController(app: app), name: "Expense11-" + code)
      let detail = QFPurchaseReceiptViewController(app: app, receipt: receipt)
      try await capture(detail, name: "Receipt12-" + code)
      let draft = QFPurchaseReceiptDraft(receipt)
      XCTAssertTrue(QFContentDraftStore.save(draft, app: app, kind: "receipt.personal.new"))
      try await capture(QFPurchaseReceiptViewController(app: app), name: "Receipt14-" + code)
      QFContentDraftStore.remove(app: app, kind: "receipt.personal.new")
      try await capture(QFCookingCostsViewController(app: app, range: .init(startDate: "2026-10-06", endDate: "2026-10-06"), householdID: nil), name: "Cost13-" + code)
      try await capture(QFMissingCostViewController(app: app, record: cost), name: "Cost15-" + code)
    }
  }


  @MainActor func testShoppingReceiptIsLocalUntilSubmitAndCarriesSourceRevisions() async throws {
    let app=try await session();let list=try JSONDecoder().decode(QFShoppingList.self,from:JSONSerialization.data(withJSONObject:QFPurchaseTransport.shoppingFixture()))
    let key="receipt.shopping."+list.id;QFContentDraftStore.remove(app:app,kind:key)
    let c=QFPurchaseReceiptViewController(app:app,shoppingList:list),window=show(c);defer{window.isHidden=true;QFContentDraftStore.remove(app:app,kind:key)}
    XCTAssertFalse(QFPurchaseTransport.requests.contains{$0.httpMethod=="PUT"})
    try button("purchase.receipt.save",c.view).sendActions(for:.touchUpInside)
    try await eventually{QFPurchaseTransport.requests.contains{$0.httpMethod=="PUT"}}
    let request=try XCTUnwrap(QFPurchaseTransport.requests.first{$0.httpMethod=="PUT"});let body=try JSONDecoder().decode(QFPurchaseReceiptRequest.self,from:QFPurchaseTransport.body(request))
    XCTAssertEqual(body.shoppingSource?.listId,list.id);XCTAssertEqual(body.shoppingSource?.expectedRevision,3);XCTAssertEqual(body.shoppingSource?.items.first?.expectedRevision,2);XCTAssertEqual(body.items.first?.id,list.items.first?.id)
    XCTAssertNil(body.items.first?.lineAmount)
  }
  @MainActor func testShoppingReceiveButtonOpensConfirmationBeforeWritingInventory() async throws {
    let app=try await session(),c=QFIngredientViewController(app:app),window=show(c);defer{window.isHidden=true}
    let tabs=try XCTUnwrap(descendants(UISegmentedControl.self,c.view).first{$0.accessibilityIdentifier=="ingredient.segment"});tabs.selectedSegmentIndex=1;tabs.sendActions(for:.valueChanged)
    try await eventually{(try? self.button("shopping.receive",c.view).isEnabled)==true}
    try button("shopping.receive",c.view).sendActions(for:.touchUpInside)
    XCTAssertTrue(c.navigationController?.topViewController is QFPurchaseReceiptViewController);XCTAssertFalse(QFPurchaseTransport.requests.contains{$0.httpMethod=="PUT"})
  }
  @MainActor func testCookingStatisticsUsesServerTotalsAndStableRecipeIdentity() async throws {
    let app=try await session(),c=QFCookingUsageViewController(app:app),window=show(c);defer{window.isHidden=true}
    try await eventually{self.descendants(UIButton.self,c.view).filter{$0.accessibilityIdentifier?.hasPrefix("cooking.usage.")==true}.count==20}
    XCTAssertTrue(descendants(UILabel.self,c.view).contains{$0.text=="300"})
    let scroll=try XCTUnwrap(descendants(UIScrollView.self,c.view).first{$0.mj_footer != nil});await scroll.mj_footer?.beginRefreshing()
    try await eventually{self.descendants(UIButton.self,c.view).filter{$0.accessibilityIdentifier?.hasPrefix("cooking.usage.")==true}.count==25}
    let card=try XCTUnwrap(descendants(UIButton.self,c.view).first{$0.accessibilityIdentifier?.hasPrefix("cooking.usage.")==true});card.sendActions(for:.touchUpInside)
    try await eventually{QFPurchaseTransport.requests.contains{$0.url?.path.hasSuffix("cooking-records")==true}}
    let request=try XCTUnwrap(QFPurchaseTransport.requests.last{$0.url?.path.hasSuffix("cooking-records")==true});XCTAssertTrue(request.url!.query!.contains("recipeId="));XCTAssertTrue(request.url!.query!.contains("startDate="))
  }
  @MainActor func testCookingStatisticsTenLanguagesRetainSummaryAndActions() async throws {
    let app=try await session(),original=app.interfaceLanguage;defer{_ = app.setInterfaceLanguage(original)}
    for language in ["zh-Hans","zh-Hant","en","ja","ko","ru","es","fr","de","pt-BR"] {
      _ = app.setInterfaceLanguage(language);let c=QFCookingUsageViewController(app:app),window=show(c)
      try await eventually{self.descendants(UILabel.self,c.view).contains{$0.text=="300"}};window.layoutIfNeeded()
      for label in descendants(UILabel.self,c.view).filter({ $0.accessibilityIdentifier?.hasPrefix("cooking.usage.count.") == true }) {
        XCTAssertGreaterThanOrEqual(label.bounds.width + 1, label.intrinsicContentSize.width, language)
        let frame=label.convert(label.bounds,to:c.view);XCTAssertLessThanOrEqual(frame.maxX,c.view.bounds.width-20,language)
      }
      let shot=XCTAttachment(image:UIGraphicsImageRenderer(bounds:window.bounds).image{_ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)});shot.name="Plan10-"+language;shot.lifetime = .keepAlways;add(shot);window.isHidden=true
    }
  }
}
