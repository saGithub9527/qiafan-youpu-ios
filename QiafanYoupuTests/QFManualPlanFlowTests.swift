import Foundation
import MJRefresh
import UIKit
import XCTest
@testable import QiafanYoupu

private final class QFManualPlanTransport: URLProtocol {
  static let lock = NSLock()
  static var requests: [URLRequest] = []
  static var failNextBatch = false
  static var nextBatchCode: Int?
  static var nextPlanCode: Int?
  static var nextCookingCode: Int?
  static var failNextCooking = false
  static var storedCooking: [String: Any]?
  static var historyRecords: [[String: Any]] = []
  static var nextHistoryCode: Int?
  static var failNextCookingBatch = false
  static var nextCookingBatchCode: Int?
  static var inventoryRows: [[String: Any]] = inventoryValues()
  static var recipeAmount = "2"
  static var availabilityUnlinked = false
  static var nextInventoryCode: Int?
  static var failNextInventory = false
  static func inventoryValues() -> [[String: Any]] {
    (1...2).map { index in ["id": "stock-\(index)", "ingredientId": ingredientID, "ingredientName": index == 1 ? "番茄" : "西兰花", "contentAvailable": true, "categoryCode": "VEGETABLE", "unitCode": "g", "initialQuantity": "500", "currentQuantity": "500", "location": "冷藏", "status": "ACTIVE", "revision": 3, "createdAt": "2026-09-30T10:00:00Z"] }
  }
  static func inventoryWrites() -> [URLRequest] { requests.filter { $0.url?.path.contains("inventory/lots/") == true } }
  static let ingredientID = "82000000-0000-0000-0000-000000000001"
  static var meal = planValue()
  static var dayItems: [[String: Any]] = []
  static func reset() { lock.lock(); defer { lock.unlock() }; inventoryRows = inventoryValues(); recipeAmount = "2"; availabilityUnlinked = false; nextInventoryCode = nil; failNextInventory = false; requests = []; failNextBatch = false; nextPlanCode = nil; meal = planValue(); dayItems = []; nextCookingCode = nil; failNextCooking = false; storedCooking = nil; historyRecords = []; nextHistoryCode = nil; failNextCookingBatch = false; nextCookingBatchCode = nil }
  static func batchBodies() throws -> [QFPlanBatchDraft] {
    lock.lock(); defer { lock.unlock() }
    return try requests.filter { $0.url?.path.hasSuffix("planned-meals/batch") == true }.map {
      try JSONDecoder().decode(QFPlanBatchDraft.self, from: body($0))
    }
  }
  static func body(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }; result.append(buffer, count: count)
    }
    return result
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let bytes = Self.body(request)
    var captured = request; captured.httpBody = bytes
    let path = request.url!.path
    Self.lock.lock(); Self.requests.append(captured)
    let isCookingBatch = path.hasSuffix("cooking-records/batch")
    let isCooking = path.contains("/cooking-records/") && !isCookingBatch
    let isHistory = path.hasSuffix("/cooking-records")
    let isInventoryWrite = path.contains("/inventory/lots/")
    let fail = (isInventoryWrite && Self.failNextInventory) || (isCookingBatch && Self.failNextCookingBatch) || (path.hasSuffix("planned-meals/batch") && Self.failNextBatch) || (isCooking && request.httpMethod == "PUT" && Self.failNextCooking)
    let isPlan = path.hasSuffix("planned-meals/test-plan")
    let rejection = isInventoryWrite ? Self.nextInventoryCode : isCookingBatch ? Self.nextCookingBatchCode : isHistory ? Self.nextHistoryCode : path.hasSuffix("planned-meals/batch") ? Self.nextBatchCode : isPlan && request.httpMethod == "PUT" ? Self.nextPlanCode : isCooking && request.httpMethod == "PUT" ? Self.nextCookingCode : isCooking && Self.storedCooking == nil ? 40400 : nil
    if isInventoryWrite { Self.failNextInventory = false; Self.nextInventoryCode = nil }
    if isCookingBatch { Self.failNextCookingBatch = false; Self.nextCookingBatchCode = nil }
    if isHistory { Self.nextHistoryCode = nil }
    if isCooking && request.httpMethod == "PUT" { Self.nextCookingCode = nil; Self.failNextCooking = false }
    if isPlan { Self.nextPlanCode = nil }
    if path.hasSuffix("planned-meals/batch") { Self.nextBatchCode = nil }
    if fail { Self.failNextBatch = false }; Self.lock.unlock()
    if fail { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
    let value: Any
    if path.hasSuffix("app/config") {
      value = ["appName": "Test", "serviceRegion": "cn", "loginMethods": ["quick": true, "apple": true],
        "agreements": ["userAgreement": "test", "privacyPolicy": "test"]]
    } else if path.hasSuffix("auth/quick/sessions") {
      let token = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
      value = ["session": ["accessToken": token, "refreshToken": token,
        "accessTokenExpiresIn": 3600, "refreshTokenExpiresIn": 86400],
        "user": ["userId": "manual-plan-test-user", "systemAccount": "sys_manual_plan_test",
          "boundAccount": NSNull(), "accountNameBound": false, "passwordConfigured": false,
          "nickname": "测试用户", "avatarUrl": NSNull(), "countryCode": "CN",
          "regionCode": NSNull(), "bio": NSNull(), "appleBound": false]]
    } else if path.hasSuffix("cooking-cost-previews") {
      let body = try! JSONSerialization.jsonObject(with: bytes) as! [String: Any]
      let items = (body["items"] as! [[String: Any]]).map { item -> [String: Any] in
        let materials = (item["materials"] as! [[String: Any]]).map { row -> [String: Any] in
          let quantity = Decimal(string: row["amount"] as! String)!
          let total = NSDecimalNumber(decimal:quantity * Decimal(string:"0.0005")!).stringValue
          return ["ingredientId":row["ingredientId"]!, "name":row["name"]!, "quantity":row["amount"]!, "unitCode":row["unit"]!, "status":"COMPLETE", "totals":[["currency":"CNY", "total":total]]]
        }
        return ["id":item["id"]!, "status":"COMPLETE", "totals":[["currency":"CNY","total":"1.25"]], "pendingMaterialCount":0, "materials":materials]
      }
      value = ["preview":true, "reservesInventory":false, "date":body["date"]!, "householdId":body["householdId"] ?? NSNull(), "valuationRevision":7, "status":"COMPLETE", "totals":[["currency":"CNY","total":"2.5"]], "pendingMaterialCount":0, "items":items]
    } else if path.hasSuffix("measurement-units") {
      let names = ["zh-Hans": "克", "zh-Hant": "克", "en": "Gram", "ja": "グラム", "ko": "그램", "ru": "Грамм", "es": "Gramo", "fr": "Gramme", "de": "Gramm", "pt-BR": "Grama"]
      value = [["code": "g", "dimension": "MASS", "symbol": "g", "name": names[request.value(forHTTPHeaderField: "Accept-Language") ?? "zh-Hans"] ?? "Gram", "factorToBase": "1", "decimalAllowed": true]]
    } else if path.hasSuffix("home/recipes/a") {
      value = ["id": "a", "title": "紫菜蛋花汤", "subtitle": "", "servings": 2, "favoriteCount": 0, "ratingCount": 0, "isFavorite": false, "categoryIds": [], "cuisineIds": [], "tasteIds": [], "countryCodes": ["CN"], "contentLanguage": "zh-Hans", "contentAvailable": true,
        "materials": [["name": "紫菜", "amount": Self.recipeAmount, "unit": "g", "ingredientId": Self.ingredientID]], "steps": []]
    } else if isInventoryWrite {
      let index = Self.inventoryRows.firstIndex { $0["id"] as? String == request.url!.lastPathComponent }!
      if rejection == nil {
        let input = try! JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        if request.httpMethod == "DELETE" { Self.inventoryRows[index]["status"] = "ARCHIVED" }
        else { Self.inventoryRows[index]["currentQuantity"] = input["currentQuantity"]; Self.inventoryRows[index]["location"] = input["location"] }
        Self.inventoryRows[index]["revision"] = (Self.inventoryRows[index]["revision"] as! Int) + 1
      }
      value = Self.inventoryRows[index]
    } else if path.hasSuffix("/inventory") {
      let rows = Self.inventoryRows.filter { $0["status"] as? String != "ARCHIVED" }
      let page = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value ?? "0") ?? 0
      let titles = ["zh-Hans": ["番茄", "西兰花"], "zh-Hant": ["番茄", "青花菜"], "en": ["Tomato", "Broccoli"], "ja": ["トマト", "ブロッコリー"], "ko": ["토마토", "브로콜리"], "ru": ["Помидор", "Брокколи"], "es": ["Tomate", "Brócoli"], "fr": ["Tomate", "Brocoli"], "de": ["Tomate", "Brokkoli"], "pt-BR": ["Tomate", "Brócolis"]]
      let names = titles[request.value(forHTTPHeaderField: "Accept-Language") ?? "zh-Hans"] ?? titles["en"]!
      value = ["items": Array(rows.dropFirst(page * 20).prefix(20)).enumerated().map { index, original -> [String: Any] in var row = original; row["ingredientName"] = names[index % 2]; return row }, "total": rows.count]
    } else if path.hasSuffix("/shopping-lists") {
      value = ["items": [], "total": 0]
    } else if path.hasSuffix("inventory/balances") {
      value = ["items": [["ingredientId": Self.ingredientID, "unitCode": "g", "quantity": "250"]]]
    } else if isHistory {
      value = Self.historyValue(request)
    } else if isCookingBatch {
      let input = try! JSONSerialization.jsonObject(with: bytes) as! [String: Any]
      let items = (input["items"] as! [[String: Any]]).map { item -> [String: Any] in
        var record = item; record["date"] = input["date"]; record["inventoryMode"] = "ACTUAL_MATERIALS"; record["revision"] = 0; record["cost"] = NSNull(); return record
      }
      value = ["requestId": input["requestId"]!, "items": items, "total": items.count]
    } else if isCooking {
      if request.httpMethod == "PUT" && rejection == nil {
        var saved = try! JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        saved["id"] = request.url!.lastPathComponent; saved["inventoryMode"] = "ACTUAL_MATERIALS"
        saved["revision"] = (saved["expectedRevision"] as? Int).map { $0 + 1 } ?? 0
        Self.storedCooking = saved
        if let index = Self.historyRecords.firstIndex(where: { $0["id"] as? String == saved["id"] as? String }) {
          Self.historyRecords[index] = saved
        }
      }
      value = Self.storedCooking as Any? ?? NSNull()
    } else if path.hasSuffix("catalog") {
      value = ["items": [Self.recipe("a", "番茄炒蛋"), Self.recipe("b", "清炒青菜")], "total": 2]
    } else if path.hasSuffix("planned-meals/calendar") {
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      value = ["month": query.first { $0.name == "month" }?.value ?? "2026-10", "days": []]
    } else if path.hasSuffix("planned-meals/day") {
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      value = ["date": query.first { $0.name == "date" }?.value ?? "2026-09-30", "slots": [["meal": "LUNCH", "revision": 0, "items": Self.dayItems]]]
    } else if path.hasSuffix("planned-meals/availability") {
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      value = ["date": query.first { $0.name == "date" }?.value ?? "2026-09-30", "householdId": NSNull(),
        "items": Self.dayItems.map { dish in
          ["planId": dish["id"]!, "planRevision": dish["revision"] ?? 0, "status": "SHORT",
            "materials": [["ingredientId": Self.availabilityUnlinked ? NSNull() : Self.ingredientID as Any,
              "name": "牛肉", "status": Self.availabilityUnlinked ? "UNCONFIRMED" : "SHORT",
              "requiredQuantity": "200", "availableQuantity": "120", "missingQuantity": "80", "unitCode": "g"]]]
        }]
    } else if path.hasSuffix("planned-meals/batch") {
      let input = try! JSONDecoder().decode(QFPlanBatchDraft.self, from: bytes)
      value = ["requestId": input.requestId.uuidString, "addedCount": 2, "skippedCount": 0, "days": []]
    } else if isPlan {
      if request.httpMethod == "PUT" && rejection == nil,
        let payload = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
        for (key, value) in payload where key != "expectedRevision" { Self.meal[key] = value }
        Self.meal["revision"] = (Self.meal["revision"] as? Int ?? 0) + 1
      }
      value = Self.meal
    } else { value = NSNull() }
    let data = try! JSONSerialization.data(withJSONObject: ["code": rejection ?? 0, "message": "test", "requestId": "test", "data": value])
    let response = HTTPURLResponse(url: request.url!, statusCode: rejection.map { $0 / 100 } ?? 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
  static func historyValue(_ request: URLRequest) -> [String: Any] {
    let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    let month = query["month"] ?? "2026-09", date = query["date"]
    let all = historyRecords.filter { ($0["date"] as? String)?.hasPrefix(month) == true }
    guard let date else { return ["items": all, "total": all.count] }
    let daily = all.filter { $0["date"] as? String == date }, page = Int(query["page"] ?? "0") ?? 0
    func totals(_ records: [[String: Any]]) -> [[String: String]] {
      var sums: [String: Decimal] = [:]
      for row in records { if let cost = row["cost"] as? String, let number = Decimal(string: cost) { sums[row["currency"] as? String ?? "CNY", default: 0] += number } }
      return sums.keys.sorted().map { ["currency": $0, "total": String(describing: sums[$0]!)] }
    }
    let dates = Array(Set(all.compactMap { $0["date"] as? String })).sorted()
    return ["items": Array(daily.dropFirst(page * 20).prefix(20)), "total": daily.count,
      "totals": totals(daily), "missingCostCount": daily.filter { !($0["cost"] is String) }.count,
      "summary": ["month": month, "completedCount": all.count, "cookingDays": dates.count, "recordDates": dates,
        "totals": totals(all), "missingCostCount": all.filter { !($0["cost"] is String) }.count]]
  }
  static func historyReads() -> [URLRequest] { requests.filter { $0.url?.path.hasSuffix("/cooking-records") == true } }
  static func planValue() -> [String: Any] {
    ["id": "test-plan", "recipeId": "a", "title": "紫菜蛋花汤", "subtitle": "", "date": "2026-09-30", "meal": "LUNCH", "servings": 2, "revision": 0, "completed": false, "skipped": false, "contentAvailable": true]
  }
  static func planWrites() -> [URLRequest] {
    lock.lock(); defer { lock.unlock() }
    return requests.filter { $0.url?.path.hasSuffix("planned-meals/test-plan") == true && $0.httpMethod == "PUT" }
  }
  static func cookingWrites() -> [URLRequest] {
    lock.lock(); defer { lock.unlock() }
    return requests.filter { $0.url?.path.contains("/cooking-records/") == true && $0.httpMethod == "PUT" }
  }
  private static func recipe(_ id: String, _ title: String) -> [String: Any] {
    ["id": id, "type": "RECIPE", "title": title, "subtitle": "家常菜", "materials": [], "steps": [], "minutes": 10]
  }
}

final class QFManualPlanFlowTests: XCTestCase {
  private var service = ""
  override func setUp() {
    super.setUp(); service = "com.talka.manual-plan-tests." + UUID().uuidString
    QFManualPlanTransport.reset()
  }
  override func tearDownWithError() throws {
    for key in ["current", "device-id", "credential-test"] { try QFKeychainStore(service: service).remove(key) }
    UserDefaults.standard.removeObject(forKey: "qf.profile.draft.manual-plan-test.manual-plan-test-user.manual-plan.personal")
    QFManualPlanTransport.reset()
    try super.tearDownWithError()
  }
  @MainActor private func makeSession() async throws -> QFAppSession {
    let identity = QFDeviceIdentity(service: service)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QFManualPlanTransport.self]
    let api = QFAPIClient(environment: QFAPIEnvironment(name: "manual-plan-test", baseURL: URL(string: "https://manual-plan.invalid/api/v1")), identity: identity, transportConfiguration: configuration)
    api.recordsRequests = false
    let app = QFAppSession(api: api, identity: identity, keychain: QFKeychainStore(service: service))
    await app.start(); try await app.login(agreementAccepted: true)
    QFContentDraftStore.remove(app: app, kind: "manual-plan.personal")
    QFContentDraftStore.remove(app: app, kind: "complete-plan.test-plan")
    QFContentDraftStore.remove(app: app, kind: "inventory-edit.personal")
    return app
  }
  @MainActor private func views<T: UIView>(_ type: T.Type, _ root: UIView) -> [T] {
    ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, $0) }
  }
  @MainActor private func button(_ id: String, in root: UIView) throws -> UIButton {
    try XCTUnwrap(views(UIButton.self, root).first { $0.accessibilityIdentifier == id })
  }
  @MainActor private func eventually(_ condition: () -> Bool) async throws {
    let until = Date().addingTimeInterval(3)
    while !condition() && Date() < until { try await Task.sleep(nanoseconds: 20_000_000) }
    XCTAssertTrue(condition())
  }
  @MainActor private func window(_ controller: UIViewController) -> UIWindow {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = controller; window.makeKeyAndVisible()
    controller.loadViewIfNeeded(); window.layoutIfNeeded()
    return window
  }
  @MainActor private func screenshot(_ view: UIView, name: String) {
    view.layoutIfNeeded()
    let image = UIGraphicsImageRenderer(size: view.bounds.size).image { _ in
      view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
    add(attachment)
  }
  @MainActor func testMultiSelectionStaysLocalUntilSingleBatchSave() async throws {
    let app = try await makeSession()
    let saved = expectation(description: "Batch save callback")
    let editor = QFCreatePlanViewController(app: app, initialDate: QFManualPlanDraft.date("2026-09-30")!) { saved.fulfill() }
    let nav = QFNavigationController(rootViewController: UIViewController())
    let window = window(nav); defer { window.isHidden = true; window.rootViewController = nil }
    nav.pushViewController(editor, animated: false)
    try button("plan.create.add.LUNCH", in: editor.view).sendActions(for: .touchUpInside)
    try await eventually { nav.topViewController is QFPlanRecipePickerViewController }
    let picker = try XCTUnwrap(nav.topViewController as? QFPlanRecipePickerViewController)
    try await eventually { nav.transitionCoordinator == nil }
    let table = try XCTUnwrap(views(UITableView.self, picker.view).first)
    try await eventually { table.numberOfRows(inSection: 0) == 2 }
    table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: 0, section: 0))
    table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: 1, section: 0))
    picker.view.layoutIfNeeded()
    XCTAssertGreaterThan(table.bounds.height, 200)
    XCTAssertLessThan(table.frame.minY, picker.view.bounds.height / 2)
    let selectedButton = try button("plan.recipePicker.add", in: picker.view)
    XCTAssertTrue(selectedButton.currentTitle?.contains("2") == true, selectedButton.currentTitle ?? "nil")
    XCTAssertTrue(selectedButton.isEnabled)
    try await eventually { selectedButton.titleLabel?.text?.contains("2") == true }
    screenshot(picker.view, name: "Plan recipe multi-selection")
    try button("plan.recipePicker.add", in: picker.view).sendActions(for: .touchUpInside)
    try await eventually { nav.topViewController === editor }
    try await eventually { QFContentDraftStore.load(QFManualPlanDraft.self, app: app, kind: "manual-plan.personal")?.recipeCount == 2 }
    XCTAssertEqual(try QFManualPlanTransport.batchBodies().count, 0)
    screenshot(editor.view, name: "Create plan local draft")
    try button("plan.create.save", in: editor.view).sendActions(for: .touchUpInside)
    await fulfillment(of: [saved], timeout: 3)
    let bodies = try QFManualPlanTransport.batchBodies()
    XCTAssertEqual(bodies.count, 1)
    XCTAssertEqual(bodies.first?.meals.first?.items.map(\.recipeId), ["a", "b"])
    XCTAssertNil(QFContentDraftStore.load(QFManualPlanDraft.self, app: app, kind: "manual-plan.personal"))
  }
  @MainActor func testCapacityRejectionUnlocksDraftButPermissionLossKeepsReceipt() async throws {
    let app = try await makeSession()
    var draft = QFManualPlanDraft(date: "2026-09-30")
    draft.recipes["LUNCH"] = [.init(id: "a", title: "番茄炒蛋", subtitle: "", mediaId: nil, minutes: nil, language: app.interfaceLanguage)]
    XCTAssertTrue(QFContentDraftStore.save(draft, app: app, kind: "manual-plan.personal"))
    let editor = QFCreatePlanViewController(app: app, initialDate: Date()) { XCTFail("A rejected request must not save") }
    let nav = QFNavigationController(rootViewController: editor)
    let window = window(nav); defer { window.isHidden = true; window.rootViewController = nil }
    let save = try button("plan.create.save", in: editor.view)
    QFManualPlanTransport.nextBatchCode = 42204
    save.sendActions(for: .touchUpInside)
    try await eventually { (try? QFManualPlanTransport.batchBodies().count) == 1 && save.isEnabled }
    XCTAssertNil(QFContentDraftStore.load(QFManualPlanDraft.self, app: app, kind: "manual-plan.personal")?.pending)
    XCTAssertTrue(editor.bodyStack.isUserInteractionEnabled)
    QFManualPlanTransport.failNextBatch = true
    save.sendActions(for: .touchUpInside)
    try await eventually { (try? QFManualPlanTransport.batchBodies().count) == 2 && save.isEnabled }
    let receipt = QFContentDraftStore.load(QFManualPlanDraft.self, app: app, kind: "manual-plan.personal")?.pending
    XCTAssertNotNil(receipt)
    QFManualPlanTransport.nextBatchCode = 40300
    save.sendActions(for: .touchUpInside)
    try await eventually { (try? QFManualPlanTransport.batchBodies().count) == 3 && save.isEnabled }
    XCTAssertEqual(QFContentDraftStore.load(QFManualPlanDraft.self, app: app, kind: "manual-plan.personal")?.pending, receipt)
    XCTAssertFalse(editor.bodyStack.isUserInteractionEnabled)
  }
  @MainActor func testUncertainSubmissionRetriesSamePersistedReceipt() async throws {
    let app = try await makeSession()
    var draft = QFManualPlanDraft(date: "2026-09-30")
    draft.recipes["LUNCH"] = [.init(id: "a", title: "番茄炒蛋", subtitle: "", mediaId: nil, minutes: nil, language: app.interfaceLanguage)]
    XCTAssertTrue(QFContentDraftStore.save(draft, app: app, kind: "manual-plan.personal"))
    QFManualPlanTransport.failNextBatch = true
    let saved = expectation(description: "Retry saves")
    let editor = QFCreatePlanViewController(app: app, initialDate: Date()) { saved.fulfill() }
    let nav = QFNavigationController(rootViewController: editor)
    let window = window(nav); defer { window.isHidden = true; window.rootViewController = nil }
    let save = try button("plan.create.save", in: editor.view)
    save.sendActions(for: .touchUpInside)
    try await eventually { (try? QFManualPlanTransport.batchBodies().count) == 1 && save.isEnabled }
    let pending = QFContentDraftStore.load(QFManualPlanDraft.self, app: app, kind: "manual-plan.personal")?.pending
    XCTAssertNotNil(pending)
    save.sendActions(for: .touchUpInside)
    await fulfillment(of: [saved], timeout: 3)
    let bodies = try QFManualPlanTransport.batchBodies()
    XCTAssertEqual(bodies.count, 2)
    XCTAssertEqual(bodies.first, bodies.last)
    XCTAssertEqual(bodies.first?.requestId, pending?.body.requestId)
  }
}

extension QFManualPlanFlowTests {
  @MainActor private func completion(_ app: QFAppSession, saved: @escaping () -> Void) throws -> QFCompleteMealViewController {
    let item = try JSONDecoder().decode(QFPlannedMeal.self, from: JSONSerialization.data(withJSONObject: QFManualPlanTransport.planValue()))
    return QFCompleteMealViewController(app: app, plan: item, saved: saved)
  }
  @MainActor private func waitForCompletion(_ editor: QFCompleteMealViewController) async throws {
    try await eventually { self.views(UILabel.self, editor.view).contains { $0.text?.contains("250") == true } && editor.bodyStack.isUserInteractionEnabled }
  }
  @MainActor func testPlanHomeKeepsEmptyMealsAndExpandsLocally() async throws {
    let app = try await makeSession()
    QFManualPlanTransport.dayItems = (0..<5).map { index in
      var row = QFManualPlanTransport.planValue(); row["id"] = "test-dish-\(index)"; row["date"] = QFContentDate.day(Date()); return row
    }
    let page = QFPlanViewController(app: app)
    let window = window(QFNavigationController(rootViewController: page)); defer { window.isHidden = true; window.rootViewController = nil }
    try await eventually { self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "plan.expand.LUNCH" } }
    try await eventually {
      self.views(UILabel.self, page.view).contains {
        $0.accessibilityIdentifier == "plan.dish.shortage.test-dish-0" && $0.text?.contains("牛肉") == true
      }
    }
    XCTAssertEqual(QFManualPlanTransport.requests.filter { $0.url?.path.hasSuffix("planned-meals/availability") == true }.count, 1)
    XCTAssertNotNil(try button("plan.empty.BREAKFAST", in: page.view)); XCTAssertNotNil(try button("plan.empty.DINNER", in: page.view))
    XCTAssertEqual(views(UIStackView.self, page.view).filter { $0.accessibilityIdentifier?.hasPrefix("plan.dish.") == true }.count, 3)
    let before = QFManualPlanTransport.requests.count
    try button("plan.expand.LUNCH", in: page.view).sendActions(for: .touchUpInside)
    XCTAssertEqual(views(UIStackView.self, page.view).filter { $0.accessibilityIdentifier?.hasPrefix("plan.dish.") == true }.count, 5)
    XCTAssertEqual(QFManualPlanTransport.requests.count, before)
    try button("plan.expand.LUNCH", in: page.view).sendActions(for: .touchUpInside)
    XCTAssertEqual(views(UIStackView.self, page.view).filter { $0.accessibilityIdentifier?.hasPrefix("plan.dish.") == true }.count, 3)
    try button("plan.empty.DINNER", in: page.view).sendActions(for: .touchUpInside)
    try await eventually { page.navigationController?.topViewController is QFCreatePlanViewController }
    XCTAssertTrue(QFManualPlanTransport.requests.filter { $0.httpMethod == "PUT" || $0.httpMethod == "POST" && !$0.url!.path.contains("auth/") }.isEmpty)
  }
  @MainActor func testPlanCardDoesNotCallUnlinkedIngredientMissingStock() async throws {
    let app = try await makeSession()
    QFManualPlanTransport.availabilityUnlinked = true
    var row = QFManualPlanTransport.planValue(); row["date"] = QFContentDate.day(Date())
    QFManualPlanTransport.dayItems = [row]
    let page = QFPlanViewController(app: app)
    let window = window(QFNavigationController(rootViewController: page))
    defer { window.isHidden = true; window.rootViewController = nil }
    try await eventually {
      self.views(UILabel.self, page.view).contains {
        $0.accessibilityIdentifier == "plan.dish.shortage.test-plan"
          && $0.text?.contains("食材未关联") == true
          && $0.text?.contains("牛肉") == true
      }
    }
  }
  @MainActor func testCompletionEditsStayLocalAndSendActualAmountsOnce() async throws {
    let app = try await makeSession(), saved = expectation(description: "Actual completion saved")
    let editor = try completion(app) { saved.fulfill() }
    let nav = QFNavigationController(rootViewController: UIViewController())
    let window = window(nav); defer { window.isHidden = true; window.rootViewController = nil }
    nav.pushViewController(editor, animated: false)
    try await waitForCompletion(editor)
    let amount = try XCTUnwrap(views(UITextField.self, editor.view).first { $0.accessibilityIdentifier == "plan.complete.amount.0" })
    amount.text = "3.5"; amount.sendActions(for: .editingChanged)
    XCTAssertTrue(QFManualPlanTransport.cookingWrites().isEmpty)
    XCTAssertEqual(QFContentDraftStore.load(QFMealCompletionDraft.self, app: app, kind: "complete-plan.test-plan")?.record.materials.first?.amount, "3.5")
    screenshot(editor.view, name: "Confirm actual cooking quantities")
    try button("plan.complete.save", in: editor.view).sendActions(for: .touchUpInside)
    await fulfillment(of: [saved], timeout: 4)
    let writes = QFManualPlanTransport.cookingWrites(); XCTAssertEqual(writes.count, 1)
    let body = try JSONSerialization.jsonObject(with: QFManualPlanTransport.body(XCTUnwrap(writes.first))) as! [String: Any]
    XCTAssertEqual(body["expectedPlanRevision"] as? Int, 0)
    XCTAssertEqual((body["materials"] as? [[String: Any]])?.first?["amount"] as? String, "3.5")
    XCTAssertNil(body["cost"])
    XCTAssertFalse(QFManualPlanTransport.requests.contains { $0.url?.path.contains("consume-inventory") == true })
    XCTAssertNil(QFContentDraftStore.load(QFMealCompletionDraft.self, app: app, kind: "complete-plan.test-plan"))
  }
  @MainActor func testCompletionRecordsRemainderWithoutChangingMeasuredAmount() async throws {
    let app = try await makeSession(), saved = expectation(description: "Completion saved")
    let editor = try completion(app) { saved.fulfill() }
    let window = window(QFNavigationController(rootViewController: editor))
    defer { window.isHidden = true; window.rootViewController = nil }
    try await waitForCompletion(editor)
    try await eventually { self.previewRequests().count == 1 }
    try button("plan.complete.usage.0", in: editor.view).sendActions(for: .touchUpInside)
    try await Task.sleep(nanoseconds: 850_000_000)
    XCTAssertEqual(previewRequests().count, 1)
    XCTAssertEqual(QFContentDraftStore.load(QFMealCompletionDraft.self, app: app, kind: "complete-plan.test-plan")?.record.materials.first?.usageStatus, "HAS_REMAINDER")
    try button("plan.complete.save", in: editor.view).sendActions(for: .touchUpInside)
    await fulfillment(of: [saved], timeout: 4)
    let body = try JSONSerialization.jsonObject(with: QFManualPlanTransport.body(XCTUnwrap(QFManualPlanTransport.cookingWrites().first))) as! [String: Any]
    XCTAssertEqual((body["materials"] as? [[String: Any]])?.first?["usageStatus"] as? String, "HAS_REMAINDER")
    XCTAssertEqual((body["materials"] as? [[String: Any]])?.first?["amount"] as? String, "2")
  }
  @MainActor func testQualitativeAmountRecordsUsageWithoutCostPreview() async throws {
    QFManualPlanTransport.recipeAmount = "适量"
    let app = try await makeSession(), saved = expectation(description: "Qualitative completion saved")
    let editor = try completion(app) { saved.fulfill() }
    let window = window(QFNavigationController(rootViewController: editor))
    defer { window.isHidden = true; window.rootViewController = nil }
    try await waitForCompletion(editor)
    XCTAssertEqual(QFContentDraftStore.load(QFMealCompletionDraft.self, app: app, kind: "complete-plan.test-plan")?.record.materials.first?.usageStatus, "USED")
    XCTAssertTrue(previewRequests().isEmpty)
    try button("plan.complete.save", in: editor.view).sendActions(for: .touchUpInside)
    await fulfillment(of: [saved], timeout: 4)
    let body = try JSONSerialization.jsonObject(with: QFManualPlanTransport.body(XCTUnwrap(QFManualPlanTransport.cookingWrites().first))) as! [String: Any]
    XCTAssertEqual((body["materials"] as? [[String: Any]])?.first?["usageStatus"] as? String, "USED")
    XCTAssertEqual((body["materials"] as? [[String: Any]])?.first?["amount"] as? String, "适量")
  }
  @MainActor func testCompletionComparesEditedAmountWithStockWithoutWriting() async throws {
    let app = try await makeSession()
    let editor = try completion(app) { XCTFail("Read-only comparison must not save") }
    let window = window(QFNavigationController(rootViewController: editor))
    defer { window.isHidden = true; window.rootViewController = nil }
    try await waitForCompletion(editor)
    let amount = try XCTUnwrap(views(UITextField.self, editor.view).first {
      $0.accessibilityIdentifier == "plan.complete.amount.0"
    })
    amount.text = "300"; amount.sendActions(for: .editingChanged)
    try await eventually {
      self.views(UILabel.self, editor.view).contains {
        $0.accessibilityIdentifier == "plan.complete.stock.0" && $0.text?.contains("50") == true
      }
    }
    XCTAssertTrue(QFManualPlanTransport.cookingWrites().isEmpty)
  }
  @MainActor func testCompletionStockFailureAllowsCorrection() async throws {
    let app = try await makeSession()
    let editor = try completion(app) { XCTFail("Rejected completion cannot save") }
    let window = window(QFNavigationController(rootViewController: editor)); defer { window.isHidden = true; window.rootViewController = nil }
    try await waitForCompletion(editor)
    QFManualPlanTransport.nextCookingCode = 42206
    try button("plan.complete.save", in: editor.view).sendActions(for: .touchUpInside)
    try await eventually { QFManualPlanTransport.cookingWrites().count == 1 && editor.bodyStack.isUserInteractionEnabled }
    XCTAssertEqual(QFContentDraftStore.load(QFMealCompletionDraft.self, app: app, kind: "complete-plan.test-plan")?.pending, false)
  }
  @MainActor func testCompletionHistoryCostFailureAllowsCorrection() async throws {
    let app = try await makeSession()
    let editor = try completion(app) { XCTFail("Rejected completion cannot save") }
    let window = window(QFNavigationController(rootViewController: editor)); defer { window.isHidden = true; window.rootViewController = nil }
    try await waitForCompletion(editor)
    QFManualPlanTransport.nextCookingCode = 42207
    try button("plan.complete.save", in: editor.view).sendActions(for: .touchUpInside)
    try await eventually { QFManualPlanTransport.cookingWrites().count == 1 && editor.bodyStack.isUserInteractionEnabled }
    XCTAssertEqual(QFContentDraftStore.load(QFMealCompletionDraft.self, app: app, kind: "complete-plan.test-plan")?.pending, false)
  }
  @MainActor func testUncertainCompletionFreezesBodyAndRetriesSameRecord() async throws {
    let app = try await makeSession(), saved = expectation(description: "Same confirmation retried")
    let editor = try completion(app) { saved.fulfill() }
    let window = window(QFNavigationController(rootViewController: editor)); defer { window.isHidden = true; window.rootViewController = nil }
    try await waitForCompletion(editor)
    QFManualPlanTransport.failNextCooking = true
    try button("plan.complete.save", in: editor.view).sendActions(for: .touchUpInside)
    try await eventually { QFManualPlanTransport.cookingWrites().count == 1 && !editor.bodyStack.isUserInteractionEnabled && (try? self.button("plan.complete.save", in: editor.view).isEnabled) == true }
    XCTAssertEqual(QFContentDraftStore.load(QFMealCompletionDraft.self, app: app, kind: "complete-plan.test-plan")?.pending, true)
    try button("plan.complete.save", in: editor.view).sendActions(for: .touchUpInside)
    await fulfillment(of: [saved], timeout: 4)
    let writes = QFManualPlanTransport.cookingWrites(); XCTAssertEqual(writes.count, 2)
    XCTAssertEqual(writes.first?.url, writes.last?.url)
    let first = try JSONSerialization.jsonObject(with: QFManualPlanTransport.body(XCTUnwrap(writes.first))) as! NSDictionary
    let last = try JSONSerialization.jsonObject(with: QFManualPlanTransport.body(XCTUnwrap(writes.last))) as! NSDictionary
    XCTAssertEqual(first, last)
  }
  @MainActor func testCompletionConflictReadsExistingRecordWithoutSecondWrite() async throws {
    let app = try await makeSession(), saved = expectation(description: "Existing server record recovered")
    let editor = try completion(app) { saved.fulfill() }
    let window = window(QFNavigationController(rootViewController: editor)); defer { window.isHidden = true; window.rootViewController = nil }
    try await waitForCompletion(editor)
    let draft = try XCTUnwrap(QFContentDraftStore.load(QFMealCompletionDraft.self, app: app, kind: "complete-plan.test-plan"))
    var server = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft.record)) as! [String: Any]
    server["inventoryMode"] = "ACTUAL_MATERIALS"; server["note"] = "Updated elsewhere"
    QFManualPlanTransport.storedCooking = server; QFManualPlanTransport.nextCookingCode = 40900
    try button("plan.complete.save", in: editor.view).sendActions(for: .touchUpInside)
    await fulfillment(of: [saved], timeout: 4)
    XCTAssertEqual(QFManualPlanTransport.cookingWrites().count, 1)
    XCTAssertEqual(QFManualPlanTransport.requests.filter { $0.url?.path.contains("/cooking-records/") == true && $0.url?.path.hasSuffix("/cost") == false && $0.httpMethod == "GET" }.count, 1)
  }
  @MainActor func testDeletedPlanOffersExplicitReturnWithoutResubmitting() async throws {
    let app = try await makeSession()
    let editor = try completion(app) { XCTFail("A missing plan cannot complete") }
    let window = window(QFNavigationController(rootViewController: editor)); defer { window.isHidden = true; window.rootViewController = nil }
    try await waitForCompletion(editor)
    QFManualPlanTransport.nextCookingCode = 40400
    try button("plan.complete.save", in: editor.view).sendActions(for: .touchUpInside)
    try await eventually { editor.presentedViewController is UIAlertController }
    let alert = try XCTUnwrap(editor.presentedViewController as? UIAlertController)
    XCTAssertEqual(alert.title, app.text("计划已变更", "Plan changed"))
    XCTAssertEqual(alert.actions.count, 2)
    XCTAssertEqual(QFManualPlanTransport.cookingWrites().count, 1)
    XCTAssertEqual(QFManualPlanTransport.requests.filter { $0.url?.path.contains("/cooking-records/") == true && $0.url?.path.hasSuffix("/cost") == false && $0.httpMethod == "GET" }.count, 1)
    editor.dismiss(animated: false)
  }
  @MainActor func testLegacyRecordMetadataRestoresServerMaterialsAndOmitsConfirmationRevision() async throws {
    let app = try await makeSession()
    var record = QFCookingRecord()
    record.title = "紫菜蛋花汤"; record.inventoryMode = "LEGACY_RECIPE"; record.plannedMealId = "test-plan"
    record.materials = [.init(name: "紫菜", amount: "2", unit: "g", ingredientId: QFManualPlanTransport.ingredientID)]
    var obsolete = record; obsolete.materials[0].amount = "999"; obsolete.expectedPlanRevision = 0
    XCTAssertTrue(QFContentDraftStore.save(obsolete, app: app, kind: "cooking-" + record.id))
    defer { QFContentDraftStore.remove(app: app, kind: "cooking-" + record.id) }
    let editor = QFCookingRecordEditorViewController(app: app, record: record, existing: true)
    let saved = expectation(description: "Metadata edit saved"); editor.onChanged = { saved.fulfill() }
    let nav = QFNavigationController(rootViewController: UIViewController())
    let window = window(nav); defer { window.isHidden = true; window.rootViewController = nil }
    nav.pushViewController(editor, animated: false)
    XCTAssertFalse(views(UITextField.self, editor.view).contains { $0.placeholder == app.text("实际用量", "Amount used") })
    XCTAssertFalse(views(UIButton.self, editor.view).contains { $0.currentTitle == app.text("＋ 添加用料", "+ Add material") })
    let note = try XCTUnwrap(views(UITextView.self, editor.view).first)
    note.text = "Updated note"; note.delegate?.textViewDidChange?(note)
    try button("cooking.record.save", in: editor.view).sendActions(for: .touchUpInside)
    await fulfillment(of: [saved], timeout: 4)
    let body = try JSONSerialization.jsonObject(with: QFManualPlanTransport.body(XCTUnwrap(QFManualPlanTransport.cookingWrites().first))) as! [String: Any]
    XCTAssertNil(body["expectedPlanRevision"])
    XCTAssertEqual((body["materials"] as? [[String: Any]])?.first?["amount"] as? String, "2")
  }
}


extension QFManualPlanFlowTests {
  @MainActor private func editableRecord() -> QFCookingRecord {
    var record = QFCookingRecord(); record.title = "紫菜蛋花汤"; record.inventoryMode = "ACTUAL_MATERIALS"
    record.revision = 3; record.cost = "12.00"
    record.materials = [.init(name: "紫菜", amount: "2", unit: "g", ingredientId: QFManualPlanTransport.ingredientID)]
    return record
  }
  @MainActor func testRecordEditDraftKeepsOriginalRevisionAndFrozenRequest() throws {
    let record = editableRecord()
    var draft = QFCookingRecordEditDraft(record: record, language: "zh-Hans")
    draft.record.materials[0].amount = "5"
    XCTAssertTrue(draft.prepare())
    let first = try XCTUnwrap(draft.pending)
    XCTAssertEqual(first.expectedRevision, 3); XCTAssertNotNil(first.requestId)
    XCTAssertNil(first.expectedPlanRevision); XCTAssertNil(first.cost)
    var restored = try JSONDecoder().decode(QFCookingRecordEditDraft.self, from: JSONEncoder().encode(draft))
    restored.record.materials[0].amount = "9"
    XCTAssertTrue(restored.prepare())
    XCTAssertEqual(restored.pending?.requestId, first.requestId)
    XCTAssertEqual(restored.pending?.materials.first?.amount, "5")
  }
  @MainActor func testRecordEditsStayLocalUntilOneVersionedSave() async throws {
    let app = try await makeSession(), record = editableRecord()
    let editor = QFCookingRecordDetailViewController(app: app, record: record)
    let window = window(QFNavigationController(rootViewController: editor)); defer { window.isHidden = true; window.rootViewController = nil }
    try await eventually { (try? self.button("cooking.detail.edit", in: editor.view).isEnabled) == true }
    XCTAssertFalse(views(UITextField.self, editor.view).contains { $0.accessibilityIdentifier == "cooking.detail.amount.0" })
    try button("cooking.detail.edit", in: editor.view).sendActions(for: .touchUpInside)
    let amount = try XCTUnwrap(views(UITextField.self, editor.view).first { $0.accessibilityIdentifier == "cooking.detail.amount.0" })
    amount.text = "5"; amount.sendActions(for: .editingChanged)
    XCTAssertTrue(QFManualPlanTransport.cookingWrites().isEmpty)
    XCTAssertEqual(try button("cooking.detail.edit", in: editor.view).currentTitle, app.text("收起修改", "Close editing"))
    XCTAssertTrue(views(UILabel.self, editor.view).contains { $0.text == app.text("保存后更新成本", "Cost updates after saving") })
    try await Task.sleep(nanoseconds: 600_000_000)
    let screenshot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
    screenshot.name = "Record detail editing matches design09"; screenshot.lifetime = .keepAlways; add(screenshot)
    let saved = expectation(description: "Edited record saved"); editor.onChanged = { saved.fulfill() }
    try button("cooking.detail.save", in: editor.view).sendActions(for: .touchUpInside)
    await fulfillment(of: [saved], timeout: 4)
    let write = try XCTUnwrap(QFManualPlanTransport.cookingWrites().first)
    let body = try JSONDecoder().decode(QFCookingDraft.self, from: QFManualPlanTransport.body(write))
    XCTAssertEqual(body.expectedRevision, 3); XCTAssertNotNil(body.requestId); XCTAssertNil(body.expectedPlanRevision)
    XCTAssertEqual(body.materials.first?.amount, "5"); XCTAssertNil(body.cost)
    XCTAssertEqual(QFManualPlanTransport.cookingWrites().count, 1)
    XCTAssertNil(QFContentDraftStore.load(QFCookingRecordEditDraft.self, app: app, kind: "cooking-edit." + record.id))
  }
  @MainActor func testUncertainRecordEditRetriesIdenticalRequest() async throws {
    let app = try await makeSession(), record = editableRecord()
    let editor = QFCookingRecordDetailViewController(app: app, record: record)
    let window = window(QFNavigationController(rootViewController: editor)); defer { window.isHidden = true; window.rootViewController = nil }
    try await eventually { (try? self.button("cooking.detail.edit", in: editor.view).isEnabled) == true }
    try button("cooking.detail.edit", in: editor.view).sendActions(for: .touchUpInside)
    QFManualPlanTransport.failNextCooking = true
    let amount = try XCTUnwrap(views(UITextField.self, editor.view).first { $0.accessibilityIdentifier == "cooking.detail.amount.0" })
    amount.text = "3"; amount.sendActions(for: .editingChanged)
    try button("cooking.detail.save", in: editor.view).sendActions(for: .touchUpInside)
    try await eventually { QFManualPlanTransport.cookingWrites().count == 1 && (try? self.button("cooking.detail.save", in: editor.view).isEnabled) == true }
    XCTAssertFalse(try button("cooking.detail.edit", in: editor.view).isEnabled)
    XCTAssertNotNil(QFContentDraftStore.load(QFCookingRecordEditDraft.self, app: app, kind: "cooking-edit." + record.id)?.pending)
    let saved = expectation(description: "Same edit retried"); editor.onChanged = { saved.fulfill() }
    try button("cooking.detail.save", in: editor.view).sendActions(for: .touchUpInside)
    await fulfillment(of: [saved], timeout: 4)
    let writes = QFManualPlanTransport.cookingWrites(); XCTAssertEqual(writes.count, 2)
    let first = try JSONSerialization.jsonObject(with: QFManualPlanTransport.body(writes[0])) as! NSDictionary
    let second = try JSONSerialization.jsonObject(with: QFManualPlanTransport.body(writes[1])) as! NSDictionary
    XCTAssertEqual(first, second)
    XCTAssertEqual(QFManualPlanTransport.requests.filter { $0.url?.path.contains("/cooking-records/") == true && $0.url?.path.hasSuffix("/cost") == false && $0.httpMethod == "GET" }.count, 1)
  }
  @MainActor func testRecordHistoryCostRejectionUnfreezesDateDraftBeforeExplicitResubmit() async throws {
    let app = try await makeSession()
    var record = editableRecord(); record.date = "2026-09-08"
    let key = "cooking-edit." + record.id
    let editor = QFCookingRecordDetailViewController(app: app, record: record)
    let window = window(QFNavigationController(rootViewController: editor))
    defer { window.isHidden = true; window.rootViewController = nil; QFContentDraftStore.remove(app: app, kind: key) }
    try await eventually { (try? self.button("cooking.detail.edit", in: editor.view).isEnabled) == true }
    try button("cooking.detail.edit", in: editor.view).sendActions(for: .touchUpInside)
    let earlier = try XCTUnwrap(views(UIDatePicker.self, editor.view).first)
    earlier.date = try XCTUnwrap(QFManualPlanDraft.date("2026-09-07")); earlier.sendActions(for: .valueChanged)
    QFManualPlanTransport.nextCookingCode = 42207
    try button("cooking.detail.save", in: editor.view).sendActions(for: .touchUpInside)
    try await eventually {
      QFManualPlanTransport.cookingWrites().count == 1
        && QFContentDraftStore.load(QFCookingRecordEditDraft.self, app: app, kind: key)?.pending == nil
        && (try? self.button("cooking.detail.edit", in: editor.view).isEnabled) == true
    }
    let rejected = try JSONDecoder().decode(QFCookingDraft.self, from: QFManualPlanTransport.body(try XCTUnwrap(QFManualPlanTransport.cookingWrites().first)))
    let local = try XCTUnwrap(QFContentDraftStore.load(QFCookingRecordEditDraft.self, app: app, kind: key))
    XCTAssertEqual(local.baseline.revision, 3); XCTAssertEqual(local.record.date, "2026-09-07")
    XCTAssertNil(local.pending); XCTAssertNil(QFManualPlanTransport.storedCooking)
    let corrected = try XCTUnwrap(views(UIDatePicker.self, editor.view).first)
    corrected.date = try XCTUnwrap(QFManualPlanDraft.date("2026-09-09")); corrected.sendActions(for: .valueChanged)
    XCTAssertEqual(QFManualPlanTransport.cookingWrites().count, 1)
    let saved = expectation(description: "Corrected date saved after explicit confirmation")
    editor.onChanged = { saved.fulfill() }
    try button("cooking.detail.save", in: editor.view).sendActions(for: .touchUpInside)
    await fulfillment(of: [saved], timeout: 4)
    let writes = QFManualPlanTransport.cookingWrites(); XCTAssertEqual(writes.count, 2)
    let accepted = try JSONDecoder().decode(QFCookingDraft.self, from: QFManualPlanTransport.body(writes[1]))
    XCTAssertEqual(accepted.date, "2026-09-09"); XCTAssertEqual(accepted.expectedRevision, 3)
    XCTAssertNotEqual(accepted.requestId, rejected.requestId)
  }
  @MainActor func testRecordUndoNeedsConfirmationAndSendsOriginalRevision() async throws {
    let app = try await makeSession(), record = editableRecord()
    QFManualPlanTransport.storedCooking = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
    let editor = QFCookingRecordDetailViewController(app: app, record: record)
    let window = window(QFNavigationController(rootViewController: editor)); defer { window.isHidden = true; window.rootViewController = nil }
    try await eventually { (try? self.button("cooking.detail.delete", in: editor.view).isEnabled) == true }
    try button("cooking.detail.delete", in: editor.view).sendActions(for: .touchUpInside)
    try await eventually { editor.presentedViewController is QFCookingUndoConfirmationController }
    let dialog = try XCTUnwrap(editor.presentedViewController)
    try await Task.sleep(nanoseconds: 600_000_000)
    screenshot(window, name: "Record undo centered confirmation design16")
    XCTAssertTrue(QFManualPlanTransport.requests.filter { $0.httpMethod == "DELETE" }.isEmpty)
    let deleted = expectation(description: "Record undo completed"); editor.onChanged = { deleted.fulfill() }
    try button("cooking.undo.confirm", in: dialog.view).sendActions(for: .touchUpInside)
    await fulfillment(of: [deleted], timeout: 4)
    let request = try XCTUnwrap(QFManualPlanTransport.requests.first { $0.httpMethod == "DELETE" })
    XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "expectedRevision" }?.value, "3")
    XCTAssertTrue(QFManualPlanTransport.cookingWrites().isEmpty)
  }
  @MainActor func testRecordEditConflictRequiresExplicitReload() async throws {
    let app = try await makeSession(), record = editableRecord()
    let editor = QFCookingRecordDetailViewController(app: app, record: record)
    let window = window(QFNavigationController(rootViewController: editor)); defer { window.isHidden = true; window.rootViewController = nil }
    defer { QFContentDraftStore.remove(app: app, kind: "cooking-edit." + record.id) }
    try await eventually { (try? self.button("cooking.detail.edit", in: editor.view).isEnabled) == true }
    try button("cooking.detail.edit", in: editor.view).sendActions(for: .touchUpInside)
    var latest = record; latest.revision = 4; latest.materials[0].amount = "7"
    let amount = try XCTUnwrap(views(UITextField.self, editor.view).first { $0.accessibilityIdentifier == "cooking.detail.amount.0" })
    amount.text = "3"; amount.sendActions(for: .editingChanged)
    QFManualPlanTransport.storedCooking = try JSONSerialization.jsonObject(with: JSONEncoder().encode(latest)) as? [String: Any]
    QFManualPlanTransport.nextCookingCode = 40900
    try button("cooking.detail.save", in: editor.view).sendActions(for: .touchUpInside)
    try await eventually { editor.presentedViewController is UIAlertController }
    XCTAssertEqual((editor.presentedViewController as? UIAlertController)?.title, app.text("记录已变更", "Record changed"))
    XCTAssertEqual(QFManualPlanTransport.cookingWrites().count, 1)
    XCTAssertEqual(QFContentDraftStore.load(QFCookingRecordEditDraft.self, app: app, kind: "cooking-edit." + record.id)?.baseline.revision, 3)
    editor.dismiss(animated: false)
  }
  @MainActor func testAdjustmentSheetHasFourActionsAndProtectsCompletedMeals() async throws {
    let app = try await makeSession()
    var value = QFManualPlanTransport.planValue()
    value["completed"] = true
    let item = try JSONDecoder().decode(QFPlannedMeal.self, from: JSONSerialization.data(withJSONObject: value))
    let sheet = QFMealActionsViewController(app: app, items: [item]) { _, _ in XCTFail("No action should be submitted") }
    let host = UIViewController()
    let window = window(host); defer { window.isHidden = true; window.rootViewController = nil }
    host.present(sheet, animated: false)
    try await eventually { sheet.view.window != nil }
    XCTAssertFalse(try button("plan.adjust.replace", in: sheet.view).isEnabled)
    XCTAssertFalse(try button("plan.adjust.skip", in: sheet.view).isEnabled)
    XCTAssertTrue(try button("plan.adjust.move", in: sheet.view).isEnabled)
    XCTAssertTrue(try button("plan.adjust.remove", in: sheet.view).isEnabled)
    XCTAssertGreaterThanOrEqual(try button("plan.adjust.remove", in: sheet.view).bounds.height, 44)
    screenshot(window, name: "Adjust meal bottom sheet")
    XCTAssertTrue(QFManualPlanTransport.planWrites().isEmpty)
    host.dismiss(animated: false)
  }

  @MainActor func testMoveDraftDoesNotWriteUntilSaveAndPreservesRecipeAndRevision() async throws {
    let app = try await makeSession()
    let item = try JSONDecoder().decode(QFPlannedMeal.self, from: JSONSerialization.data(withJSONObject: QFManualPlanTransport.planValue()))
    QFContentDraftStore.remove(app: app, kind: "move-plan.test-plan")
    defer { QFContentDraftStore.remove(app: app, kind: "move-plan.test-plan") }
    let saved = expectation(description: "Move saved")
    let editor = QFMovePlanViewController(app: app, item: item) { saved.fulfill() }
    let nav = QFNavigationController(rootViewController: UIViewController())
    let window = window(nav); defer { window.isHidden = true; window.rootViewController = nil }
    nav.pushViewController(editor, animated: false)
    let meal = try XCTUnwrap(views(UISegmentedControl.self, editor.view).first)
    meal.selectedSegmentIndex = 2; meal.sendActions(for: .valueChanged)
    let date = try XCTUnwrap(views(UIDatePicker.self, editor.view).first)
    date.date = QFManualPlanDraft.date("2026-10-02")!; date.sendActions(for: .valueChanged)
    XCTAssertTrue(QFManualPlanTransport.planWrites().isEmpty)
    screenshot(editor.view, name: "Move plan local draft")
    try button("plan.move.save", in: editor.view).sendActions(for: .touchUpInside)
    await fulfillment(of: [saved], timeout: 4)
    let request = try XCTUnwrap(QFManualPlanTransport.planWrites().first)
    let draft = try JSONDecoder().decode(QFPlannedMealDraft.self, from: QFManualPlanTransport.body(request))
    XCTAssertEqual(draft.date, "2026-10-02"); XCTAssertEqual(draft.meal, "DINNER")
    XCTAssertEqual(draft.recipeId, "a"); XCTAssertEqual(draft.expectedRevision, 0)
    XCTAssertEqual(draft.skipped, false)
  }

  @MainActor func testRevisionConflictOnlyRecoversAnExactlyMatchingState() async throws {
    let app = try await makeSession()
    let original = try JSONDecoder().decode(QFPlannedMeal.self, from: JSONSerialization.data(withJSONObject: QFManualPlanTransport.planValue()))
    var draft = original.editDraft; draft.skipped = true
    QFManualPlanTransport.meal["skipped"] = true; QFManualPlanTransport.meal["revision"] = 1
    QFManualPlanTransport.nextPlanCode = 40900
    let replay = try await app.adjustPlannedMeal(original.id, draft: draft)
    XCTAssertTrue(replay.skipped); XCTAssertEqual(replay.revision, 1)
    QFManualPlanTransport.nextPlanCode = 40900
    QFManualPlanTransport.meal["recipeId"] = "changed-by-another-member"
    do {
      _ = try await app.adjustPlannedMeal(original.id, draft: draft)
      XCTFail("Must not overwrite a changed plan")
    } catch let error as QFAPIError { XCTAssertEqual(error.code, 40900) }
    XCTAssertEqual(QFManualPlanTransport.planWrites().count, 2)
  }
}

extension QFManualPlanFlowTests {
  @MainActor private func historyFixture(_ id: Int, date: String = "2026-09-08", cost: String? = "2.50") -> [String: Any] {
    ["id": "history-\(id)", "date": date, "title": "菜品 \(id)", "meal": "LUNCH", "currency": "CNY", "cost": cost as Any? ?? NSNull(), "materials": [], "note": "", "inventoryMode": "NONE", "revision": 0]
  }
  @MainActor private func historyControl(_ id: String, in view: UIView) throws -> UIControl {
    try XCTUnwrap(views(UIControl.self, view).first { $0.accessibilityIdentifier == id })
  }
  @MainActor func testPlanHistoryRequestsDailyPageWithFullMonthSummary() async throws {
    let app = try await makeSession()
    QFManualPlanTransport.historyRecords = [historyFixture(1), historyFixture(2, cost: nil), historyFixture(3, date: "2026-09-07")]
    let controller = QFPlanCookingHistoryViewController(app: app, date: QFManualPlanDraft.date("2026-09-08")!)
    let window = window(QFNavigationController(rootViewController: controller)); defer { window.isHidden = true; window.rootViewController = nil }
    try await eventually { self.views(UILabel.self, controller.view).contains { $0.text == "3" } }
    let reads = QFManualPlanTransport.historyReads(); XCTAssertEqual(reads.count, 1)
    let query = URLComponents(url: reads[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertTrue(query.contains(URLQueryItem(name: "month", value: "2026-09")))
    XCTAssertTrue(query.contains(URLQueryItem(name: "date", value: "2026-09-08")))
    XCTAssertTrue(query.contains(URLQueryItem(name: "page", value: "0")))
    XCTAssertFalse(QFManualPlanTransport.requests.contains { $0.url?.path.hasSuffix("content-summary") == true })
    XCTAssertTrue(views(UILabel.self, controller.view).contains { $0.text == app.text("下厨天数", "Cooking days") })
    XCTAssertTrue(views(UILabel.self, controller.view).contains { $0.text == "2" })
    try await Task.sleep(nanoseconds: 600_000_000)
    screenshot(window, name: "Plan history monthly summary and selected day design08")
  }
  @MainActor func testPlanHistoryUpwardPagingAndPullRefreshUseServerPages() async throws {
    let app = try await makeSession()
    QFManualPlanTransport.historyRecords = (1...25).map { historyFixture($0) }
    let controller = QFPlanCookingHistoryViewController(app: app, date: QFManualPlanDraft.date("2026-09-08")!)
    let window = window(QFNavigationController(rootViewController: controller)); defer { window.isHidden = true; window.rootViewController = nil }
    let list = try XCTUnwrap(views(UITableView.self, controller.view).first { $0.accessibilityIdentifier == "plan.history.list" })
    try await eventually { list.numberOfRows(inSection: 0) == 25 }
    let footer = try XCTUnwrap(list.mj_footer)
    await footer.beginRefreshing()
    try await eventually { list.numberOfRows(inSection: 0) == 30 }
    XCTAssertEqual(QFManualPlanTransport.historyReads().count, 2)
    XCTAssertEqual(URLComponents(url: QFManualPlanTransport.historyReads()[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value, "1")
    let refresh = try XCTUnwrap(list.refreshControl); refresh.beginRefreshing(); refresh.sendActions(for: .valueChanged)
    try await eventually { QFManualPlanTransport.historyReads().count == 3 && !refresh.isRefreshing }
    XCTAssertEqual(list.numberOfRows(inSection: 0), 25)
    XCTAssertEqual(URLComponents(url: QFManualPlanTransport.historyReads()[2].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value, "0")
  }
  @MainActor func testPlanHistoryDaySwitchReusesLocalSnapshot() async throws {
    let app = try await makeSession()
    QFManualPlanTransport.historyRecords = [historyFixture(1), historyFixture(2, date: "2026-09-09")]
    let controller = QFPlanCookingHistoryViewController(app: app, date: QFManualPlanDraft.date("2026-09-08")!)
    let window = window(QFNavigationController(rootViewController: controller)); defer { window.isHidden = true; window.rootViewController = nil }
    try await eventually { self.views(UIControl.self, controller.view).contains { $0.accessibilityIdentifier == "plan.history.record.history-1" } }
    try historyControl("plan.history.date.2026-09-09", in: controller.view).sendActions(for: .touchUpInside)
    try await eventually { self.views(UIControl.self, controller.view).contains { $0.accessibilityIdentifier == "plan.history.record.history-2" } }
    XCTAssertEqual(QFManualPlanTransport.historyReads().count, 2)
    try historyControl("plan.history.date.2026-09-08", in: controller.view).sendActions(for: .touchUpInside)
    try await eventually { self.views(UIControl.self, controller.view).contains { $0.accessibilityIdentifier == "plan.history.record.history-1" } }
    XCTAssertEqual(QFManualPlanTransport.historyReads().count, 2)
  }
  @MainActor func testPlanHistoryInitialFailureHasRetryInsteadOfEmptySuccess() async throws {
    let app = try await makeSession(); QFManualPlanTransport.nextHistoryCode = 50300
    QFManualPlanTransport.historyRecords = [historyFixture(1)]
    let controller = QFPlanCookingHistoryViewController(app: app, date: QFManualPlanDraft.date("2026-09-08")!)
    let window = window(QFNavigationController(rootViewController: controller)); defer { window.isHidden = true; window.rootViewController = nil }
    try await eventually { self.views(UIControl.self, controller.view).contains { $0.accessibilityIdentifier == "plan.history.retry" } }
    XCTAssertFalse(views(UILabel.self, controller.view).contains { $0.text == "0" || $0.text == app.text("这天还没有做菜记录", "No cooking history for this day") })
    try historyControl("plan.history.retry", in: controller.view).sendActions(for: .touchUpInside)
    try await eventually { self.views(UIControl.self, controller.view).contains { $0.accessibilityIdentifier == "plan.history.record.history-1" } }
    XCTAssertEqual(QFManualPlanTransport.historyReads().count, 2)
    let list = try XCTUnwrap(views(UITableView.self, controller.view).first)
    let source = try XCTUnwrap(list.dataSource as? UITableViewDiffableDataSource<Int, String>)
    XCTAssertFalse(source.snapshot().itemIdentifiers.contains("failure"))
    XCTAssertFalse(list.visibleCells.flatMap { self.views(UIControl.self, $0) }.contains { $0.accessibilityIdentifier == "plan.history.retry" })
  }
  @MainActor func testPlanHistoryPaginationDeduplicatesAndKeepsServerTotals() throws {
    let app = try XCTUnwrap(URL(string: "https://example.invalid/api/v1/me/cooking-records?month=2026-09&date=2026-09-08&page=0"))
    QFManualPlanTransport.historyRecords = [historyFixture(1), historyFixture(2)]
    let page = try JSONDecoder().decode(QFCookingHistoryPage.self, from: JSONSerialization.data(withJSONObject: QFManualPlanTransport.historyValue(URLRequest(url: app))))
    var state = QFPlanHistoryDayState(); state.apply(page, at: 0); state.apply(page, at: 1)
    XCTAssertEqual(state.items.count, 2); XCTAssertEqual(state.total, 2)
    XCTAssertEqual(state.summary?.completedCount, 2); XCTAssertEqual(state.summary?.cookingDays, 1)
    XCTAssertFalse(state.hasMore)
  }
  @MainActor func testPlanHistoryReturningFromDetailRefreshesOnlyAfterSave() async throws {
    let app = try await makeSession(), record = editableRecord()
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    QFManualPlanTransport.historyRecords = [value]; QFManualPlanTransport.storedCooking = value
    let controller = QFPlanCookingHistoryViewController(app: app, date: QFManualPlanDraft.date(record.date)!)
    let navigation = QFNavigationController(rootViewController: controller)
    let window = window(navigation); defer { window.isHidden = true; window.rootViewController = nil }
    let identifier = "plan.history.record." + record.id
    try await eventually { self.views(UIControl.self, controller.view).contains { $0.accessibilityIdentifier == identifier } }
    try historyControl(identifier, in: controller.view).sendActions(for: .touchUpInside)
    try await eventually { navigation.topViewController is QFCookingRecordDetailViewController }
    try await Task.sleep(nanoseconds: 600_000_000)
    navigation.popViewController(animated: false)
    XCTAssertEqual(QFManualPlanTransport.historyReads().count, 1)
    try historyControl(identifier, in: controller.view).sendActions(for: .touchUpInside)
    try await eventually { navigation.topViewController is QFCookingRecordDetailViewController }
    let detail = try XCTUnwrap(navigation.topViewController as? QFCookingRecordDetailViewController)
    try await Task.sleep(nanoseconds: 600_000_000)
    try button("cooking.detail.edit", in: detail.view).sendActions(for: .touchUpInside)
    let amount = try XCTUnwrap(views(UITextField.self, detail.view).first { $0.accessibilityIdentifier == "cooking.detail.amount.0" })
    amount.text = "5"; amount.sendActions(for: .editingChanged)
    try button("cooking.detail.save", in: detail.view).sendActions(for: .touchUpInside)
    try await eventually { QFManualPlanTransport.storedCooking?["revision"] as? Int == 4 && self.views(UIButton.self, detail.view).first { $0.accessibilityIdentifier == "cooking.detail.save" }?.isEnabled == true }
    XCTAssertEqual(QFManualPlanTransport.cookingWrites().count, 1)
    navigation.popViewController(animated: false)
    try await eventually { QFManualPlanTransport.historyReads().count == 2 && self.views(UILabel.self, controller.view).contains { $0.text == app.text("成本待补全", "Cost missing") } }
    XCTAssertTrue(views(UILabel.self, controller.view).contains { $0.text == app.text("成本待补全", "Cost missing") })
  }
}

extension QFManualPlanFlowTests {
  @MainActor private func backfillDraft(_ count: Int = 2) -> QFBackfillCookingDraft {
    var draft = QFBackfillCookingDraft(date: "2026-09-08", householdId: nil, language: "zh-Hans")
    draft.items = (0..<count).map { index in
      var record = QFCookingRecord(); record.date = draft.date; record.title = index == 0 ? "番茄炒蛋" : "紫菜蛋花汤"
      record.meal = index == 0 ? "BREAKFAST" : "DINNER"
      record.materials = [.init(name: "紫菜", amount: "2", unit: "g", ingredientId: QFManualPlanTransport.ingredientID)]
      return .init(record: record)
    }; return draft
  }
  private func backfillRequests() -> [URLRequest] {
    QFManualPlanTransport.lock.lock(); defer { QFManualPlanTransport.lock.unlock() }
    return QFManualPlanTransport.requests.filter { $0.url?.path.hasSuffix("cooking-records/batch") == true }
  }
  @MainActor func testBackfillBatchSupportsThirtyDishesAndFreezesOneDateAndReceipt() throws {
    var draft = backfillDraft(30); XCTAssertTrue(draft.prepare())
    let first = try XCTUnwrap(draft.pending)
    XCTAssertEqual(first.items.count, 30); XCTAssertEqual(first.date, "2026-09-08")
    XCTAssertEqual(first.items.first?.meal, "BREAKFAST"); XCTAssertEqual(first.items.last?.meal, "DINNER")
    draft.items[0].record.materials[0].amount = "9"; draft.date = "2026-09-09"
    XCTAssertTrue(draft.prepare()); XCTAssertEqual(draft.pending?.requestId, first.requestId)
    XCTAssertEqual(draft.pending?.items.first?.materials.first?.amount, "2"); XCTAssertEqual(draft.pending?.date, "2026-09-08")
    XCTAssertEqual(try JSONDecoder().decode(QFBackfillCookingDraft.self, from: JSONEncoder().encode(draft)).pending?.requestId, first.requestId)
    var oversized = backfillDraft(31); XCTAssertFalse(oversized.prepare())
    var invalidDate = backfillDraft(); invalidDate.date = "2026-02-31"; XCTAssertFalse(invalidDate.prepare())
    var duplicate = backfillDraft(); duplicate.items[1].record.id = duplicate.items[0].record.id; XCTAssertFalse(duplicate.prepare())
  }
  @MainActor func testBackfillRequiresActualPositiveAmountsAndMappedIngredients() {
    var draft = backfillDraft(1); draft.items[0].record.materials[0].amount = "适量"; XCTAssertFalse(draft.prepare())
    draft.items[0].record.materials[0].amount = "0"; XCTAssertFalse(draft.prepare())
    draft.items[0].record.materials[0].amount = "1"; draft.items[0].record.materials[0].ingredientId = nil; XCTAssertFalse(draft.prepare())
    draft.items[0].record.materials[0].ingredientId = QFManualPlanTransport.ingredientID; XCTAssertTrue(draft.prepare())
  }
  @MainActor func testBackfillDraftStaysLocalThenSendsOneAtomicBatch() async throws {
    let app = try await makeSession(); let key = "backfill.personal.2026-09-08"
    defer { QFContentDraftStore.remove(app: app, kind: key) }
    XCTAssertTrue(QFContentDraftStore.save(backfillDraft(), app: app, kind: key))
    let controller = QFBackfillCookingViewController(app: app, date: "2026-09-08")
    let window = window(QFNavigationController(rootViewController: controller)); defer { window.isHidden = true; window.rootViewController = nil }
    try await eventually { self.views(UITextField.self, controller.view).contains { $0.accessibilityIdentifier == "plan.backfill.amount.0" } }
    try await Task.sleep(nanoseconds: 200_000_000)
    let amount = try XCTUnwrap(views(UITextField.self, controller.view).first { $0.accessibilityIdentifier == "plan.backfill.amount.0" })
    amount.text = "3"; amount.sendActions(for: .editingChanged)
    XCTAssertTrue(backfillRequests().isEmpty); XCTAssertTrue(QFManualPlanTransport.cookingWrites().isEmpty)
    XCTAssertEqual(QFContentDraftStore.load(QFBackfillCookingDraft.self, app: app, kind: key)?.items.first?.record.materials.first?.amount, "3")
    try await Task.sleep(nanoseconds: 500_000_000); screenshot(window, name: "Backfill actual quantities and multiple meals design07")
    let saved = expectation(description: "Batch saved"); controller.onChanged = { saved.fulfill() }
    try button("plan.backfill.save", in: controller.view).sendActions(for: .touchUpInside)
    await fulfillment(of: [saved], timeout: 4)
    XCTAssertEqual(backfillRequests().count, 1)
    let payload = try JSONDecoder().decode(QFCookingBatchRequest.self, from: QFManualPlanTransport.body(try XCTUnwrap(backfillRequests().first)))
    XCTAssertEqual(payload.items.count, 2); XCTAssertEqual(payload.items.first?.materials.first?.amount, "3")
    XCTAssertEqual(payload.items.last?.meal, "DINNER"); XCTAssertEqual(payload.date, "2026-09-08")
    XCTAssertNil(QFContentDraftStore.load(QFBackfillCookingDraft.self, app: app, kind: key))
  }
  @MainActor func testBackfillUncertainResponseRetainsIdenticalBatchForRetry() async throws {
    let app = try await makeSession(); let key = "backfill.personal.2026-09-08"
    defer { QFContentDraftStore.remove(app: app, kind: key) }
    XCTAssertTrue(QFContentDraftStore.save(backfillDraft(), app: app, kind: key)); QFManualPlanTransport.failNextCookingBatch = true
    let controller = QFBackfillCookingViewController(app: app, date: "2026-09-08")
    let window = window(QFNavigationController(rootViewController: controller)); defer { window.isHidden = true; window.rootViewController = nil }
    try await Task.sleep(nanoseconds: 250_000_000)
    try button("plan.backfill.save", in: controller.view).sendActions(for: .touchUpInside)
    try await eventually { self.backfillRequests().count == 1 && controller.footer.isUserInteractionEnabled && self.views(UIButton.self, controller.view).contains { $0.accessibilityIdentifier == "plan.backfill.save" && $0.isEnabled && $0.currentTitle == app.text("重试", "Retry") } }
    XCTAssertNotNil(QFContentDraftStore.load(QFBackfillCookingDraft.self, app: app, kind: key)?.pending)
    let saved = expectation(description: "Retry saved"); controller.onChanged = { saved.fulfill() }
    try button("plan.backfill.save", in: controller.view).sendActions(for: .touchUpInside)
    await fulfillment(of: [saved], timeout: 4)
    let requests = backfillRequests(); XCTAssertEqual(requests.count, 2)
    let first = try JSONSerialization.jsonObject(with: QFManualPlanTransport.body(requests[0])) as? NSDictionary
    let second = try JSONSerialization.jsonObject(with: QFManualPlanTransport.body(requests[1])) as? NSDictionary
    XCTAssertEqual(first, second); XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept-Language"), requests[1].value(forHTTPHeaderField: "Accept-Language"))
  }
  @MainActor func testBackfillStockRejectionKeepsEveryDraftDishAndAllowsCorrection() async throws {
    let app = try await makeSession(); let key = "backfill.personal.2026-09-08"
    defer { QFContentDraftStore.remove(app: app, kind: key) }
    XCTAssertTrue(QFContentDraftStore.save(backfillDraft(), app: app, kind: key)); QFManualPlanTransport.nextCookingBatchCode = 42206
    let controller = QFBackfillCookingViewController(app: app, date: "2026-09-08")
    let window = window(QFNavigationController(rootViewController: controller)); defer { window.isHidden = true; window.rootViewController = nil }
    try await Task.sleep(nanoseconds: 250_000_000)
    try button("plan.backfill.save", in: controller.view).sendActions(for: .touchUpInside)
    try await eventually { self.backfillRequests().count == 1 && QFContentDraftStore.load(QFBackfillCookingDraft.self, app: app, kind: key)?.pending == nil }
    let draft = try XCTUnwrap(QFContentDraftStore.load(QFBackfillCookingDraft.self, app: app, kind: key))
    XCTAssertEqual(draft.items.count, 2); XCTAssertTrue(QFManualPlanTransport.cookingWrites().isEmpty)
    let amount = try XCTUnwrap(views(UITextField.self, controller.view).first { $0.accessibilityIdentifier == "plan.backfill.amount.0" })
    amount.text = "1"; amount.sendActions(for: .editingChanged)
    XCTAssertEqual(QFContentDraftStore.load(QFBackfillCookingDraft.self, app: app, kind: key)?.items.first?.record.materials.first?.amount, "1")
  }
  @MainActor func testBackfillHistoryCostRejectionKeepsDraftAndAllowsCorrection() async throws {
    let app = try await makeSession(); let key = "backfill.personal.2026-09-08"
    defer { QFContentDraftStore.remove(app: app, kind: key) }
    XCTAssertTrue(QFContentDraftStore.save(backfillDraft(), app: app, kind: key)); QFManualPlanTransport.nextCookingBatchCode = 42207
    let controller = QFBackfillCookingViewController(app: app, date: "2026-09-08")
    let window = window(QFNavigationController(rootViewController: controller)); defer { window.isHidden = true; window.rootViewController = nil }
    try await Task.sleep(nanoseconds: 250_000_000)
    try button("plan.backfill.save", in: controller.view).sendActions(for: .touchUpInside)
    try await eventually { self.backfillRequests().count == 1 && QFContentDraftStore.load(QFBackfillCookingDraft.self, app: app, kind: key)?.pending == nil }
    let draft = try XCTUnwrap(QFContentDraftStore.load(QFBackfillCookingDraft.self, app: app, kind: key))
    XCTAssertEqual(draft.items.count, 2); XCTAssertTrue(QFManualPlanTransport.cookingWrites().isEmpty)
    let amount = try XCTUnwrap(views(UITextField.self, controller.view).first { $0.accessibilityIdentifier == "plan.backfill.amount.0" })
    amount.text = "1"; amount.sendActions(for: .editingChanged)
    XCTAssertEqual(QFContentDraftStore.load(QFBackfillCookingDraft.self, app: app, kind: key)?.items.first?.record.materials.first?.amount, "1")
  }
  @MainActor func testBackfillImportsOldDraftWithoutDeletingOtherDates() async throws {
    let app = try await makeSession(); let key = "backfill.personal.2026-09-08", oldKey = "cooking-batch-2026-09-08"
    defer { QFContentDraftStore.remove(app: app, kind: key); QFContentDraftStore.remove(app: app, kind: oldKey) }
    let first = backfillDraft(1).items[0].record; var other = first; other.id = UUID().uuidString.lowercased(); other.date = "2026-09-07"
    XCTAssertTrue(QFContentDraftStore.save([first, other], app: app, kind: oldKey))
    let controller = QFBackfillCookingViewController(app: app, date: "2026-09-08")
    let window = window(QFNavigationController(rootViewController: controller)); defer { window.isHidden = true; window.rootViewController = nil }
    try await Task.sleep(nanoseconds: 250_000_000)
    XCTAssertEqual(QFContentDraftStore.load([QFCookingRecord].self, app: app, kind: oldKey)?.count, 2)
    let saved = expectation(description: "Migrated draft saved"); controller.onChanged = { saved.fulfill() }
    try button("plan.backfill.save", in: controller.view).sendActions(for: .touchUpInside); await fulfillment(of: [saved], timeout: 4)
    XCTAssertEqual(QFContentDraftStore.load([QFCookingRecord].self, app: app, kind: oldKey)?.map(\.id), [other.id])
  }
}


extension QFManualPlanFlowTests {
  @MainActor func testBackfillTenLanguageLayoutsKeepLocalDraftAndVisibleSaveAction() async throws {
    let app = try await makeSession(); let language = app.interfaceLanguage; let key = "backfill.personal.2026-09-08"
    defer { _ = app.setInterfaceLanguage(language); QFContentDraftStore.remove(app: app, kind: key) }
    for code in ["zh-Hans", "zh-Hant", "en", "ja", "ko", "ru", "es", "fr", "de", "pt-BR"] {
      _ = app.setInterfaceLanguage(code)
      var draft = backfillDraft(1); draft.language = code
      draft.items[0].record.title = app.text("做过的菜", "Dish you cooked")
      draft.items[0].record.materials = (0..<3).map { index in
        QFWorkMaterial(name: app.text("食材", "Ingredients") + " \(index + 1)", amount: "2", unit: "g", ingredientId: QFManualPlanTransport.ingredientID)
      }
      XCTAssertTrue(QFContentDraftStore.save(draft, app: app, kind: key))
      let controller = QFBackfillCookingViewController(app: app, date: draft.date)
      let host = window(QFNavigationController(rootViewController: controller))
      try await Task.sleep(nanoseconds: 180_000_000); host.layoutIfNeeded()
      let save = try button("plan.backfill.save", in: controller.view)
      XCTAssertEqual(save.currentTitle, app.text("保存补记", "Save cooking records"), code)
      XCTAssertTrue(save.isEnabled, code)
      let unit = try button("plan.backfill.unit.0", in: controller.view)
      XCTAssertEqual(unit.titleLabel?.numberOfLines, 1, code)
      if !["zh-Hans", "zh-Hant", "ja", "ko"].contains(code) { XCTAssertEqual(unit.currentTitle, "g", code) }
      let frame = save.convert(save.bounds, to: host)
      XCTAssertGreaterThanOrEqual(frame.minY, host.safeAreaInsets.top, code)
      XCTAssertLessThanOrEqual(frame.maxY, host.bounds.height - host.safeAreaInsets.bottom + 1, code)
      XCTAssertEqual(views(UITextField.self, controller.view).filter { $0.accessibilityIdentifier?.hasPrefix("plan.backfill.amount.") == true }.count, 3)
      screenshot(host, name: "Backfill design07 \(code)")
      controller.scrollView.setContentOffset(CGPoint(x: 0, y: max(0, controller.scrollView.contentSize.height - controller.scrollView.bounds.height + controller.scrollView.adjustedContentInset.bottom)), animated: false)
      host.layoutIfNeeded()
      let add = try button("plan.backfill.addDish", in: controller.view)
      let addFrame = add.convert(add.bounds, to: host)
      XCTAssertGreaterThanOrEqual(addFrame.minY, controller.scrollView.convert(controller.scrollView.bounds, to: host).minY - 1, code)
      XCTAssertLessThanOrEqual(addFrame.maxY, frame.minY, code)
      if code == "zh-Hans" || code == "fr" { screenshot(host, name: "Backfill cost and add dish scroll \(code)") }
      XCTAssertTrue(backfillRequests().isEmpty); XCTAssertTrue(QFManualPlanTransport.cookingWrites().isEmpty)
      host.isHidden = true; host.rootViewController = nil
    }
  }
  @MainActor func testBackfillRestoresHouseholdReceiptAndOriginalLanguageAfterReopening() async throws {
    let app = try await makeSession(); let language = app.interfaceLanguage; _ = app.setInterfaceLanguage("en")
    let household = "82000000-0000-0000-0000-000000000099", key = "backfill.82000000-0000-0000-0000-000000000099.2026-09-08"
    defer { _ = app.setInterfaceLanguage(language); QFContentDraftStore.remove(app: app, kind: key) }
    var draft = QFBackfillCookingDraft(date: "2026-09-08", householdId: household, language: "ja")
    draft.items = backfillDraft().items; XCTAssertTrue(draft.prepare())
    XCTAssertTrue(QFContentDraftStore.save(draft, app: app, kind: key))
    let controller = QFBackfillCookingViewController(app: app, date: draft.date, householdID: household)
    let host = window(QFNavigationController(rootViewController: controller)); defer { host.isHidden = true; host.rootViewController = nil }
    XCTAssertEqual(try button("plan.backfill.save", in: controller.view).currentTitle, app.text("重试", "Retry"))
    let saved = expectation(description: "Stored receipt replayed"); controller.onChanged = { saved.fulfill() }
    try button("plan.backfill.save", in: controller.view).sendActions(for: .touchUpInside)
    await fulfillment(of: [saved], timeout: 4)
    let request = try XCTUnwrap(backfillRequests().first)
    let body = try JSONDecoder().decode(QFCookingBatchRequest.self, from: QFManualPlanTransport.body(request))
    XCTAssertEqual(body.requestId, draft.pending?.requestId); XCTAssertEqual(body.householdId, household)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "ja")
  }
  @MainActor func testBackfillPermissionAndAmbiguousRejectionsDoNotDiscardReceipt() async throws {
    let app = try await makeSession(); let key = "backfill.personal.2026-09-08"
    defer { QFContentDraftStore.remove(app: app, kind: key) }
    XCTAssertTrue(QFContentDraftStore.save(backfillDraft(), app: app, kind: key))
    let controller = QFBackfillCookingViewController(app: app, date: "2026-09-08")
    let host = window(QFNavigationController(rootViewController: controller)); defer { host.isHidden = true; host.rootViewController = nil }
    try await Task.sleep(nanoseconds: 200_000_000)
    for (index, code) in [40300, 40900, 42900, 40000].enumerated() {
      QFManualPlanTransport.nextCookingBatchCode = code
      try button("plan.backfill.save", in: controller.view).sendActions(for: .touchUpInside)
      try await eventually { self.backfillRequests().count == index + 1 && controller.footer.isUserInteractionEnabled }
      XCTAssertNotNil(QFContentDraftStore.load(QFBackfillCookingDraft.self, app: app, kind: key)?.pending)
    }
    let requests = try backfillRequests().map { try JSONDecoder().decode(QFCookingBatchRequest.self, from: QFManualPlanTransport.body($0)) }
    XCTAssertEqual(Set(requests.map(\.requestId)).count, 1)
    XCTAssertEqual(requests.count, 4)
  }
  @MainActor func testInventoryEditIsLocalAndSaveOnlyMutatesOneCard() async throws {
    let app = try await makeSession()
    let page = QFIngredientViewController(app: app, preparationDates: ("2026-09-30", "2026-09-30"))
    let host = window(QFNavigationController(rootViewController: page)); defer { host.isHidden = true; host.rootViewController = nil }
    try await eventually { self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.edit.stock-1" } }
    let untouched = try button("inventory.edit.stock-2", in: page.view)
    try button("inventory.edit.stock-1", in: page.view).sendActions(for: .touchUpInside)
    let quantity = try XCTUnwrap(views(UITextField.self, page.view).first { $0.accessibilityIdentifier == "inventory.quantity" })
    let location = try XCTUnwrap(views(UITextField.self, page.view).first { $0.accessibilityIdentifier == "inventory.location" })
    quantity.text = "350"; quantity.sendActions(for: .editingChanged)
    location.text = "冷冻"; location.sendActions(for: .editingChanged)
    XCTAssertEqual(QFManualPlanTransport.inventoryWrites().count, 0)
    XCTAssertEqual(QFContentDraftStore.load(QFInventoryInlineDraft.self, app: app, kind: "inventory-edit.personal")?.quantity, "350")
    let reads = QFManualPlanTransport.requests.filter { $0.url?.path.hasSuffix("/inventory") == true }.count
    page.scrollView.refreshControl?.sendActions(for: .valueChanged)
    try await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertEqual(QFManualPlanTransport.requests.filter { $0.url?.path.hasSuffix("/inventory") == true }.count, reads)
    screenshot(host, name: "Inventory inline editor design05")
    try button("inventory.save", in: page.view).sendActions(for: .touchUpInside)
    try await eventually { self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.edit.stock-1" } }
    let request = try XCTUnwrap(QFManualPlanTransport.inventoryWrites().first)
    let body = try JSONDecoder().decode(QFInventoryEditRequest.self, from: QFManualPlanTransport.body(request))
    XCTAssertEqual(request.httpMethod, "PATCH"); XCTAssertEqual(body.currentQuantity, "350"); XCTAssertEqual(body.expectedRevision, 3); XCTAssertEqual(body.location, "冷冻")
    XCTAssertNil(QFContentDraftStore.load(QFInventoryInlineDraft.self, app: app, kind: "inventory-edit.personal"))
    XCTAssertTrue(try button("inventory.edit.stock-2", in: page.view) === untouched)
    screenshot(host, name: "Inventory stock list design04")
  }

  @MainActor func testInventoryLostResponseRetriesFrozenBodyAndRejectsEditing() async throws {
    let app = try await makeSession(); let page = QFIngredientViewController(app: app)
    let host = window(page); defer { host.isHidden = true; host.rootViewController = nil }
    try await eventually { self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.edit.stock-1" } }
    try button("inventory.edit.stock-1", in: page.view).sendActions(for: .touchUpInside)
    QFManualPlanTransport.failNextInventory = true
    try button("inventory.save", in: page.view).sendActions(for: .touchUpInside)
    try await eventually { QFManualPlanTransport.inventoryWrites().count == 1 && (try? self.button("inventory.save", in: page.view).isEnabled) == true }
    XCTAssertFalse(try XCTUnwrap(views(UITextField.self, page.view).first { $0.accessibilityIdentifier == "inventory.quantity" }).isEnabled)
    let frozen = try XCTUnwrap(QFContentDraftStore.load(QFInventoryInlineDraft.self, app: app, kind: "inventory-edit.personal")?.pendingEdit)
    try button("inventory.save", in: page.view).sendActions(for: .touchUpInside)
    try await eventually { QFManualPlanTransport.inventoryWrites().count == 2 && self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.edit.stock-1" } }
    let requests = QFManualPlanTransport.inventoryWrites()
    XCTAssertEqual(try JSONDecoder().decode(QFInventoryEditRequest.self, from: QFManualPlanTransport.body(requests[0])), frozen)
    XCTAssertEqual(try JSONDecoder().decode(QFInventoryEditRequest.self, from: QFManualPlanTransport.body(requests[1])), frozen)
  }

  @MainActor func testInventoryDeletionRequiresSheetConfirmationAndPreservesOtherRows() async throws {
    let app = try await makeSession(); let page = QFIngredientViewController(app: app, preparationDates: ("2026-09-30", "2026-09-30"))
    let host = window(QFNavigationController(rootViewController: page)); defer { host.isHidden = true; host.rootViewController = nil }
    try await eventually { self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.edit.stock-1" } }
    try button("inventory.edit.stock-1", in: page.view).sendActions(for: .touchUpInside)
    try button("inventory.delete", in: page.view).sendActions(for: .touchUpInside)
    try await eventually { page.presentedViewController?.view.window != nil }
    try await Task.sleep(nanoseconds: 400_000_000)
    screenshot(host, name: "Inventory deletion bottom sheet design06")
    XCTAssertEqual(QFManualPlanTransport.inventoryWrites().count, 0)
    let sheet = try XCTUnwrap(page.presentedViewController)
    try button("inventory.delete.cancel", in: sheet.view).sendActions(for: .touchUpInside)
    try await eventually { page.presentedViewController == nil }
    XCTAssertEqual(QFManualPlanTransport.inventoryWrites().count, 0)
    try button("inventory.delete", in: page.view).sendActions(for: .touchUpInside)
    try await eventually { page.presentedViewController?.view.window != nil }
    try await Task.sleep(nanoseconds: 400_000_000)
    try button("inventory.delete.confirm", in: XCTUnwrap(page.presentedViewController).view).sendActions(for: .touchUpInside)
    try await eventually { QFManualPlanTransport.inventoryWrites().count == 1 && !self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.edit.stock-1" || $0.accessibilityIdentifier == "inventory.save" } }
    let request = try XCTUnwrap(QFManualPlanTransport.inventoryWrites().first)
    XCTAssertEqual(request.httpMethod, "DELETE")
    XCTAssertEqual(try JSONDecoder().decode(QFInventoryArchiveRequest.self, from: QFManualPlanTransport.body(request)).expectedRevision, 3)
    XCTAssertNotNil(try button("inventory.edit.stock-2", in: page.view))
  }

  @MainActor func testInventoryInputValidationAndCancelNeverCallMutationAPI() async throws {
    let app = try await makeSession(); let page = QFIngredientViewController(app: app)
    let host = window(page); defer { host.isHidden = true; host.rootViewController = nil }
    try await eventually { self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.edit.stock-1" } }
    try button("inventory.edit.stock-1", in: page.view).sendActions(for: .touchUpInside)
    let field = try XCTUnwrap(views(UITextField.self, page.view).first { $0.accessibilityIdentifier == "inventory.quantity" })
    field.text = "-1"; field.sendActions(for: .editingChanged)
    try button("inventory.save", in: page.view).sendActions(for: .touchUpInside)
    XCTAssertEqual(QFManualPlanTransport.inventoryWrites().count, 0)
    try button("inventory.cancel", in: page.view).sendActions(for: .touchUpInside)
    XCTAssertNil(QFContentDraftStore.load(QFInventoryInlineDraft.self, app: app, kind: "inventory-edit.personal"))
    XCTAssertEqual(QFManualPlanTransport.inventoryWrites().count, 0)
  }

  @MainActor func testInventoryTenLanguagesKeepFullWidthEditorAndDeleteSheet() async throws {
    let app = try await makeSession(); let original = app.interfaceLanguage
    defer { _ = app.setInterfaceLanguage(original); QFContentDraftStore.remove(app: app, kind: "inventory-edit.personal") }
    for code in ["zh-Hans", "zh-Hant", "en", "ja", "ko", "ru", "es", "fr", "de", "pt-BR"] {
      _ = app.setInterfaceLanguage(code)
      QFContentDraftStore.remove(app: app, kind: "inventory-edit.personal")
      let page = QFIngredientViewController(app: app, preparationDates: ("2026-09-30", "2026-09-30"))
      let host = window(QFNavigationController(rootViewController: page))
      try await eventually { self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.edit.stock-1" } }
      try button("inventory.edit.stock-1", in: page.view).sendActions(for: .touchUpInside)
      host.layoutIfNeeded()
      let card = try XCTUnwrap(views(UIView.self, page.view).first { $0.accessibilityIdentifier == "inventory.editing.stock-1" })
      XCTAssertGreaterThan(card.bounds.width, page.view.bounds.width * 0.8, code)
      let save = try button("inventory.save", in: page.view)
      XCTAssertGreaterThanOrEqual(save.bounds.height, 44, code)
      // MJRefresh finishes state changes asynchronously on the main queue.
      // Capture the settled page, and verify an exhausted list doesn't offer more rows.
      try await eventually { self.views(MJRefreshFooter.self, page.view).contains { $0.state == .noMoreData } }
      screenshot(host, name: "Inventory editor " + code)
      if code == "fr" || code == "ru" {
        try button("inventory.delete", in: page.view).sendActions(for: .touchUpInside)
        try await eventually { page.presentedViewController?.view.window != nil }
        try await Task.sleep(nanoseconds: 400_000_000)
        screenshot(host, name: "Inventory deletion " + code)
        page.dismiss(animated: false)
      }
      host.isHidden = true; host.rootViewController = nil
    }
    XCTAssertEqual(QFManualPlanTransport.inventoryWrites().count, 0)
  }

  @MainActor func testInventoryRevisionConflictNeedsExplicitReloadBeforeNewEdit() async throws {
    let app = try await makeSession(); let page = QFIngredientViewController(app: app)
    let host = window(page); defer { host.isHidden = true; host.rootViewController = nil }
    try await eventually { self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.edit.stock-1" } }
    try button("inventory.edit.stock-1", in: page.view).sendActions(for: .touchUpInside)
    QFManualPlanTransport.nextInventoryCode = 40900
    try button("inventory.save", in: page.view).sendActions(for: .touchUpInside)
    try await eventually { self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.reload" } }
    XCTAssertTrue(try XCTUnwrap(QFContentDraftStore.load(QFInventoryInlineDraft.self, app: app, kind: "inventory-edit.personal")).isFrozen)
    try button("inventory.reload", in: page.view).sendActions(for: .touchUpInside)
    try await eventually { self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.edit.stock-1" } }
    XCTAssertEqual(QFManualPlanTransport.inventoryWrites().count, 1)
    XCTAssertNil(QFContentDraftStore.load(QFInventoryInlineDraft.self, app: app, kind: "inventory-edit.personal"))
  }

  @MainActor func testInventoryForbiddenResponseKeepsReceiptAndRestoredArchiveCanBeRetried() async throws {
    let app = try await makeSession()
    let lot = try JSONDecoder().decode(QFInventoryLot.self, from: JSONSerialization.data(withJSONObject: QFManualPlanTransport.inventoryRows[0]))
    var draft = QFInventoryInlineDraft(lot: lot, language: app.interfaceLanguage)
    draft.pendingArchive = QFInventoryArchiveRequest(expectedRevision: 3, idempotencyKey: UUID().uuidString)
    QFContentDraftStore.save(draft, app: app, kind: "inventory-edit.personal")
    QFManualPlanTransport.inventoryRows[0]["status"] = "ARCHIVED"
    let page = QFIngredientViewController(app: app)
    let host = window(page); defer { host.isHidden = true; host.rootViewController = nil }
    try await eventually { self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.save" } }
    QFManualPlanTransport.nextInventoryCode = 40300
    try button("inventory.save", in: page.view).sendActions(for: .touchUpInside)
    try await eventually { QFManualPlanTransport.inventoryWrites().count == 1 && (try? self.button("inventory.save", in: page.view).isEnabled) == true }
    XCTAssertEqual(QFContentDraftStore.load(QFInventoryInlineDraft.self, app: app, kind: "inventory-edit.personal")?.pendingArchive, draft.pendingArchive)
    try button("inventory.save", in: page.view).sendActions(for: .touchUpInside)
    try await eventually { !self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.save" } }
    let writes = QFManualPlanTransport.inventoryWrites()
    XCTAssertEqual(writes.count, 2)
    XCTAssertEqual(try JSONDecoder().decode(QFInventoryArchiveRequest.self, from: QFManualPlanTransport.body(writes[1])), draft.pendingArchive)
  }

  @MainActor func testInventoryMissingUnsubmittedDraftCanBeCancelled() async throws {
    let app = try await makeSession()
    let lot = try JSONDecoder().decode(QFInventoryLot.self, from: JSONSerialization.data(withJSONObject: QFManualPlanTransport.inventoryRows[0]))
    QFContentDraftStore.save(QFInventoryInlineDraft(lot: lot), app: app, kind: "inventory-edit.personal")
    QFManualPlanTransport.inventoryRows[0]["status"] = "ARCHIVED"
    let page = QFIngredientViewController(app: app)
    let host = window(page); defer { host.isHidden = true; host.rootViewController = nil }
    try await eventually { self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.cancel" } }
    try button("inventory.cancel", in: page.view).sendActions(for: .touchUpInside)
    try await eventually { (try? self.button("ingredient.add", in: page.view).isEnabled) == true }
    XCTAssertNil(QFContentDraftStore.load(QFInventoryInlineDraft.self, app: app, kind: "inventory-edit.personal"))
    XCTAssertEqual(QFManualPlanTransport.inventoryWrites().count, 0)
  }

  @MainActor func testInventoryRecoveryDoesNotHideNextServerPage() async throws {
    let app = try await makeSession()
    QFManualPlanTransport.inventoryRows = (1...22).map { index in var row = QFManualPlanTransport.inventoryValues()[0]; row["id"] = "stock-\(index)"; return row }
    let lot = try JSONDecoder().decode(QFInventoryLot.self, from: JSONSerialization.data(withJSONObject: QFManualPlanTransport.inventoryRows[0]))
    var draft = QFInventoryInlineDraft(lot: lot); draft.pendingArchive = QFInventoryArchiveRequest(expectedRevision: 3, idempotencyKey: UUID().uuidString)
    QFContentDraftStore.save(draft, app: app, kind: "inventory-edit.personal")
    QFManualPlanTransport.inventoryRows[0]["status"] = "ARCHIVED"
    let page = QFIngredientViewController(app: app)
    let host = window(page); defer { host.isHidden = true; host.rootViewController = nil }
    try await eventually { self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.save" } }
    try button("inventory.save", in: page.view).sendActions(for: .touchUpInside)
    try await eventually { QFContentDraftStore.load(QFInventoryInlineDraft.self, app: app, kind: "inventory-edit.personal") == nil }
    try await Task.sleep(nanoseconds: 100_000_000)
    let footer = try XCTUnwrap(page.scrollView.mj_footer)
    await footer.beginRefreshing()
    try await eventually { self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.edit.stock-22" } }
    XCTAssertEqual(self.views(UIButton.self, page.view).filter { $0.accessibilityIdentifier?.hasPrefix("inventory.edit.stock-") == true }.count, 21)
  }

  @MainActor func testInventoryDeleteConfirmationCannotCrossHouseholdContext() async throws {
    let app = try await makeSession(); let page = QFIngredientViewController(app: app)
    let host = window(page); defer { app.setPlanningScope(householdID: nil, householdName: nil); host.isHidden = true; host.rootViewController = nil }
    try await eventually { self.views(UIButton.self, page.view).contains { $0.accessibilityIdentifier == "inventory.edit.stock-1" } }
    try button("inventory.edit.stock-1", in: page.view).sendActions(for: .touchUpInside)
    try button("inventory.delete", in: page.view).sendActions(for: .touchUpInside)
    try await eventually { page.presentedViewController?.view.window != nil }
    let stale = try button("inventory.delete.confirm", in: XCTUnwrap(page.presentedViewController).view)
    app.setPlanningScope(householdID: "80000000-0000-0000-0000-000000000001", householdName: "Family")
    try await eventually { page.presentedViewController == nil }
    stale.sendActions(for: .touchUpInside)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(QFManualPlanTransport.inventoryWrites().count, 0)
  }

}

extension QFManualPlanFlowTests {
  @MainActor private func previewRequest(amount: String = "100", count: Int = 1) -> QFCookingCostPreviewRequest {
    .init(date:"2026-10-06", householdId:nil, items:(0..<count).map { index in
      var record = QFCookingRecord(); record.id = String(format:"91000000-0000-0000-0000-%012d",index + 1)
      record.materials = [.init(name:"番茄",amount:amount,unit:"g",ingredientId:QFManualPlanTransport.ingredientID)]
      return .init(record)
    })
  }
  private func previewRequests() -> [URLRequest] {
    QFManualPlanTransport.requests.filter { $0.url?.path.hasSuffix("cooking-cost-previews") == true }
  }
  @MainActor func testPreviewDebouncesEntireBatchAndKeepsInventoryCache() async throws {
    let app = try await makeSession(), loader = QFCookingCostPreviewLoader(app: app)
    _ = try await app.inventoryLots()
    let reads = QFManualPlanTransport.requests.filter { $0.url?.path.hasSuffix("/inventory") == true }.count
    loader.update(previewRequest(amount:"10",count:2)); loader.update(previewRequest(amount:"20",count:2)); loader.update(previewRequest(amount:"30",count:2))
    try await eventually { loader.result != nil }
    XCTAssertEqual(previewRequests().count,1)
    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with:QFManualPlanTransport.body(previewRequests()[0])) as? [String:Any])
    let rows = try XCTUnwrap(body["items"] as? [[String:Any]])
    XCTAssertEqual(rows.count,2); XCTAssertEqual((rows[0]["materials"] as? [[String:Any]])?.first?["amount"] as? String,"30")
    XCTAssertFalse(loader.result!.reservesInventory)
    _ = try await app.inventoryLots()
    XCTAssertEqual(QFManualPlanTransport.requests.filter { $0.url?.path.hasSuffix("/inventory") == true }.count,reads)
    loader.update(previewRequest(amount:"30",count:2))
    try await Task.sleep(nanoseconds:800_000_000)
    XCTAssertEqual(previewRequests().count,1)
    XCTAssertTrue(QFManualPlanTransport.cookingWrites().isEmpty)
  }
  @MainActor func testPreviewCancelsInvalidDraftAndUsesLanguageHeader() async throws {
    let app = try await makeSession(), loader = QFCookingCostPreviewLoader(app:app)
    loader.update(previewRequest());loader.update(previewRequest(amount:"适量"))
    try await Task.sleep(nanoseconds:800_000_000)
    XCTAssertTrue(previewRequests().isEmpty);XCTAssertNil(loader.result);XCTAssertFalse(loader.loading)
    XCTAssertTrue(app.setInterfaceLanguage("ja"))
    loader.update(previewRequest());try await eventually { loader.result != nil }
    XCTAssertEqual(previewRequests().last?.value(forHTTPHeaderField:"Accept-Language"),"ja")
    loader.update(nil);XCTAssertNil(loader.result)
    _ = app.setInterfaceLanguage("zh-Hans")
  }
  @MainActor func testPreviewUnitPriceKeepsSmallDecimalsAndDoesNotGuessDensity() async throws {
    let app = try await makeSession(), loader = QFCookingCostPreviewLoader(app:app), request = previewRequest()
    loader.update(request);try await eventually { loader.result != nil }
    let units = [QFMeasurementUnit(code:"g",dimension:"MASS",symbol:"g",name:"克",factorToBase:"1",decimalAllowed:true),
      QFMeasurementUnit(code:"kg",dimension:"MASS",symbol:"kg",name:"千克",factorToBase:"1000",decimalAllowed:true),
      QFMeasurementUnit(code:"ml",dimension:"VOLUME",symbol:"ml",name:"毫升",factorToBase:"1",decimalAllowed:true)]
    let row = request.items[0].materials[0]
    XCTAssertTrue(loader.material(row,itemID:request.items[0].id,units:units,unitPrice:true).contains("0.0005"))
    var mass=row;mass.unit="kg";mass.amount="0.1"
    XCTAssertTrue(loader.material(mass,itemID:request.items[0].id,units:units,unitPrice:false).contains("0.05"))
    mass.unit="ml";XCTAssertEqual(loader.material(mass,itemID:request.items[0].id,units:units,unitPrice:false),"—")
  }
  @MainActor func testCompletionPreviewUpdatesCostWithoutReplacingFocusedAmount() async throws {
    let app = try await makeSession(), editor = try completion(app) {}
    let window = window(editor); defer { window.isHidden=true;window.rootViewController=nil }
    try await waitForCompletion(editor)
    try await eventually { self.views(UILabel.self,editor.view).first { $0.accessibilityIdentifier == "plan.complete.cost" }?.text?.contains("1.25") == true }
    let field = try XCTUnwrap(views(UITextField.self,editor.view).first { $0.accessibilityIdentifier == "plan.complete.amount.0" })
    field.becomeFirstResponder();field.text="50";field.sendActions(for:.editingChanged)
    let before=previewRequests().count
    try await eventually { self.previewRequests().count > before && self.views(UILabel.self,editor.view).first { $0.accessibilityIdentifier == "plan.complete.cost" }?.text?.contains("1.25") == true }
    XCTAssertTrue(field.isFirstResponder);XCTAssertEqual(field.text,"50");XCTAssertTrue(field.isDescendant(of:editor.view))
    XCTAssertTrue(QFManualPlanTransport.cookingWrites().isEmpty)
    screenshot(editor.view,name:"Completion server cost preview preserves editing")
  }
}
