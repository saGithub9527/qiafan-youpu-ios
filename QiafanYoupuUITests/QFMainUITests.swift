import XCTest

final class QFAssistantOverlayUITests: XCTestCase {
  func testFilamentPreviewRemainsInteractiveAboveLogin() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-QFSkipWelcome", "-QFStartTab", "profile", "-QFAssistantFilamentPreview"]
    app.launch(); defer { app.terminate() }
    let selector = app.buttons["assistant.selection.button"]
    XCTAssertTrue(selector.waitForExistence(timeout: 15))
    selector.tap()
    XCTAssertTrue(app.buttons["assistant.selection.renderer"].isSelected, "The native preview must actually be active")
    let categories = app.segmentedControls["assistant.selection.category"]
    categories.buttons.element(boundBy: 1).tap()
    let smile = app.cells["assistant.face.smile"]
    XCTAssertTrue(smile.waitForExistence(timeout: 5)); smile.tap()
    let proof = XCTAttachment(screenshot: app.screenshot())
    proof.name = "filament-preview-in-app"; proof.lifetime = .keepAlways; add(proof)
    let renderer = app.buttons["assistant.selection.renderer"]
    renderer.tap()
    XCTAssertFalse(renderer.isSelected)
    renderer.tap()
    XCTAssertTrue(renderer.isSelected)
    XCTAssertFalse(app.cells["assistant.face.smile"].isSelected, "Switching renderers must clear the old manual expression")
    app.buttons["assistant.selection.close"].tap()
    app.buttons["profile.login"].tap()
    XCTAssertTrue(selector.isHittable)
    XCTAssertTrue(app.buttons["assistant.floating-button"].isHittable)
    selector.tap()
    XCTAssertTrue(app.buttons["assistant.selection.renderer"].waitForExistence(timeout: 5))
    let login = XCTAttachment(screenshot: app.screenshot())
    login.name = "filament-preview-above-login"; login.lifetime = .keepAlways; add(login)
  }

  func testSelectionsRemainAvailableAboveOtherPages() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-QFSkipWelcome", "-QFStartTab", "profile"]
    app.launch()
    defer { app.terminate() }
    let select = app.buttons["assistant.selection.button"]
    XCTAssertTrue(select.waitForExistence(timeout: 15))
    select.tap()
    let list = app.tables["assistant.selection.list"]
    XCTAssertTrue(list.waitForExistence(timeout: 5))
    XCTAssertTrue(app.cells["assistant.pose.wave"].exists)
    app.cells["assistant.pose.wave"].tap()
    let categories = app.segmentedControls["assistant.selection.category"]
    categories.buttons.element(boundBy: 1).tap()
    XCTAssertTrue(app.cells["assistant.face.smile"].waitForExistence(timeout: 5))
    app.cells["assistant.face.smile"].tap()
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "assistant-actions-and-expressions"; attachment.lifetime = .keepAlways; add(attachment)
    app.buttons["assistant.selection.automatic"].tap()
    app.buttons["assistant.selection.close"].tap()
    // Open another app page without submitting data. The character window
    // must stay interactive after the tab's content/navigation hierarchy changes.
    app.buttons["profile.login"].tap()
    XCTAssertTrue(app.buttons["assistant.floating-button"].isHittable)
    XCTAssertTrue(select.isHittable)
    select.tap()
    XCTAssertTrue(list.waitForExistence(timeout: 5))
    let top = XCTAttachment(screenshot: app.screenshot())
    top.name = "assistant-above-presented-content"; top.lifetime = .keepAlways; add(top)
  }
}

final class QFMainUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    #if DEBUG
      app = XCUIApplication()
    #else
      throw XCTSkip("Debug UI flow; use QFReleaseWelcomeUITests for Release.")
    #endif
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func assertAgreementIsVerticallyCentered(_ identifier: String) {
    let checkbox = app.buttons[identifier]
    let copy = app.descendants(matching: .any).matching(identifier: "\(identifier).text").firstMatch
    XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
    XCTAssertTrue(copy.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(copy.frame.height, 0)
    XCTAssertEqual(checkbox.frame.midY, copy.frame.midY, accuracy: 2)
  }

  private func openLogin(reset: Bool) {
    app.launchArguments = ["-QFSkipWelcome", "-QFStartTab", "profile"]
    if reset { app.launchArguments += ["-QFResetUIState"] }
    app.launch()
    XCTAssertTrue(app.buttons["profile.login"].waitForExistence(timeout: 10))
    app.buttons["profile.login"].tap()
    if !app.buttons["login.quick"].waitForExistence(timeout: 5) {
      // Session restoration can finish between reading the profile label and tapping it.
      // Check the actual destination, then revoke only this simulator's test session.
      XCTAssertTrue(app.alerts["编辑资料"].waitForExistence(timeout: 5))
      app.alerts["编辑资料"].buttons["知道了"].tap()
      app.buttons["diagnostics.open"].tap()
      let menu = app.buttons["diagnostics.menu"]
      XCTAssertTrue(menu.waitForExistence(timeout: 5))
      expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: menu)
      waitForExpectations(timeout: 30)
      menu.tap()
      app.buttons["退出当前测试会话"].tap()
      expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: menu)
      waitForExpectations(timeout: 30)
      app.buttons["diagnostics.requests.close"].tap()
      expectation(
        for: NSPredicate(format: "label == %@", "去登录"),
        evaluatedWith: app.buttons["profile.login"])
      waitForExpectations(timeout: 10)
      app.buttons["profile.login"].tap()
    }
    XCTAssertTrue(app.buttons["login.quick"].waitForExistence(timeout: 5))
    let ready = NSPredicate(format: "value == %@", "可用")
    expectation(for: ready, evaluatedWith: app.buttons["login.quick"])
    waitForExpectations(timeout: 30)
  }

  func testAllFourPrimaryTabs() {
    app.launchArguments = ["-QFSkipWelcome"]
    app.launch()
    for tab in ["recipe", "plan", "ingredient", "profile"] {
      let button = app.buttons["tab.\(tab)"]
      XCTAssertTrue(button.waitForExistence(timeout: 10))
      button.tap()
      XCTAssertTrue(button.isSelected)
      capture("tab-\(tab)")
    }
    let profileAction = app.buttons["profile.login"]
    XCTAssertTrue(profileAction.exists)
    profileAction.tap()
    if app.buttons["login.quick"].waitForExistence(timeout: 5) {
      capture("04-login")
      app.buttons["login.close"].tap()
    } else {
      // A simulator can retain its test account between UI runs. The same profile
      // action then opens the signed-in profile editor rather than the login sheet.
      XCTAssertTrue(app.staticTexts["编辑资料"].waitForExistence(timeout: 5))
      capture("04-signed-in-profile-editor")
      app.buttons["返回"].firstMatch.tap()
    }
    XCTAssertTrue(app.buttons["tab.profile"].waitForExistence(timeout: 5))
  }

  func testSwitchingTabsPreservesSearchAndDismissesKeyboard() {
    app.launchArguments = ["-QFSkipWelcome", "-QFStartTab", "ingredient"]
    app.launch()
    let search = app.textFields["ingredient.search"]
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    search.typeText("milk")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    app.buttons["tab.plan"].tap()
    XCTAssertTrue(app.buttons["tab.plan"].isSelected)
    let keyboardGone = NSPredicate(format: "exists == false")
    expectation(for: keyboardGone, evaluatedWith: app.keyboards.firstMatch)
    waitForExpectations(timeout: 5)
    app.buttons["tab.ingredient"].tap()
    XCTAssertEqual(app.textFields["ingredient.search"].value as? String, "milk")
    XCTAssertFalse(app.keyboards.firstMatch.exists)
  }

  func testEmptyInventoryDistinguishesNoStockFromNoSearchMatch() throws {
    app.launchArguments = ["-QFSkipWelcome", "-QFStartTab", "ingredient"]
    app.launch()
    guard app.staticTexts["暂无库存"].waitForExistence(timeout: 12) else {
      throw XCTSkip("Requires the signed-in disposable simulator account with empty inventory")
    }
    capture("inventory-empty-unfiltered")
    let search = app.textFields["ingredient.search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("qf-never-matches-8472")
    XCTAssertTrue(app.staticTexts["没有找到相关食材"].waitForExistence(timeout: 12))
    capture("inventory-empty-filtered")
  }

  func testLoginConsentPersistsBothDirectionsAndDoesNotAuthenticate() {
    openLogin(reset: true)
    assertAgreementIsVerticallyCentered("login.agreement")
    capture("login-centered-agreement")
    XCTAssertTrue(app.buttons["login.quick"].isEnabled)
    XCTAssertTrue(app.buttons["login.apple"].isEnabled)
    XCTAssertNotEqual(app.buttons["login.apple"].value as? String, "正在等待 Apple 授权")
    XCTAssertNotEqual(app.buttons["login.apple"].value as? String, "正在登录")
    XCTAssertEqual(app.buttons["login.agreement"].value as? String, "未勾选")
    app.buttons["login.quick"].tap()
    XCTAssertTrue(app.buttons["notice.continue"].waitForExistence(timeout: 5))
    assertAgreementIsVerticallyCentered("notice.agreement")
    capture("notice-centered-agreement")
    XCTAssertFalse(app.buttons["notice.continue"].isEnabled)
    app.buttons["notice.agreement"].tap()
    app.buttons["notice.decline"].tap()
    XCTAssertEqual(app.buttons["login.agreement"].value as? String, "未勾选")
    app.buttons["login.agreement"].tap()
    app.terminate()
    openLogin(reset: false)
    XCTAssertEqual(app.buttons["login.agreement"].value as? String, "已勾选")
    // Toggling consent must not start real Apple authorization or create an account.
    XCTAssertTrue(app.buttons["login.quick"].exists)
    app.buttons["login.agreement"].tap()
    app.terminate()
    openLogin(reset: false)
    XCTAssertEqual(app.buttons["login.agreement"].value as? String, "未勾选")
  }

  func testWelcomePagesConsentAndDebugRelaunch() {
    app.launchArguments = ["-QFResetUIState"]
    app.launch()
    XCTAssertTrue(app.buttons["welcome.skip"].waitForExistence(timeout: 10))
    capture("01-welcome")
    XCTAssertFalse(app.buttons["welcome.enter"].isHittable)
    let pager = app.scrollViews["welcome.pages"]
    XCTAssertTrue(pager.waitForExistence(timeout: 5))
    for _ in 0..<4 {
      // On iPad the centered pager is narrower than the window; start inside its illustration.
      let start = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
      let end = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45))
      start.press(forDuration: 0.05, thenDragTo: end)
    }
    XCTAssertTrue(app.buttons["welcome.enter"].isHittable)
    capture("02-welcome-last")
    app.buttons["welcome.enter"].tap()
    XCTAssertTrue(app.buttons["notice.continue"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["notice.continue"].isEnabled)
    capture("03-safety-notice")
    app.buttons["notice.agreement"].tap()
    XCTAssertTrue(app.buttons["notice.continue"].isEnabled)
    app.buttons["notice.continue"].tap()
    XCTAssertTrue(app.buttons["tab.recipe"].waitForExistence(timeout: 5))
    app.terminate()
    app.launchArguments = []
    app.launch()
    XCTAssertTrue(app.buttons["welcome.skip"].waitForExistence(timeout: 10))
  }
}

/// Read-only route audit for a signed-in physical test device. It deliberately avoids
/// submitting plans, changing settings, or capturing a receipt for the user's account.
final class QFPhysicalJourneyUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["-QFSkipWelcome"]
    app.launch()
    XCTAssertTrue(app.buttons["tab.recipe"].waitForExistence(timeout: 20))
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @discardableResult
  private func page(_ identifier: String, timeout: TimeInterval = 10) -> XCUIElement {
    let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    XCTAssertTrue(element.waitForExistence(timeout: timeout), "Page missing: \(identifier)")
    return element
  }

  private func back() {
    let button = app.buttons["返回"].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 5), "Back button missing")
    button.tap()
  }

  func testRecipeSearchAndFilters() {
    page("recipe.home")
    capture("recipe-home")
    app.buttons["recipe.search"].tap()
    page("recipe.search.screen")
    capture("recipe-search")
    back()
    page("recipe.home")
    app.buttons["recipe.filter.country"].tap()
    capture("recipe-country-filter")
    back()
    page("recipe.home")
    app.buttons["recipe.filter.taste"].tap()
    capture("recipe-taste-filter")
  }

  func testAssistantCharacterGreetsAndTapDoesNotCrash() {
    XCTAssertTrue(page("assistant.floating-button", timeout: 5).isHittable)
    XCTAssertTrue(page("assistant.greeting", timeout: 10).exists)
    capture("assistant-greeting")

    app.buttons["assistant.floating-button"].tap()
    // A signed-in device opens the conversation panel. A signed-out device is still a valid
    // no-crash path and keeps the root tab visible while showing the sign-in toast.
    let panel = app.otherElements["assistant.conversation.panel"]
    if panel.waitForExistence(timeout: 5) {
      XCTAssertTrue(app.buttons["assistant.conversation.close"].waitForExistence(timeout: 5))
      app.buttons["assistant.conversation.close"].tap()
      XCTAssertTrue(page("assistant.floating-button", timeout: 5).exists)
    } else {
      XCTAssertTrue(app.buttons["tab.recipe"].exists)
    }
  }

  func testRecipeDetailAndReturn() {
    page("recipe.home")
    let firstDish = app.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH %@", "八宝粥")
    ).firstMatch
    XCTAssertTrue(firstDish.waitForExistence(timeout: 15))
    firstDish.tap()
    page("recipe.detail")
    capture("recipe-detail")
    XCTAssertEqual(app.state, .runningForeground, "Recipe detail left the foreground before back navigation")
    back()
    page("recipe.home")
  }

  func testUnpicturedRecipesUseIllustrations() {
    page("recipe.home")
    for dish in ["八宝粥", "白切鸡", "糖油粑粑", "豆沙包"] {
      app.buttons["recipe.search"].tap()
      page("recipe.search.screen")
      let field = app.searchFields.firstMatch
      XCTAssertTrue(field.waitForExistence(timeout: 5))
      field.tap()
      field.typeText(dish + "\n")
      let result = app.descendants(matching: .any).matching(
        NSPredicate(format: "label BEGINSWITH %@", dish)
      ).firstMatch
      XCTAssertTrue(result.waitForExistence(timeout: 15), "No search result for \(dish)")
      result.tap()
      page("recipe.detail")
      XCTAssertTrue(app.staticTexts["插画"].waitForExistence(timeout: 5),
                    "A recipe without owned media must identify its illustration: \(dish)")
      capture("illustration-\(dish)")
      back()
      page("recipe.search.screen")
      back()
      page("recipe.home")
    }
  }

  func testRecipeCountryFilterAppliesAndClears() {
    page("recipe.home")
    // Dismiss the device's AssistiveTouch menu if a previous run opened it.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.1)).tap()
    let country = app.buttons["recipe.filter.country"]
    XCTAssertTrue(country.waitForExistence(timeout: 10))
    country.tap()
    let china = app.staticTexts["中国"].firstMatch
    XCTAssertTrue(china.waitForExistence(timeout: 10))
    china.tap()
    app.buttons["确定"].tap()
    page("recipe.home")
    XCTAssertTrue(country.waitForExistence(timeout: 10))
    XCTAssertTrue(country.label.contains("中国"), "Applied country must be shown in filter")
    capture("recipe-country-applied")
    let clear = app.buttons["recipe.clearFilters"]
    XCTAssertTrue(clear.waitForExistence(timeout: 5))
    // The physical device's AssistiveTouch bubble can cover the button center.
    clear.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
    expectation(
      for: NSPredicate(format: "label CONTAINS %@", "全球"), evaluatedWith: country)
    waitForExpectations(timeout: 10)
  }

  func testLocalThemeAndLanguageApplyThenRestore() {
    app.buttons["tab.profile"].tap()
    page("profile.screen")
    app.buttons["设置"].tap()
    page("settings.screen")
    app.buttons["主题设置"].tap()
    page("settings.theme.screen")
    // A prior interrupted audit applied 自然绿. Its recorded initial value was 经典橙.
    // Restore that value before exercising another reversible theme change.
    if app.buttons["自然绿"].isSelected {
      app.buttons["经典橙"].tap()
      app.buttons["settings.theme.apply"].tap()
      page("profile.screen")
      app.buttons["设置"].tap()
      page("settings.screen")
      app.buttons["主题设置"].tap()
      page("settings.theme.screen")
    }
    XCTAssertTrue(app.buttons["经典橙"].isSelected, "Expected pre-audit theme was not restored")
    let alternate = "自然绿"
    app.buttons[alternate].tap()
    app.buttons["settings.theme.apply"].tap()
    page("profile.screen")
    app.buttons["设置"].tap()
    page("settings.screen")
    app.buttons["主题设置"].tap()
    page("settings.theme.screen")
    XCTAssertTrue(app.buttons[alternate].isSelected, "Applied theme did not persist")
    capture("theme-applied")
    app.buttons["经典橙"].tap()
    app.buttons["settings.theme.apply"].tap()
    page("profile.screen")
    app.buttons["设置"].tap()
    page("settings.screen")
    app.buttons["界面语言"].tap()
    page("settings.language.screen")
    let original = app.buttons["简体中文"]
    XCTAssertTrue(original.isSelected, "This physical test expects the user's Chinese UAT setup")
    app.buttons["English"].tap()
    XCTAssertTrue(app.buttons["English"].isSelected, "English selection did not apply")
    capture("language-english")
    original.tap()
    XCTAssertTrue(original.isSelected, "Original interface language was not restored")
    back()
    page("settings.screen")
  }

  func testPlanCreatePickerHistoryAndPreparation() {
    app.buttons["tab.plan"].tap()
    page("plan.screen")
    capture("plan-home")
    app.buttons["plan.create"].tap()
    XCTAssertTrue(app.buttons["手动添加菜谱"].waitForExistence(timeout: 5))
    app.buttons["手动添加菜谱"].tap()
    page("plan.create.editor")
    capture("plan-create")
    XCTAssertFalse(app.buttons["plan.create.save"].isEnabled, "Empty plan must not submit")
    app.buttons["plan.create.add.BREAKFAST"].tap()
    page("plan.recipePicker")
    capture("plan-recipe-picker")
    page("plan.recipePicker.sources")
    back()
    page("plan.create.editor")
    back()
    page("plan.screen")
    app.buttons["做菜记录"].tap()
    page("plan.history")
    capture("plan-history")
    back()
    page("plan.screen")
    app.buttons["备菜"].tap()
    page("ingredient.screen")
    capture("plan-preparation")
    back()
    page("plan.screen")
  }

  func testPlanHistoryExpensesAndPreparationRoutes() {
    app.buttons["tab.plan"].tap()
    page("plan.screen")
    app.buttons["做菜记录"].tap()
    page("plan.history")
    capture("plan-history")
    app.buttons["plan.history.add"].tap()
    page("plan.backfill")
    capture("plan-backfill")
    back()
    page("plan.history")
    back()
    page("plan.screen")
    app.buttons["plan.summary.cost"].tap()
    page("plan.cooking-costs")
    capture("plan-cooking-costs")
    back()
    page("plan.screen")
    app.buttons["plan.summary.purchase"].tap()
    page("plan.expenses")
    capture("plan-expenses")
    back()
    page("plan.screen")
    app.buttons["备菜"].tap()
    page("ingredient.screen")
    capture("plan-preparation")
    back()
    page("plan.screen")
  }

  func testIngredientDiscoveryAndReceiptEntry() {
    app.buttons["tab.ingredient"].tap()
    page("ingredient.screen")
    capture("ingredient-home")
    app.buttons["食材大全"].tap()
    page("ingredient.catalog")
    capture("ingredient-catalog")
    back()
    page("ingredient.screen")
    app.buttons["食材组合推荐"].tap()
    page("ingredient.combinations")
    capture("ingredient-combinations")
    back()
    page("ingredient.screen")
    app.buttons["ingredient.scan"].tap()
    page("receipt.scanner")
    capture("receipt-scanner")
    back()
    page("ingredient.screen")
  }

  func testProfileSettingsAndContentRoutes() {
    app.buttons["tab.profile"].tap()
    page("profile.screen")
    capture("profile-home")
    app.buttons["设置"].tap()
    page("settings.screen")
    capture("settings-home")
    app.buttons["主题设置"].tap()
    page("settings.theme.screen")
    capture("settings-theme")
    back()
    page("settings.screen")
    app.buttons["界面语言"].tap()
    page("settings.language.screen")
    capture("settings-language")
    back()
    page("settings.screen")
    app.swipeUp()
    app.buttons["帮助与反馈"].tap()
    page("feedback.screen")
    capture("feedback")
    back()
    page("settings.screen")
    back()
    page("profile.screen")
    app.buttons["我的作品"].tap()
    capture("profile-works")
    back()
    page("profile.screen")
  }

  func testSystemPermissionsOpensSettingsAndReturns() throws {
    app.buttons["tab.profile"].tap()
    page("profile.screen")
    guard app.buttons["profile.login"].label != "去登录" else {
      throw XCTSkip("Requires the disposable signed-in simulator account")
    }
    app.buttons["设置"].tap()
    page("settings.screen")
    let account = app.buttons["账号与隐私"]
    if !account.isHittable { app.swipeUp() }
    account.tap()
    page("account.screen")
    let permissions = app.buttons["account.systemPermissions"]
    if !permissions.isHittable { app.swipeUp() }
    XCTAssertTrue(permissions.waitForExistence(timeout: 5))
    permissions.tap()
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
    let screenshot = XCTAttachment(screenshot: settings.screenshot())
    screenshot.name = "system-permissions-settings"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.activate()
    page("account.screen")
  }

  func testProfileContentMenuRoutes() {
    app.buttons["tab.profile"].tap()
    page("profile.screen")
    for title in ["我的图片贡献", "我的收藏", "做菜记录与统计", "兴趣偏好", "会员订阅"] {
      let entry = app.buttons[title]
      XCTAssertTrue(entry.waitForExistence(timeout: 10), "Missing profile entry: \(title)")
      if !entry.isHittable { app.swipeUp() }
      entry.tap()
      let heading = title == "做菜记录与统计" ? "做菜记录" : title
      page("profile.content.\(heading)")
      capture("profile-\(title)")
      back()
      page("profile.screen")
    }
  }
}
