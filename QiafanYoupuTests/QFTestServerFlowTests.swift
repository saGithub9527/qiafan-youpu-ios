import XCTest
import UIKit
@testable import QiafanYoupu

/// Explicit opt-in; this only uses the named TEST service and its own persistent test identity.
final class QFTestServerFlowTests: XCTestCase {
  private struct FavoriteState: Decodable { let saved: Bool }

  private static var liveNetworkEnabled: Bool {
#if QF_LIVE_NETWORK
    true
#else
    ProcessInfo.processInfo.environment["QF_LIVE_NETWORK"] == "1"
#endif
  }

  @MainActor func testRealTestServerInterestPreferenceRestore() async throws {
    try XCTSkipUnless(Self.liveNetworkEnabled,
                      "Real-network check requires explicit opt-in")
    let service = "com.talka.acceptance.v46.20261006"
    let identity = QFDeviceIdentity(service: service)
    let api = QFAPIClient(
      environment: .init(name: "acceptance-v46", baseURL: URL(string: "https://test-api.yzsalingo.com/api/v1")),
      identity: identity)
    api.recordsRequests = false
    let app = QFAppSession(api: api, identity: identity, keychain: QFKeychainStore(service: service))
    await app.start()
    try await app.login(agreementAccepted: true)
    let original: QFInterests = try await app.contentRequest(path: "me/interests")
    do {
      let options: QFInterestOptions = try await app.contentRequest(path: "profile/options")
      let taste = try XCTUnwrap(options.tastes.first?.id)
      var draft = original
      if draft.tasteIds.contains(taste) { draft.tasteIds.removeAll { $0 == taste } }
      else { draft.tasteIds.append(taste) }
      let saved: QFInterests = try await app.contentRequest(
        path: "me/interests", method: "PUT", body: JSONEncoder().encode(draft))
      XCTAssertEqual(saved.tasteIds.contains(taste), draft.tasteIds.contains(taste))
      let reread: QFInterests = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.contentRequest(path: "me/interests")
      }
      XCTAssertEqual(reread.tasteIds.contains(taste), draft.tasteIds.contains(taste))
      let _: QFInterests = try await app.contentRequest(
        path: "me/interests", method: "PUT", body: JSONEncoder().encode(original))
      let restored: QFInterests = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.contentRequest(path: "me/interests")
      }
      XCTAssertEqual(restored, original)
      try await app.logout()
    } catch {
      let _: QFInterests? = try? await app.contentRequest(
        path: "me/interests", method: "PUT", body: JSONEncoder().encode(original))
      try? await app.logout()
      throw error
    }
  }

  /// Local photo stays in the draft until submission, then the test work enters
  /// moderation and is deleted from the isolated account after readback.
  @MainActor func testRealTestServerWorkSubmissionAndModerationCleanup() async throws {
    try XCTSkipUnless(Self.liveNetworkEnabled,
                      "Real-network check requires explicit opt-in")
    let service = "com.talka.acceptance.v46.20261006"
    let identity = QFDeviceIdentity(service: service)
    let api = QFAPIClient(
      environment: .init(name: "acceptance-v46", baseURL: URL(string: "https://test-api.yzsalingo.com/api/v1")),
      identity: identity)
    api.recordsRequests = false
    let app = QFAppSession(api: api, identity: identity, keychain: QFKeychainStore(service: service))
    await app.start()
    try await app.login(agreementAccepted: true)
    let workID = UUID().uuidString.lowercased()
    let photo = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).jpegData(
      withCompressionQuality: 0.8) { context in
        UIColor.systemOrange.setFill()
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        ("TEST" as NSString).draw(
          at: CGPoint(x: 24, y: 48), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 30)])
      }
    let local = try QFLocalMediaStore.save(photo, video: false, scope: app.contentScope)
    defer { QFLocalMediaStore.remove(local.id, scope: app.contentScope) }
    var submitted = false
    do {
      XCTAssertNil(try QFLocalMediaStore.file(local.id, scope: app.contentScope).uploadedID)
      var material = QFWorkMaterial()
      material.name = "测试食材"; material.amount = "1"; material.unit = "克"
      var step = QFWorkStep()
      step.title = "测试步骤"; step.body = "仅验证提交和审核状态"
      var draft = QFWorkDraft()
      draft.title = "自动化测试作品（立即删除）"
      draft.body = "仅用于测试服验收"
      draft.photoIds = [local.id]
      draft.materials = [material]
      draft.steps = [step]
      XCTAssertNil(draft.validation)
      let uploaded = try await app.uploadedMediaID(local.id)
      draft.photoIds = [uploaded]
      let published: QFUserWork = try await app.contentRequest(
        path: "me/works/\(workID)/publish", method: "POST", body: JSONEncoder().encode(draft))
      submitted = true
      XCTAssertEqual(published.status, "PENDING")
      let pending: QFContentPage<QFUserWork> = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.contentRequest(path: "me/works", query: ["status": "PENDING", "page": "0"])
      }
      XCTAssertTrue(pending.items.contains { $0.id == workID })
      try await app.contentMutation(path: "me/works/\(workID)", method: "DELETE")
      submitted = false
      let after: QFContentPage<QFUserWork> = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.contentRequest(path: "me/works", query: ["status": "PENDING", "page": "0"])
      }
      XCTAssertFalse(after.items.contains { $0.id == workID })
      try await app.logout()
    } catch {
      if submitted { try? await app.contentMutation(path: "me/works/\(workID)", method: "DELETE") }
      try? await app.logout()
      throw error
    }
  }

  /// Read/write/readback checks on the physical device; restore both server values.
  @MainActor func testRealTestServerSettingsAndRecipeFavoriteRestore() async throws {
    try XCTSkipUnless(Self.liveNetworkEnabled,
                      "Real-network check requires explicit opt-in")
    let service = "com.talka.acceptance.v46.20261006"
    let identity = QFDeviceIdentity(service: service)
    let api = QFAPIClient(
      environment: .init(name: "acceptance-v46", baseURL: URL(string: "https://test-api.yzsalingo.com/api/v1")),
      identity: identity)
    api.recordsRequests = false
    let app = QFAppSession(api: api, identity: identity, keychain: QFKeychainStore(service: service))
    await app.start()
    try await app.login(agreementAccepted: true)
    let original = try await app.loadUserSettings()
    var favoriteID: String?
    var originalFavorite: Bool?
    do {
      let changed = QFUserSettings(
        theme: original.theme, interfaceLanguage: original.interfaceLanguage,
        planReminders: original.planReminders,
        workAndContributionUpdates: !original.workAndContributionUpdates)
      let saved = try await app.updateUserSettings(changed)
      XCTAssertEqual(saved.workAndContributionUpdates, changed.workAndContributionUpdates)
      let reread = try await app.loadUserSettings()
      XCTAssertEqual(reread.workAndContributionUpdates, changed.workAndContributionUpdates)
      _ = try await app.updateUserSettings(original)
      let restoredSettings = try await app.loadUserSettings()
      XCTAssertEqual(restoredSettings.workAndContributionUpdates, original.workAndContributionUpdates)

      let catalog: QFContentPage<QFCatalogItem> = try await app.contentRequest(
        path: "catalog", query: ["type": "RECIPE", "page": "0"])
      let id = try XCTUnwrap(catalog.items.first?.id)
      favoriteID = id
      let path = "me/favorites/RECIPE/\(id)"
      let before: FavoriteState = try await app.contentRequest(path: path)
      originalFavorite = before.saved
      try await app.contentMutation(path: path, method: before.saved ? "DELETE" : "PUT")
      let after: FavoriteState = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.contentRequest(path: path)
      }
      XCTAssertEqual(after.saved, !before.saved)
      try await app.contentMutation(path: path, method: before.saved ? "PUT" : "DELETE")
      let restored: FavoriteState = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.contentRequest(path: path)
      }
      XCTAssertEqual(restored.saved, before.saved)
      try await app.logout()
    } catch {
      _ = try? await app.updateUserSettings(original)
      if let favoriteID, let originalFavorite {
        try? await app.contentMutation(
          path: "me/favorites/RECIPE/\(favoriteID)", method: originalFavorite ? "PUT" : "DELETE")
      }
      try? await app.logout()
      throw error
    }
  }

  /// Real HTTPS on the isolated acceptance identity, with synthetic plan/list cleanup.
  @MainActor func testRealTestServerPlanPreparationAndShoppingThroughUIKit() async throws {
    try XCTSkipUnless(Self.liveNetworkEnabled,
                      "Real-network check requires explicit opt-in")
    let service = "com.talka.acceptance.v46.20261006"
    let identity = QFDeviceIdentity(service: service)
    let api = QFAPIClient(
      environment: .init(name: "acceptance-v46", baseURL: URL(string: "https://test-api.yzsalingo.com/api/v1")),
      identity: identity)
    api.recordsRequests = false
    let app = QFAppSession(api: api, identity: identity, keychain: QFKeychainStore(service: service))
    await app.start()
    try await app.login(agreementAccepted: true)
    var date: String?
    var recipeID: String?
    var stage = "catalog"
    do {
      let catalog: QFContentPage<QFCatalogItem> = try await app.contentRequest(
        path: "catalog", query: ["type": "RECIPE", "page": "0"])
      let recipe = try XCTUnwrap(catalog.items.first { !$0.materials.isEmpty })
      recipeID = recipe.id
      stage = "find-empty-date"
      for offset in 14...30 {
        let candidate = QFManualPlanDraft.string(
          try XCTUnwrap(QFManualPlanDraft.calendar.date(byAdding: .day, value: offset, to: Date())))
        let day = try await app.planDay(date: candidate)
        if day.slots.allSatisfy({ $0.items.isEmpty }) { date = candidate; break }
      }
      let selectedDate = try XCTUnwrap(date, "No empty acceptance date was found")
      let key = "manual-plan.personal"
      var draft = QFManualPlanDraft(date: selectedDate)
      draft.recipes["BREAKFAST"] = [.init(
        id: recipe.id, title: recipe.title, subtitle: recipe.subtitle,
        mediaId: recipe.mediaId, minutes: recipe.minutes, language: app.interfaceLanguage)]
      XCTAssertTrue(QFContentDraftStore.save(draft, app: app, kind: key))
      let saved = expectation(description: "UIKit plan save reached real test server")
      let editor = QFCreatePlanViewController(app: app, initialDate: Date()) { saved.fulfill() }
      let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
      let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
      defer {
        window.isHidden = true
        window.rootViewController = nil
        QFContentDraftStore.remove(app: app, kind: key)
      }
      window.rootViewController = QFNavigationController(rootViewController: editor)
      window.makeKeyAndVisible()
      editor.loadViewIfNeeded()
      try await waitUntil {
        self.descendants(UIButton.self, editor.view).contains {
          $0.accessibilityIdentifier == "plan.create.save" && $0.isEnabled
        }
      }
      let save = try XCTUnwrap(descendants(UIButton.self, editor.view).first {
        $0.accessibilityIdentifier == "plan.create.save"
      })
      stage = "UIKit-plan-save"
      save.sendActions(for: .touchUpInside)
      await fulfillment(of: [saved], timeout: 30)
      stage = "plan-readback"
      let plans = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.plannedMeals(
          recipeID: recipe.id, startDate: selectedDate, endDate: selectedDate, meal: "BREAKFAST")
      }
      let plan = try XCTUnwrap(plans.items.first { $0.recipeId == recipe.id })
      XCTAssertEqual(plan.date, selectedDate)
      stage = "preparation"
      let prep = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.planPreparation(startDate: selectedDate, endDate: selectedDate)
      }
      XCTAssertTrue(prep.sourcePlans.contains { $0.planId == plan.id })
      XCTAssertFalse(prep.items.isEmpty, "A recipe with materials must reach preparation")
      stage = "shopping-generate"
      let shopping = try await app.generateShoppingList(.init(
        startDate: selectedDate, endDate: selectedDate, householdId: nil, subtractInventory: false))
      XCTAssertEqual(shopping.startDate, selectedDate)
      XCTAssertFalse(shopping.items.isEmpty, "Preparation must produce a shopping list")
      stage = "shopping-readback"
      let reread = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.shoppingList(shopping.id)
      }
      XCTAssertEqual(reread.items.count, shopping.items.count)
      let evidence = XCTAttachment(string:
        "TEST-only identity; UIKit save -> real HTTPS plan readback -> preparation source/materials -> generated shopping list/readback; synthetic data cleaned afterward.")
      evidence.name = "Real plan/preparation/shopping boundary"
      evidence.lifetime = .keepAlways
      add(evidence)
      stage = "cleanup"
      try await cleanupOwnPlanAndShopping(app, date: selectedDate, recipeID: recipe.id)
      let remaining = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.plannedMeals(
          recipeID: recipe.id, startDate: selectedDate, endDate: selectedDate, meal: "BREAKFAST")
      }
      XCTAssertTrue(remaining.items.isEmpty)
      try await app.logout()
    } catch {
      let diagnostic = XCTAttachment(string: "Stage: \(stage); error: \(error)")
      diagnostic.name = "Live plan flow failure stage"
      diagnostic.lifetime = .keepAlways
      add(diagnostic)
      if let date, let recipeID {
        try? await cleanupOwnPlanAndShopping(app, date: date, recipeID: recipeID)
      }
      try? await app.logout()
      throw error
    }
  }

  @MainActor private func cleanupOwnPlanAndShopping(
    _ app: QFAppSession, date: String, recipeID: String
  ) async throws {
    let lists = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
      try await app.shoppingLists()
    }
    for list in lists.items where list.startDate == date && list.endDate == date {
      try await app.deleteShoppingList(list.id)
    }
    let plans = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
      try await app.plannedMeals(
        recipeID: recipeID, startDate: date, endDate: date, meal: "BREAKFAST")
    }
    for plan in plans.items where plan.recipeId == recipeID {
      try await app.deletePlannedMeal(plan.id, expectedRevision: plan.revision)
    }
  }

  /// A disabled schedule proves the timezone/meal contract without sending a notification.
  @MainActor func testRealTestServerReminderSettingsReadWrite() async throws {
    try XCTSkipUnless(Self.liveNetworkEnabled,
                      "Real-network check requires explicit opt-in")
    let service = "com.talka.acceptance.v46.20261006"
    let identity = QFDeviceIdentity(service: service)
    let api = QFAPIClient(
      environment: .init(name: "acceptance-v46", baseURL: URL(string: "https://test-api.yzsalingo.com/api/v1")),
      identity: identity)
    api.recordsRequests = false
    let app = QFAppSession(api: api, identity: identity, keychain: QFKeychainStore(service: service))
    await app.start()
    try await app.login(agreementAccepted: true)
    do {
      let before = try await app.reminderSettings()
      let meals = [
        QFMealReminderDraft(meal: "BREAKFAST", enabled: true, localTime: "08:00", advanceMinutes: 0),
        QFMealReminderDraft(meal: "LUNCH", enabled: true, localTime: "12:00", advanceMinutes: 15),
        QFMealReminderDraft(meal: "DINNER", enabled: true, localTime: "18:00", advanceMinutes: 0),
        QFMealReminderDraft(meal: "SNACK", enabled: false, localTime: "15:00", advanceMinutes: 0),
      ]
      let saved = try await app.saveReminderSettings(.init(
        householdId: nil, timezone: "Asia/Shanghai", enabled: false,
        expectedRevision: before.revision, meals: meals))
      XCTAssertFalse(saved.enabled)
      XCTAssertEqual(saved.timezone, "Asia/Shanghai")
      XCTAssertEqual(saved.meals.count, 4)
      let reread = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.reminderSettings()
      }
      XCTAssertEqual(reread, saved)
      if before.id != nil {
        let restored = try await app.saveReminderSettings(.init(
          householdId: nil, timezone: before.timezone ?? "Asia/Shanghai",
          enabled: before.enabled, expectedRevision: saved.revision,
          meals: before.meals.map {
            QFMealReminderDraft(meal: $0.meal, enabled: $0.enabled,
                                localTime: $0.localTime, advanceMinutes: $0.advanceMinutes)
          }))
        XCTAssertEqual(restored.enabled, before.enabled)
      }
      let evidence = XCTAttachment(string:
        "TEST-only identity; disabled personal reminder with IANA timezone and four meals saved and read back over real HTTPS. Existing settings restored; no push was sent.")
      evidence.name = "Real reminder settings boundary"
      evidence.lifetime = .keepAlways
      add(evidence)
      try await app.logout()
    } catch {
      try? await app.logout()
      throw error
    }
  }

  /// One clearly marked feedback item on the test-only identity; no user profile is changed.
  @MainActor func testRealTestServerFeedbackSubmissionThroughUIKit() async throws {
    try XCTSkipUnless(Self.liveNetworkEnabled,
                      "Real-network check requires explicit opt-in")
    let service = "com.talka.acceptance.v46.20261006"
    let identity = QFDeviceIdentity(service: service)
    let api = QFAPIClient(
      environment: .init(name: "acceptance-v46", baseURL: URL(string: "https://test-api.yzsalingo.com/api/v1")),
      identity: identity)
    api.recordsRequests = false
    let app = QFAppSession(api: api, identity: identity, keychain: QFKeychainStore(service: service))
    await app.start()
    try await app.login(agreementAccepted: true)
    do {
      let feedback = QFHelpFeedbackViewController(app: app)
      let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
      let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
      defer { window.isHidden = true; window.rootViewController = nil }
      window.rootViewController = QFNavigationController(rootViewController: feedback)
      window.makeKeyAndVisible()
      feedback.loadViewIfNeeded()
      let category = try XCTUnwrap(descendants(UISegmentedControl.self, feedback.view).first {
        $0.accessibilityIdentifier == "feedback.category"
      })
      category.selectedSegmentIndex = 1
      category.sendActions(for: .valueChanged)
      let content = try XCTUnwrap(descendants(UITextView.self, feedback.view).first {
        $0.accessibilityIdentifier == "feedback.content"
      })
      content.text = "Codex 独立测试账号真机反馈联调 2026-10-09；请忽略此条。"
      content.delegate?.textViewDidChange?(content)
      let submit = try XCTUnwrap(descendants(UIButton.self, feedback.view).first {
        $0.accessibilityIdentifier == "feedback.submit"
      })
      submit.sendActions(for: .touchUpInside)
      try await waitUntil {
        (feedback.presentedViewController as? UIAlertController)?.title == "已提交"
      }
      XCTAssertEqual(category.selectedSegmentIndex, 1)
      XCTAssertEqual(content.text, "")
      let evidence = XCTAttachment(string:
        "TEST-only identity; UI selected SUGGESTION, submitted one marked feedback over real HTTPS, received success alert and cleared text. This test ticket remains in test admin.")
      evidence.name = "Real feedback submission boundary"
      evidence.lifetime = .keepAlways
      add(evidence)
      try await app.logout()
    } catch {
      try? await app.logout()
      throw error
    }
  }

  @MainActor func testRealTestServerReceiptAndInventoryThroughUIKit() async throws {
    try XCTSkipUnless(Self.liveNetworkEnabled, "Real-network check requires explicit opt-in")
    let service = "com.talka.acceptance.v46.20261006"
    let identity = QFDeviceIdentity(service: service)
    let api = QFAPIClient(environment: .init(name: "acceptance-v46", baseURL: URL(string: "https://test-api.yzsalingo.com/api/v1")), identity: identity)
    let logDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "qf-receipt-audit-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: logDirectory) }
    let requestLog = QFRequestLogStore(directoryURL: logDirectory)
    api.requestLogStore = requestLog
    let app = QFAppSession(api: api, identity: identity, keychain: QFKeychainStore(service: service))
    await app.start(); try await app.login(agreementAccepted: true)
    do {
      let catalog: QFContentPage<QFCatalogItem> = try await app.contentRequest(path: "catalog", query: ["type":"INGREDIENT", "category":"VEGETABLE", "page":"0"])
      let ingredient = try XCTUnwrap(catalog.items.first)
      // IDs are stable on this test device but distinct from an earlier simulator
      // acceptance account; receipt IDs are globally unique across accounts.
      let receiptKey = "qf.acceptance.receipt.id." + service
      let lineKey = "qf.acceptance.receipt.line.id." + service
      let receiptID = UserDefaults.standard.string(forKey: receiptKey) ?? UUID().uuidString.lowercased()
      let lineID = UserDefaults.standard.string(forKey: lineKey) ?? UUID().uuidString.lowercased()
      UserDefaults.standard.set(receiptID, forKey: receiptKey)
      UserDefaults.standard.set(lineID, forKey: lineKey)
      let receipt: QFPurchaseReceipt
      do { receipt = try await app.contentRequest(path: "me/purchase-receipts/" + receiptID) }
      catch let error as QFAPIError where error.code == 40400 {
        var draft = QFPurchaseReceiptDraft(date: "2026-10-06", householdId: nil)
        draft.id = receiptID; draft.merchant = "Codex integration check 2026-10-06"
        draft.items = [.init(id:lineID, ingredientId:ingredient.id, name:ingredient.title, quantity:"1", unitCode:"g", lineAmount:"1")]
        XCTAssertNoThrow(try draft.request(), "The synthetic receipt must pass local validation")
        XCTAssertTrue(QFContentDraftStore.save(draft, app:app, kind:"receipt.personal.new"))
        let editor = QFPurchaseReceiptViewController(app:app)
        let scene = UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first
        let window = scene.map{UIWindow(windowScene:$0)} ?? UIWindow(frame:UIScreen.main.bounds)
        defer { window.isHidden = true; window.rootViewController = nil }
        window.rootViewController = QFNavigationController(rootViewController:editor);window.makeKeyAndVisible();editor.loadViewIfNeeded();window.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(25)
        while !descendants(UIButton.self,editor.view).contains(where:{$0.accessibilityIdentifier=="purchase.receipt.save" && $0.isEnabled}) && Date()<deadline { try await Task.sleep(nanoseconds:100_000_000) }
        var didSave = false
        editor.onChanged = { didSave = true }
        let button = try XCTUnwrap(descendants(UIButton.self,editor.view).first{$0.accessibilityIdentifier=="purchase.receipt.save"})
        button.sendActions(for:.touchUpInside)
        let saveDeadline = Date().addingTimeInterval(15)
        while !didSave && Date() < saveDeadline { try await Task.sleep(nanoseconds:200_000_000) }
        if !didSave {
          let attempts = requestLog.entries.filter { $0.url.contains("purchase-receipts") }
            .map { "\($0.method) status=\($0.statusCode.map(String.init) ?? "none") body=\($0.responseBody)" }
          let diagnostic = XCTAttachment(string: "Footer: \(button.currentTitle ?? "none"); purchase requests: \(attempts)")
          diagnostic.name = "Receipt save failure boundary"
          diagnostic.lifetime = .keepAlways
          add(diagnostic)
          XCTFail("UIKit receipt did not report save; see sanitized HTTP status attachment")
        }
        receipt = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.contentRequest(path:"me/purchase-receipts/"+receiptID) }
        let shot=XCTAttachment(image:UIGraphicsImageRenderer(bounds:window.bounds).image{_ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)})
        shot.name="Real test-server receipt";shot.lifetime = .keepAlways;add(shot)
      }
      XCTAssertEqual(receipt.id,receiptID);XCTAssertEqual(receipt.paidAmount.flatMap(QFPurchaseNumber.decimal),Decimal(1))
      let inventory = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.inventoryLots() }
      XCTAssertTrue(inventory.items.contains{$0.id==receipt.items.first?.lotId})
      let statistics: QFCookingUsagePage = try await app.contentRequest(path:"me/cooking-statistics",query:["startDate":"2026-10-01","endDate":"2026-10-31","page":"0"])
      XCTAssertEqual(statistics.summary.completedCount,0)
      let evidence = XCTAttachment(string:"TEST service only; owned acceptance identity; receipt \(receiptID); UIKit save + actual HTTPS + stock readback + statistics decoding. No mocked URLProtocol. No real-user data changed.")
      evidence.name="Real-network boundary";evidence.lifetime = .keepAlways;add(evidence)
      try await exerciseCooking(app, ingredient: ingredient, lotID: try XCTUnwrap(receipt.items.first?.lotId))
      try await app.logout()
    } catch { try? await app.logout(); throw error }
  }
  @MainActor private func exerciseCooking(_ app: QFAppSession, ingredient: QFCatalogItem, lotID: String) async throws {
    let date = "2026-10-06", kind = "backfill.personal.2026-10-06"
    let initial = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.inventoryLots() }
    let before = try XCTUnwrap(initial.items.first { $0.id == lotID }?.currentQuantity)
    var draft = QFBackfillCookingDraft(date: date, householdId: nil, language: app.interfaceLanguage)
    for meal in ["BREAKFAST", "LUNCH"] {
      var row = QFCookingRecord(); row.date = date; row.meal = meal; row.title = "Codex isolated integration " + meal
      row.materials = [.init(name:ingredient.title, amount:"0.1", unit:"g", ingredientId:ingredient.id)]
      draft.items.append(.init(record:row,recipeId:nil))
    }
    XCTAssertTrue(draft.ready);XCTAssertTrue(QFContentDraftStore.save(draft,app:app,kind:kind))
    let ids = draft.items.map { $0.record.id }
    let page = QFBackfillCookingViewController(app:app,date:date)
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    let window = scene.map { UIWindow(windowScene:$0) } ?? UIWindow(frame:UIScreen.main.bounds)
    defer { window.isHidden=true;window.rootViewController=nil;QFContentDraftStore.remove(app:app,kind:kind) }
    let nav = QFNavigationController(rootViewController:page);window.rootViewController=nav;window.makeKeyAndVisible();page.loadViewIfNeeded()
    do {
      try await waitUntil { self.descendants(UILabel.self,page.view).first { $0.accessibilityIdentifier == "plan.backfill.cost" }?.text?.contains("0.10") == true }
      let saved = expectation(description:"Real two-meal atomic backfill")
      page.onChanged = { saved.fulfill() }
      let save = try XCTUnwrap(descendants(UIButton.self,page.view).first { $0.accessibilityIdentifier == "plan.backfill.save" })
      save.sendActions(for:.touchUpInside);await fulfillment(of:[saved],timeout:30)
      let record: QFCookingRecord = try await app.contentRequest(path:"me/cooking-records/"+ids[0])
      let cost: QFCookingCost = try await app.contentRequest(path:"me/cooking-records/"+ids[0]+"/cost")
      XCTAssertEqual(cost.status,"COMPLETE");XCTAssertEqual((cost.totals.first?.total).flatMap(QFPurchaseNumber.decimal),Decimal(string:"0.1"))
      let detail=QFCookingRecordDetailViewController(app:app,record:record);nav.setViewControllers([detail],animated:false);detail.loadViewIfNeeded()
      try await waitUntil { self.descendants(UIButton.self,detail.view).contains { $0.accessibilityIdentifier == "cooking.detail.edit" && $0.isEnabled } }
      let edit=try XCTUnwrap(descendants(UIButton.self,detail.view).first { $0.accessibilityIdentifier == "cooking.detail.edit" });edit.sendActions(for:.touchUpInside)
      let amount=try XCTUnwrap(descendants(UITextField.self,detail.view).first { $0.accessibilityIdentifier == "cooking.detail.amount.0" });amount.text="0.15";amount.sendActions(for:.editingChanged)
      let edited=expectation(description:"Real correction updates net stock and cost");detail.onChanged = { edited.fulfill() }
      let commit=try XCTUnwrap(descendants(UIButton.self,detail.view).first { $0.accessibilityIdentifier == "cooking.detail.save" });commit.sendActions(for:.touchUpInside);await fulfillment(of:[edited],timeout:30)
      let updated:QFCookingCost = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.contentRequest(path:"me/cooking-records/"+ids[0]+"/cost") }
      XCTAssertEqual((updated.totals.first?.total).flatMap(QFPurchaseNumber.decimal),Decimal(string:"0.15"))
      let stock=try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.inventoryLots() }
      XCTAssertEqual((stock.items.first { $0.id==lotID }?.currentQuantity).flatMap(QFPurchaseNumber.decimal),QFPurchaseNumber.decimal(before)!-Decimal(string:"0.25")!)
      let screenshot=XCTAttachment(image:UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) });screenshot.name="Real test-server corrected cooking cost";screenshot.lifetime = .keepAlways;add(screenshot)
    } catch { try? await undoOwnRecords(app,ids:ids);throw error }
    try await undoOwnRecords(app,ids:ids)
    let restored=try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.inventoryLots() }
    XCTAssertEqual((restored.items.first { $0.id==lotID }?.currentQuantity).flatMap(QFPurchaseNumber.decimal),QFPurchaseNumber.decimal(before))
    let evidence=XCTAttachment(string:"Actual HTTPS UIKit: read-only batch cost preview; same-day breakfast+lunch atomic save; persisted cost; detail amount correction; precise stock delta; undo only own synthetic records restores starting stock. Receipt and audit trail retained.");evidence.name="Live cooking and stock boundary";evidence.lifetime = .keepAlways;add(evidence)
  }
  @MainActor private func undoOwnRecords(_ app:QFAppSession,ids:[String]) async throws {
    for id in ids {
      do { let row:QFCookingRecord=try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.contentRequest(path:"me/cooking-records/"+id) }
        try await app.contentMutation(path:"me/cooking-records/"+id,method:"DELETE",query:["expectedRevision":String(try XCTUnwrap(row.revision))])
      } catch let error as QFAPIError where error.code==40400 { }
    }
  }
  @MainActor private func waitUntil(_ condition:()->Bool) async throws {
    let until=Date().addingTimeInterval(25)
    while !condition() && Date()<until { try await Task.sleep(nanoseconds:100_000_000) }
    XCTAssertTrue(condition())
  }
  @MainActor private func descendants<T:UIView>(_ type:T.Type,_ root:UIView)->[T] { ((root as? T).map{[$0]} ?? []) + root.subviews.flatMap{descendants(type,$0)} }
}
