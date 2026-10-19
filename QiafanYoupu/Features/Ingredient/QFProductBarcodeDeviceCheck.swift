#if DEBUG
import CoreGraphics
import Foundation
import UIKit

/// Isolated fixture checks plus a separately requested, read-only test-server check.
@MainActor
enum QFProductBarcodeDeviceCheck {
  private static var started = false
  private static var active: Run?
  private static var liveStarted = false

  /// One explicit public product query through the user's existing App session.
  /// Never writes a receipt, inventory, chat, preference or authentication export.
  static func verifyLiveIfRequested(app: QFAppSession) async {
    let args = ProcessInfo.processInfo.arguments
    guard !liveStarted, args.contains("-QFVerifyLiveProductBarcode"),
      let index = args.firstIndex(of: "-QFCheckRun"), args.indices.contains(index + 1),
      let id = UUID(uuidString: args[index + 1]) else { return }
    liveStarted = true
    let began = ProcessInfo.processInfo.systemUptime
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("product-barcode-live-" + id.uuidString.lowercased() + ".json")
    var result: [String: Any] = ["runID": id.uuidString.lowercased(), "status": "STARTED", "businessWrites": 0]
    func save() {
      if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
        try? data.write(to: url, options: .atomic)
      }
    }
    save()
    do {
      guard app.api.environment.baseURL?.host == "test-api.yzsalingo.com", app.user != nil else {
        throw Failure("Requires the approved test environment and an existing signed-in session")
      }
      let scope = QFAssistantAgent.scope(app)
      let reply: QFBarcodeProductInfo.ServerResult = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.contentRequest(path: "me/product-barcodes/6925303723934")
      }
      try Task.checkCancellation()
      guard QFAssistantAgent.scope(app) == scope,
        let info = reply.metadata(for: "6925303723934"),
        let barcode = QFProductBarcode(value: "6925303723934", symbology: "EAN13") else {
        throw Failure("Live response or account binding did not match")
      }
      let line = QFPurchaseReceiptLine.scannedProduct(barcode: barcode, info: info)
      let assertions = ["domesticSource": info.source == "JISU_ALIYUN",
        "productName": info.name?.contains("统一") == true,
        "oneBottle": line.quantity == "1" && line.unitCode == "bottle",
        "oneLitrePerBottle": line.packageSize == "1" && line.packageContentUnit == "l",
        "sourcePriceIsNotPaidAmount": info.referencePrice != nil && line.lineAmount == nil]
      result["assertions"] = assertions
      result["status"] = assertions.values.allSatisfy { $0 } ? "LIVE_PRODUCT_BARCODE_VERIFIED" : "FAILED"
      result["productName"] = info.name; result["packageType"] = info.packageType
      result["netContent"] = line.packageSize; result["netContentUnit"] = line.packageContentUnit
      result["referencePrice"] = info.referencePrice
    } catch {
      result["status"] = error is CancellationError ? "CANCELLED" : "FAILED"
      // Deliberately exclude errors/headers that might contain private session data.
      result["errorType"] = String(describing: type(of: error))
    }
    result["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
    save()
  }

  static func startIfRequested() {
    let arguments = ProcessInfo.processInfo.arguments
    guard !started, arguments.contains("-QFVerifyProductBarcode"),
      let index = arguments.firstIndex(of: "-QFCheckRun"), arguments.indices.contains(index + 1),
      let id = UUID(uuidString: arguments[index + 1]) else { return }
    started = true
    let run = Run(id: id)
    active = run
    save(run)
    run.watchdog = Task {
      do { try await Task.sleep(nanoseconds: 18_000_000_000) } catch { return }
      guard active === run else { return }
      finish(run, status: "TIMED_OUT", error: "18 second orchestration deadline reached")
    }
    run.task = Task { await perform(run) }
  }

  static func cancel() {
    guard let run = active else { return }
    finish(run, status: "CANCELLED", error: "Explicit cancellation")
  }

  private static func perform(_ run: Run) async {
    do {
      let imageTask = Task.detached(priority: .utility) { () throws -> Bool in
        try Task.checkCancellation()
        let image = try ean13Fixture()
        let codes = try QFProductBarcodeImageDecoder.barcodes(in: image)
        try Task.checkCancellation()
        return codes.contains { $0.value == "3017620422003" && $0.symbology == "EAN13" }
      }
      run.imageTask = imageTask
      let decoded = try await imageTask.value
      run.imageTask = nil
      try check(run)
      try require(decoded, "publicEAN13ImageDecoded", run)

      let keychain = QFKeychainStore(service: run.service)
      let tokens = QFSessionTokens(accessToken: try QFCredentials.generate(), accessTokenExpiresIn: 3600,
        refreshToken: try QFCredentials.generate(), refreshTokenExpiresIn: 7200)
      let profile = QFUserProfile(userId: run.userID, systemAccount: "barcode-check", boundAccount: nil,
        accountNameBound: false, passwordConfigured: false, nickname: "Barcode Check", avatarUrl: nil,
        countryCode: nil, regionCode: nil, bio: nil, appleBound: false)
      try keychain.write(JSONEncoder().encode(StoredSession(tokens: tokens,
        accessExpiresAt: Date().addingTimeInterval(3600), refreshExpiresAt: Date().addingTimeInterval(7200),
        user: profile)), account: "current")
      let network = try Network(host: run.host, profile: profile)
      run.network = network
      FixtureProtocol.install(network)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [FixtureProtocol.self]
      let identity = QFDeviceIdentity(service: run.service)
      let api = QFAPIClient(environment: .init(name: run.environment,
        baseURL: URL(string: "https://\(run.host)/api/v1")), identity: identity,
        transportConfiguration: configuration)
      api.recordsRequests = false
      let app = QFAppSession(api: api, identity: identity, keychain: keychain)
      run.app = app
      _ = app.setInterfaceLanguage("en") // In-memory only; no settings or user preference writes.
      await app.start()
      try check(run)
      try require(app.user?.userId == run.userID, "isolatedUserRestored", run)
      try require(app.api.environment.name == run.environment && app.api.environment.baseURL?.host == run.host,
        "isolatedEnvironmentBound", run)
      let units = try await app.measurementUnits()
      try check(run)
      try require(units.contains { $0.code == "piece" }, "mockMeasurementUnitsRead", run)

      var scene: UIWindowScene?
      while scene == nil {
        try check(run)
        scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
          .first { $0.activationState == .foregroundActive }
        if scene == nil { try await Task.sleep(nanoseconds: 100_000_000) }
      }
      guard let scene else { throw Failure("No foreground window scene") }
      run.previousWindow = scene.windows.first { $0.isKeyWindow }
      run.previousResponder = run.previousWindow.flatMap { firstResponder(in: $0) }
      guard let barcode = QFProductBarcode(value: "3017620422003", symbology: "EAN13") else {
        throw Failure("Public EAN13 fixture did not pass validation")
      }
      let productLookup = QFBarcodeProductLookup(configuration: configuration)
      let metadata = try await productLookup.product(for: barcode, language: "en")
      _ = try await productLookup.product(for: barcode, language: "en")
      try require(network.summary().reads["/api/v3/product/3017620422003"] == 1, "lookupCacheAvoidsDuplicateRequest", run)
      _ = try await productLookup.product(for: barcode, language: "en", refresh: true)
      try require(network.summary().reads["/api/v3/product/3017620422003"] == 2, "explicitRetryBypassesCache", run)
      let line = QFPurchaseReceiptLine.scannedProduct(barcode: barcode, info: metadata)
      let imported = QFReceiptImport(date: "2026-10-17", currency: "CNY", sellerID: nil,
        invoiceTotal: nil, lines: [line])
      // The UUID household makes even the draft kind distinct from receipt.personal.new.
      let controller = QFPurchaseReceiptViewController(app: app, householdID: run.householdID, imported: imported)
      let navigation = UINavigationController(rootViewController: controller)
      let window = UIWindow(windowScene: scene)
      run.window = window; run.navigation = navigation
      window.frame = scene.coordinateSpace.bounds
      window.windowLevel = .normal + 1
      window.rootViewController = navigation
      window.makeKeyAndVisible()
      controller.loadViewIfNeeded(); window.layoutIfNeeded()
      try await Task.sleep(nanoseconds: 150_000_000)
      try check(run)
      guard let field = descendant(in: controller.view, id: "purchase.name." + line.id) as? UITextField else {
        throw Failure("Product name UITextField missing")
      }
      try require(field.text == "Nutella", "metadataNamePrefilled", run)
      let netContent = descendant(in: controller.view, id: "purchase.net-content." + line.id) as? UILabel
      try require(netContent == nil, "purchaseCardKeepsOnlyEditablePurchaseFields", run)
      try require(field.isEnabled && field.isUserInteractionEnabled && field.window === window,
        "productNameFieldEnabled", run)
      try require(field.becomeFirstResponder(), "productNameFieldAcceptsEditing", run)
      field.text = "Renamed public barcode fixture"
      field.sendActions(for: .editingChanged)
      field.resignFirstResponder()
      guard let draft = QFContentDraftStore.load(QFPurchaseReceiptDraft.self, app: app, kind: run.draftKind),
        let savedLine = draft.items.first, draft.items.count == 1 else { throw Failure("Isolated draft not saved") }
      try require(draft.householdId == run.householdID && savedLine.id == line.id,
        "onlyIsolatedDraftRead", run)
      try require(savedLine.name == "Renamed public barcode fixture", "editingChangedPersistsName", run)
      try require(savedLine.quantity == "1" && savedLine.lineAmount == nil && savedLine.ingredientId == nil,
        "defaultQuantityNoPriceOrIngredientGuess", run)
      try require(savedLine.scanBarcode == "3017620422003", "barcodePreservedInDraft", run)
      try require(savedLine.packageSize == "400" && savedLine.packageContentUnit == "g"
        && savedLine.quantity == "1" && savedLine.unitCode == "pack", "netContentsSeparateFromPurchaseCount", run)
      try require(descendant(in: controller.view, id: "purchase.scan-product") is UIButton,
        "productScanEntryExists", run)
      let drinkBarcode = QFProductBarcode(value: "6925303723934", symbology: "EAN13")!
      let beforeActivation = try await productLookup.product(for: drinkBarcode, language: "en", app: app)
      try require(beforeActivation == nil, "disabledDomesticAndOffMissHandled", run)
      let drinkLine = QFPurchaseReceiptLine.scannedProduct(barcode: drinkBarcode, lookupState: .loading)
      controller.appendScannedProduct(drinkLine)
      let drinkName = descendant(in: controller.view, id: "purchase.name." + drinkLine.id) as? UITextField
      try require(drinkName != nil && drinkName?.text == "", "purchaseFormAvailableBeforeNetworkCompletes", run)
      let paid = descendant(in: controller.view, id: "purchase.amount." + drinkLine.id) as? UITextField
      try require(paid?.text == "", "purchasePriceStartsUnknown", run)
      paid?.text = "4"; paid?.sendActions(for: .editingChanged)
      try await Task.sleep(nanoseconds: 200_000_000); try check(run)
      let drinkContent = descendant(in: controller.view, id: "purchase.net-content." + drinkLine.id) as? UILabel
      let drinkPrice = descendant(in: controller.view, id: "purchase.reference-price." + drinkLine.id) as? UILabel
      try require(drinkName?.text == "统一绿茶 茉莉味茶饮料", "domesticBackendNameVisible", run)
      try require(drinkContent == nil && drinkPrice == nil, "sourcePriceAndPackageDetailsNotShown", run)
      let drinkDraft = QFContentDraftStore.load(QFPurchaseReceiptDraft.self, app: app, kind: run.draftKind)
      let storedDrink = drinkDraft?.items.first { $0.id == drinkLine.id }
      try require(storedDrink?.unitCode == "bottle" && storedDrink?.quantity == "1" && storedDrink?.lineAmount == "4",
        "oneBottleKeepsIndependentlyEditedFourYuanPrice", run)
      try require(storedDrink?.packageSize == "1" && storedDrink?.packageContentUnit == "l" && storedDrink?.location == "fridge",
        "sourceSpecificationKeptBehindSimpleForm", run)
      try require((descendant(in: controller.view, id: "purchase.receipt.save") as? UIButton)?.title(for: .normal) == "Save to fridge",
        "primaryActionSavesToFridge", run)
      try require(network.summary().reads["/api/v1/me/product-barcodes/6925303723934"] == 2,
        "domesticActivationNotHiddenByOldOffMiss", run)
      let unavailable = QFProductBarcode(value: "4006381333931", symbology: "EAN13")!
      let absent = try await productLookup.product(for: unavailable, language: "en")
      try require(absent == nil, "realLookupClassHandles404AsUnlisted", run)
      let missingLine = QFPurchaseReceiptLine.scannedProduct(barcode: unavailable, lookupState: .notFound)
      controller.appendScannedProduct(missingLine)
      let status = descendant(in: controller.view, id: "purchase.barcode-status." + missingLine.id) as? UILabel
      try require(status?.text?.contains("Product name not found") == true, "unlistedProductExplained", run)
      let missingContent = descendant(in: controller.view, id: "purchase.net-content." + missingLine.id) as? UILabel
      try require(missingContent == nil, "unknownPackageDoesNotAddExtraFields", run)
      try require(descendant(in: controller.view, id: "purchase.barcode-retry." + missingLine.id) is UIButton,
        "onlineRetryAvailable", run)
      let summary = network.summary()
      try require(summary.blockedWrites == 0 && summary.unexpected == 0, "noWriteOrUnexpectedRequest", run)
      finish(run, status: "PRODUCT_BARCODE_CHECK_COMPLETED")
    } catch {
      guard active === run else { return } // Cancelled/timed-out runs cannot publish a late success.
      finish(run, status: error is CancellationError ? "CANCELLED" : "FAILED", error: String(describing: error))
    }
  }

  private static func check(_ run: Run) throws {
    try Task.checkCancellation()
    guard active === run, ProcessInfo.processInfo.systemUptime - run.startedAt < 18 else {
      throw Failure("Run binding or deadline expired")
    }
  }
  private static func require(_ condition: Bool, _ name: String, _ run: Run) throws {
    run.assertions[name] = condition
    if !condition { throw Failure(name) }
  }
  private static func descendant(in view: UIView, id: String) -> UIView? {
    if view.accessibilityIdentifier == id { return view }
    for child in view.subviews { if let found = descendant(in: child, id: id) { return found } }
    return nil
  }
  private static func firstResponder(in view: UIView) -> UIResponder? {
    if view.isFirstResponder { return view }
    for child in view.subviews { if let found = firstResponder(in: child) { return found } }
    return nil
  }

  private static func finish(_ run: Run, status: String, error: String? = nil) {
    guard active === run else { return }
    active = nil
    run.task?.cancel(); run.task = nil
    run.watchdog?.cancel(); run.watchdog = nil
    let visionStillFinishing = run.imageTask != nil
    run.imageTask?.cancel(); run.imageTask = nil
    let ownedWindow = run.window
    let ownedWasKey = ownedWindow?.isKeyWindow == true
    run.window?.endEditing(true)
    run.navigation?.setViewControllers([], animated: false)
    run.window?.isHidden = true; run.window?.rootViewController = nil
    run.navigation = nil; run.window = nil
    if ownedWasKey, let previous = run.previousWindow, previous.windowScene?.activationState == .foregroundActive {
      previous.makeKey()
      _ = run.previousResponder?.becomeFirstResponder()
    }
    run.assertions["ownedWindowClosed"] = ownedWindow.map { $0.isHidden && $0.rootViewController == nil } ?? true
    // Exact UUID keys only. No removeAll, logout, global cache or preference clearing.
    UserDefaults.standard.removeObject(forKey: run.draftStorageKey)
    run.assertions["ownedDraftRemoved"] = UserDefaults.standard.object(forKey: run.draftStorageKey) == nil
    var cleanupErrors: [String] = []
    let keychain = QFKeychainStore(service: run.service)
    for account in ["device-id", "current"] {
      do {
        try keychain.remove(account)
        if try keychain.read(account) != nil { cleanupErrors.append(account + " remains") }
      } catch { cleanupErrors.append(account + " cleanup failed") }
    }
    run.assertions["privateKeychainRemoved"] = cleanupErrors.isEmpty
    FixtureProtocol.uninstall(run.network)
    run.app = nil // Releases only this isolated session and its in-memory response cache.
    run.report["status"] = cleanupErrors.isEmpty ? status : "FAILED_CLEANUP"
    run.report["error"] = error
    run.report["cleanupErrors"] = cleanupErrors
    run.report["visionWorkerMayFinishCurrentRequest"] = visionStillFinishing
    run.report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - run.startedAt
    save(run)
  }
  private static func save(_ run: Run) {
    run.report["assertions"] = run.assertions
    if let summary = run.network?.summary() {
      run.report["mockGETRequests"] = summary.reads
      run.report["blockedWriteAttempts"] = summary.blockedWrites
      run.report["unexpectedRequests"] = summary.unexpected
    }
    do {
      let data = try JSONSerialization.data(withJSONObject: run.report, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: run.reportURL, options: .atomic)
    } catch { print("PRODUCT_BARCODE_CHECK_REPORT_WRITE_FAILED") }
  }

  private struct StoredSession: Encodable {
    let tokens: QFSessionTokens
    let accessExpiresAt: Date
    let refreshExpiresAt: Date
    let user: QFUserProfile
  }
  private struct Failure: Error, CustomStringConvertible, Sendable {
    let description: String
    init(_ value: String) { description = value }
  }
  @MainActor private final class Run {
    let userID = UUID().uuidString.lowercased()
    let householdID = UUID().uuidString.lowercased()
    let nonce = UUID().uuidString.lowercased()
    let startedAt = ProcessInfo.processInfo.systemUptime
    var environment: String { "barcode-check-" + nonce }
    var host: String { "barcode-check-" + nonce + ".invalid" }
    var service: String { "com.talka.qiafanyoupu.debug.barcode." + nonce }
    var draftKind: String { "receipt." + householdID + ".new" }
    var draftStorageKey: String { "qf.profile.draft.\(environment).\(userID).\(draftKind)" }
    let reportURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("product-barcode-check.json")
    var task: Task<Void, Never>?
    var watchdog: Task<Void, Never>?
    var imageTask: Task<Bool, Error>?
    var app: QFAppSession?
    var network: Network?
    var window: UIWindow?
    var navigation: UINavigationController?
    weak var previousWindow: UIWindow?
    weak var previousResponder: UIResponder?
    var assertions: [String: Bool] = [:]
    var report: [String: Any]
    init(id: UUID) {
      report = ["runID": id.uuidString.lowercased(), "status": "IN_PROGRESS",
        "createdAt": ISO8601DateFormatter().string(from: Date()), "checkKind": "ISOLATED_PRODUCT_BARCODE_UI",
        "cloudModelCalls": 0, "businessWrites": 0, "externalNetworkRequests": 0, "networkScope": "THIS_CHECK_ONLY",
        "cameraPackagingSample": "NOT_RUN_NO_PHYSICAL_SAMPLE", "deadlineSeconds": 18]
      report["ownedDraftKey"] = draftStorageKey
      report["privateKeychainService"] = service
    }
  }

  /// Standard EAN-13 modules, rendered with integer pixels and generous quiet zones.
  /// This public fixture does not contain a receipt, account or purchase information.
  nonisolated private static func ean13Fixture() throws -> UIImage {
    let left = ["0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011"]
    let even = ["0100111", "0110011", "0011011", "0100001", "0011101", "0111001", "0000101", "0010001", "0001001", "0010111"]
    let right = ["1110010", "1100110", "1101100", "1000010", "1011100", "1001110", "1010000", "1000100", "1001000", "1110100"]
    let digits = [3, 0, 1, 7, 6, 2, 0, 4, 2, 2, 0, 0, 3]
    let parity = Array("LLGGGL") // Leading digit 3.
    var bits = "101"
    for i in 0..<6 { bits += parity[i] == "L" ? left[digits[i + 1]] : even[digits[i + 1]] }
    bits += "01010"
    for digit in digits[7...12] { bits += right[digit] }
    bits += "101"
    let module = 6, quiet = 12, height = 240
    let width = (bits.count + quiet * 2) * module
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
      throw Failure("EAN13 bitmap context unavailable")
    }
    context.setShouldAntialias(false)
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    context.setFillColor(gray: 0, alpha: 1)
    for (index, bit) in bits.enumerated() where bit == "1" {
      context.fill(CGRect(x: CGFloat((quiet + index) * module), y: 20,
        width: CGFloat(module), height: CGFloat(height - 40)))
    }
    guard let image = context.makeImage() else { throw Failure("EAN13 bitmap unavailable") }
    return UIImage(cgImage: image)
  }
}

/// Bound only to the check's URLSessionConfiguration, never globally registered.
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  private static var network: Network?
  static func install(_ value: Network) { lock.lock(); network = value; lock.unlock() }
  static func uninstall(_ value: Network?) {
    lock.lock(); defer { lock.unlock() }
    if network === value { network = nil }
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock(); let network = Self.network; Self.lock.unlock()
    guard let network, let data = network.response(for: request), let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: network.statusCode(for: request), httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]) else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {} // Fixture delivery is synchronous; no worker or socket exists.
}

private final class Network: @unchecked Sendable {
  private let lock = NSLock()
  private let host: String
  private let payloads: [String: Data]
  private var reads: [String: Int] = [:]
  private var blockedWrites = 0
  private var unexpected = 0
  init(host: String, profile: QFUserProfile) throws {
    self.host = host
    func envelope(_ value: Any) throws -> Data {
      try JSONSerialization.data(withJSONObject: ["code": 0, "message": "fixture", "data": value])
    }
    let profileJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
    payloads = [
      "/api/v1/app/config": try envelope(["appName": "Barcode Check", "serviceRegion": "CN",
        "loginMethods": ["quick": false, "apple": false],
        "agreements": ["userAgreement": "Fixture", "privacyPolicy": "Fixture"]]),
      "/api/v1/me": try envelope(profileJSON),
      "/api/v1/me/settings": try envelope(["theme": "SYSTEM", "planReminders": false, "workAndContributionUpdates": false]),
      "/api/v1/measurement-units": try envelope([["code": "piece", "dimension": "COUNT", "symbol": "piece",
        "name": "piece", "factorToBase": "1", "decimalAllowed": false]]),
      "/api/v1/me/product-barcodes/6925303723934": try envelope(["status": "FOUND", "product": [
        "barcode": "6925303723934", "name": "统一绿茶 茉莉味茶饮料", "packageLabel": "1000毫升 · 1(升) · 瓶装",
        "netContent": ["value": "1", "unit": "l"], "referencePrice": "￥40.00", "packageType": "瓶装",
        "packageUnit": "bottle", "source": "JISU_ALIYUN"]]),
    ]
  }
  func response(for request: URLRequest) -> Data? {
    lock.lock(); defer { lock.unlock() }
    guard request.httpMethod == "GET" else { blockedWrites += 1; return nil }
    if let url = request.url, url.scheme == "https", url.host == "world.openfoodfacts.org" {
      let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let fields = Set((params.first { $0.name == "fields" }?.value ?? "").split(separator: ",").map(String.init))
      guard request.value(forHTTPHeaderField: "Authorization") == nil,
        request.value(forHTTPHeaderField: "Device-Id") == nil,
        fields.isSuperset(of: ["code", "product_name", "quantity", "product_quantity", "product_quantity_unit"]),
        url.user == nil, url.password == nil else { unexpected += 1; return nil }
      reads[url.path, default: 0] += 1
      if url.path == "/api/v3/product/3017620422003" {
        return Data(#"{"status":"success","product":{"code":"3017620422003","product_name":"Nutella","quantity":"400 g e","product_quantity":400,"product_quantity_unit":"g"}}"#.utf8)
      }
      if url.path == "/api/v3/product/4006381333931" {
        return Data(#"{"code":"4006381333931","status":"failure","result":{"id":"product_not_found"}}"#.utf8)
      }
      if url.path == "/api/v3/product/6925303723934" {
        return Data(#"{"code":"6925303723934","status":"failure","result":{"id":"product_not_found"}}"#.utf8)
      }
      unexpected += 1; return nil
    }
    guard let url = request.url, url.scheme == "https", url.host == host, url.user == nil,
      url.password == nil, let data = payloads[url.path] else { unexpected += 1; return nil }
    if url.path.hasPrefix("/api/v1/me/product-barcodes/") {
      guard request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true,
        request.value(forHTTPHeaderField: "Device-Id") != nil,
        request.value(forHTTPHeaderField: "Accept-Language") == "en" else { unexpected += 1; return nil }
    }
    reads[url.path, default: 0] += 1
    if url.path == "/api/v1/me/product-barcodes/6925303723934", reads[url.path] == 1 {
      return Data(#"{"code":0,"message":"fixture","data":{"status":"DISABLED","product":null}}"#.utf8)
    }
    return data
  }
  func statusCode(for request: URLRequest) -> Int {
    request.url?.host == "world.openfoodfacts.org"
      && ["/api/v3/product/4006381333931", "/api/v3/product/6925303723934"].contains(request.url?.path ?? "") ? 404 : 200
  }
  func summary() -> (reads: [String: Int], blockedWrites: Int, unexpected: Int) {
    lock.lock(); defer { lock.unlock() }
    return (reads, blockedWrites, unexpected)
  }
}
#endif
