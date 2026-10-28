import Foundation
import SnapKit
import UIKit
import XCTest

@testable import QiafanYoupu

#if DEBUG
private final class QFRecipeLayoutOfflineProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var requests = 0
  static func count() -> Int {
    lock.lock(); defer { lock.unlock() }
    return requests
  }
  static func reset() {
    lock.lock(); defer { lock.unlock() }
    requests = 0
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    Self.requests += 1
    Self.lock.unlock()
    client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
  }
  override func stopLoading() {}
}

@MainActor
final class QFRecipeDetailLayoutTests: XCTestCase {
  private func fixture(_ language: String) throws -> QFRecipeHomeDetail {
    let english = language == "en"
    let names = english
      ? ["Fresh red tomatoes, washed and cut into bite-size pieces",
         "Ordinary chicken eggs, cracked into a bowl and beaten together",
         "Cooking oil measured in advance for heating the pan and frying",
         "Ordinary table salt weighed according to the material list"]
      : ["洗净后切成适口小块的新鲜番茄", "打入碗中并充分搅匀的普通鸡蛋",
         "预先量取并用于热锅炒制的食用油", "按材料表预先称量的普通食盐"]
    let steps: [[String: String]] = english ? [
      ["title": "Prepare the ingredients", "body": "Wash and cut the tomatoes. Crack the eggs into a bowl and beat together. Have the cooking oil and salt ready."],
      ["title": "Cook the eggs", "body": "Heat the pan and add the cooking oil. Pour in the beaten eggs and stir-fry until fully set, then transfer to a plate."],
      ["title": "Combine and serve", "body": "Cook the tomatoes in the same pan until softened. Return the eggs, add the salt and mix, then turn off the heat and serve."]
    ] : [
      ["title": "准备食材", "body": "番茄洗净切块；鸡蛋打入碗中搅匀，备好食用油和盐。"],
      ["title": "炒鸡蛋", "body": "热锅加入食用油，倒入蛋液，翻炒至鸡蛋完全凝固后盛出。"],
      ["title": "炒匀出锅", "body": "用同一口锅将番茄炒软，倒回鸡蛋，加盐炒匀后关火装盘。"]
    ]
    let amounts = ["300", "3", "15", "2"], units = ["g", "piece", "ml", "g"]
    let materials: [[String: Any]] = names.indices.map {
      ["name": names[$0], "amount": amounts[$0], "unit": units[$0],
       "ingredientId": NSNull(), "usageStatus": NSNull()]
    }
    let object: [String: Any] = [
      "id": "d0700000-0000-4000-8000-000000000001",
      "title": english ? "Tomatoes and Eggs with a Deliberately Long Recipe Title for Narrow-Window Layout Checks"
        : "番茄炒鸡蛋——用于检查窄窗口中多行标题、材料长名称及固定底部操作栏的离线布局示例",
      "subtitle": english ? "Offline layout fixture; not a published recipe" : "离线布局夹具，不是已发布配方",
      "mediaId": NSNull(), "minutes": 15, "servings": NSNull(),
      "favoriteCount": 0, "ratingAverage": NSNull(), "ratingCount": 0,
      "isFavorite": false, "myRating": NSNull(), "categoryIds": [], "cuisineIds": [],
      "tasteIds": [], "countryCodes": ["CN"], "contentLanguage": language,
      "contentAvailable": true, "materials": materials, "steps": steps,
      "sourceName": NSNull(), "sourceUrl": NSNull(), "license": NSNull(),
      "licenseUrl": NSNull(), "attribution": NSNull()
    ]
    return try JSONDecoder().decode(QFRecipeHomeDetail.self, from: JSONSerialization.data(withJSONObject: object))
  }

  private func layout(_ page: UIViewController) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.main.async {
        page.view.window?.setNeedsLayout()
        page.view.window?.layoutIfNeeded()
        page.view.layoutIfNeeded()
        continuation.resume()
      }
    }
  }

  private func withPage(
    _ language: String = "zh-Hans",
    planned: Bool = false,
    body: (QFHomeRecipeDetailViewController, QFRecipeHomeDetail) async throws -> Void
  ) async throws {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
    else { throw XCTSkip("A foreground host scene is required") }
    QFRecipeLayoutOfflineProtocol.reset()
    let token = UUID().uuidString.lowercased(), service = "QFRecipeDetailLayoutTests." + UUID().uuidString
    let host = "recipe-layout-\(token).invalid"
    let identity = QFDeviceIdentity(service: service)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QFRecipeLayoutOfflineProtocol.self]
    let api = QFAPIClient(
      environment: QFAPIEnvironment(name: service, baseURL: URL(string: "https://\(host)/api/v1")),
      identity: identity, transportConfiguration: configuration)
    api.recordsRequests = false
    let app = QFAppSession(api: api, identity: identity, keychain: QFKeychainStore(service: service))
    app.setInterfaceLanguage(language)
    let detail = try fixture(language)
    let page = QFHomeRecipeDetailViewController(app: app, initial: detail.listItem) { _ in }
    // Must bypass initial reads before any access that loads the view; no login or Keychain setup.
    let plans = planned ? [try JSONDecoder().decode(QFPlannedMeal.self, from: JSONSerialization.data(withJSONObject: [
      "id": "d0700000-0000-4000-8000-000000000002", "recipeId": detail.id,
      "date": "2026-10-28", "meal": "DINNER", "servings": 2
    ]))] : []
    page.debugInstallLoadedRecipeFixture(detail, plans: plans)
    let container = UIViewController(), window = UIWindow(windowScene: scene)
    window.rootViewController = container
    container.addChild(page)
    container.view.addSubview(page.view)
    page.view.snp.makeConstraints {
      $0.top.bottom.equalToSuperview()
      $0.centerX.equalTo(container.view.safeAreaLayoutGuide.snp.centerX)
      $0.width.equalTo(390)
    }
    page.didMove(toParent: container)
    window.isHidden = false
    defer {
      window.isHidden = true
      page.willMove(toParent: nil); page.view.removeFromSuperview(); page.removeFromParent()
      window.rootViewController = nil
    }
    await layout(page)
    guard container.view.safeAreaLayoutGuide.layoutFrame.width >= 389.5,
      page.view.bounds.height > 300
    else { throw XCTSkip("The host scene cannot contain the 390pt reference viewport") }
    XCTAssertEqual(page.view.bounds.width, 390, accuracy: 0.5)
    XCTAssertEqual(QFRecipeLayoutOfflineProtocol.count(), 0)
    try await body(page, detail)
    await layout(page)
    XCTAssertEqual(QFRecipeLayoutOfflineProtocol.count(), 0, "Fixture/expansion/resize must not request data")
  }

  private func visibleLabels(_ view: UIView) -> [UILabel] {
    guard !view.isHidden, view.alpha > 0.01 else { return [] }
    return (view as? UILabel).map { [$0] } ?? view.subviews.flatMap(visibleLabels)
  }
  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }
  private func assertUnhidden(_ view: UIView) {
    var current: UIView? = view
    while let value = current {
      XCTAssertFalse(value.isHidden); XCTAssertGreaterThan(value.alpha, 0.01)
      current = value.superview
    }
  }
  private func footer(_ page: UIViewController) throws -> UIStackView {
    try XCTUnwrap(page.view.subviews.compactMap { $0 as? UIStackView }.first {
      $0.arrangedSubviews.compactMap { $0 as? UIButton }.count == 2
    })
  }
  private func expand(_ page: UIViewController) async throws {
    let button = try XCTUnwrap(descendants(page.view).compactMap { $0 as? UIButton }.first {
      $0.accessibilityIdentifier == "recipe.detail.directions.expand"
    })
    assertUnhidden(button)
    XCTAssertTrue(button.isEnabled)
    button.sendActions(for: .touchUpInside)
    await layout(page)
  }
  private func assertBodies(_ detail: QFRecipeHomeDetail, in page: UIViewController, shown: Bool) {
    let texts = visibleLabels(page.view).compactMap(\.text)
    for step in detail.steps { XCTAssertEqual(texts.contains(step.body), shown, step.title) }
  }

  func testReferenceFooterKeepsSecondary96Primary242AndHeight48() async throws {
    try await withPage { page, _ in
      let bar = try self.footer(page), buttons = bar.arrangedSubviews.compactMap { $0 as? UIButton }
      let scroll = try XCTUnwrap(page.view.subviews.compactMap { $0 as? UIScrollView }.first)
      XCTAssertFalse(bar.isDescendant(of: scroll))
      XCTAssertEqual(bar.frame.minX, 20, accuracy: 0.5)
      XCTAssertEqual(bar.frame.width, 350, accuracy: 0.5)
      XCTAssertEqual(buttons[0].frame.width, 96, accuracy: 0.5)
      XCTAssertEqual(buttons[1].frame.width, 242, accuracy: 0.5)
      for button in buttons { XCTAssertEqual(button.frame.height, 48, accuracy: 0.5) }
    }
  }

  func testFourLongMaterialRowsShareOneRoundedSurfaceCard() async throws {
    try await withPage { page, detail in
      let labels = self.visibleLabels(page.view)
      let names = try detail.materials.map { material in
        try XCTUnwrap(labels.first { $0.text == material.name })
      }
      XCTAssertEqual(names.count, 4)
      let cards = try names.map { label -> UIView in
        var ancestor = label.superview
        while let view = ancestor, view !== page.view {
          if view.layer.cornerRadius > 0 { return view }
          ancestor = view.superview
        }
        return try XCTUnwrap(nil as UIView?, "Material must belong to a rounded card")
      }
      XCTAssertTrue(cards.allSatisfy { $0 === cards[0] }, "Four rows must share one card")
      XCTAssertEqual(cards[0].backgroundColor, QFUI.surface)
      for index in 1..<names.count {
        let previous = names[index - 1].convert(names[index - 1].bounds, to: cards[0])
        let next = names[index].convert(names[index].bounds, to: cards[0])
        XCTAssertGreaterThanOrEqual(next.minY + 0.5, previous.maxY)
      }
    }
  }

  func testDirectionsInitiallyHideAllThreeOperationBodies() async throws {
    try await withPage("en") { page, detail in
      self.assertBodies(detail, in: page, shown: false)
      let entry = try XCTUnwrap(self.descendants(page.view).compactMap { $0 as? UIButton }.first {
        $0.accessibilityIdentifier == "recipe.detail.directions.expand"
      })
      self.assertUnhidden(entry)
      XCTAssertTrue(entry.isEnabled)
    }
  }

  func testExpansionStaysOnPageAndFooterDoesNotScroll() async throws {
    try await withPage("en") { page, detail in
      let parent = page.parent, navigation = page.navigationController
      let bar = try self.footer(page), before = bar.convert(bar.bounds, to: page.view)
      try await self.expand(page)
      self.assertBodies(detail, in: page, shown: true)
      XCTAssertTrue(page.parent === parent)
      XCTAssertTrue(page.navigationController === navigation)
      XCTAssertNil(page.presentedViewController)
      let scroll = try XCTUnwrap(page.view.subviews.compactMap { $0 as? UIScrollView }.first)
      scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top,
        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
      await self.layout(page)
      let after = bar.convert(bar.bounds, to: page.view)
      XCTAssertEqual(after.minY, before.minY, accuracy: 0.5)
      XCTAssertEqual(after.height, before.height, accuracy: 0.5)
      let last = try XCTUnwrap(self.visibleLabels(page.view).first { $0.text == detail.steps[2].body })
      XCTAssertTrue(scroll.bounds.insetBy(dx: -0.5, dy: -0.5).contains(last.convert(last.bounds, to: scroll)))
    }
  }

  func testExpandedBodiesSurvive320To390AndAsymmetricSafeAreas() async throws {
    try await withPage { page, detail in
      try await self.expand(page)
      for (width, left, right): (CGFloat, CGFloat, CGFloat) in [(320, 12, 20), (390, 20, 8), (390, 0, 0)] {
        page.additionalSafeAreaInsets = .zero
        page.view.snp.updateConstraints { $0.width.equalTo(width) }
        await self.layout(page)
        let baseline = page.view.safeAreaLayoutGuide.layoutFrame
        page.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: left, bottom: 0, right: right)
        await self.layout(page)
        let safe = page.view.safeAreaLayoutGuide.layoutFrame, bar = try self.footer(page)
        XCTAssertEqual(safe.minX, baseline.minX + left, accuracy: 0.5)
        XCTAssertEqual(safe.maxX, baseline.maxX - right, accuracy: 0.5)
        XCTAssertEqual(bar.frame.minX, safe.minX + 20, accuracy: 0.5)
        XCTAssertEqual(bar.frame.maxX, safe.maxX - 20, accuracy: 0.5)
        self.assertBodies(detail, in: page, shown: true)
      }
    }
  }

  func testLongActionTitlesRemainReadableAtAccessibilityTextSize() async throws {
    try await withPage("en") { page, _ in
      let container = try XCTUnwrap(page.parent)
      let bar = try self.footer(page)
      let buttons = bar.arrangedSubviews.compactMap { $0 as? UIButton }
      container.setOverrideTraitCollection(
        UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
        forChild: page)
      page.view.snp.updateConstraints { $0.width.equalTo(320) }
      // Exercise the supported caption inputs without changing the fixture's
      // content locale, session, or making favorite/plan mutations.
      for locale in ["zh-Hans", "zh-Hant", "en", "ja", "ko", "ru", "es", "fr", "de", "pt-BR"] {
        let language = QFInterfaceLanguage.normalized(locale)
        for selected in [false, true] {
          buttons[0].setTitle(selected
            ? language.text(chinese: "取消收藏", english: "Unfavorite")
            : language.text(chinese: "收藏", english: "Favorite"), for: .normal)
          buttons[1].setTitle(selected
            ? language.text(chinese: "已加入计划", english: "Planned")
            : language.text(chinese: "加入计划", english: "Add to plan"), for: .normal)
          await self.layout(page)
          let safe = page.view.safeAreaLayoutGuide.layoutFrame
          XCTAssertGreaterThanOrEqual(bar.frame.minY + 0.5, safe.minY, locale)
          XCTAssertLessThanOrEqual(bar.frame.maxY, safe.maxY + 0.5, locale)
          XCTAssertGreaterThanOrEqual(buttons[1].frame.width + 0.5, buttons[0].frame.width, locale)
          for button in buttons {
            let label = try XCTUnwrap(button.titleLabel)
            XCTAssertGreaterThan(label.font.pointSize, 16, locale)
            XCTAssertGreaterThan(label.bounds.width, 0, locale)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, locale)
            XCTAssertGreaterThanOrEqual(button.frame.height, 48, locale)
            let rect = label.convert(label.bounds, to: button)
            XCTAssertGreaterThanOrEqual(rect.minX, -0.5, locale)
            XCTAssertGreaterThanOrEqual(rect.minY, -0.5, locale)
            XCTAssertLessThanOrEqual(rect.maxX, button.bounds.width + 0.5, locale)
            XCTAssertLessThanOrEqual(rect.maxY, button.bounds.height + 0.5, locale)
            let required = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
            XCTAssertLessThanOrEqual(required.height, label.bounds.height + 0.5, locale)
          }
        }
      }
    }
  }

  func testFooterStateColorsAndDisabledAppearance() async throws {
    for planned in [false, true] {
      try await withPage(planned: planned) { page, _ in
        let buttons = try self.footer(page).arrangedSubviews.compactMap { $0 as? UIButton }
        XCTAssertEqual(buttons[1].currentTitle, planned ? "已加入计划" : "加入计划")
        for (button, expected) in zip(buttons, [QFUI.text, planned ? QFUI.primary : QFUI.onPrimary]) {
          let label = try XCTUnwrap(button.titleLabel)
          func displayedColor() -> UIColor {
            (label.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
              ?? label.textColor).resolvedColor(with: button.traitCollection)
          }
          let enabledColor = displayedColor()
          XCTAssertEqual(enabledColor, expected.resolvedColor(with: button.traitCollection), "planned=\(planned)")
          button.isEnabled = false
          await self.layout(page)
          XCTAssertTrue(displayedColor() != enabledColor || label.alpha < 0.99 || button.alpha < 0.99,
            "Disabled action must have a visible disabled appearance; planned=\(planned)")
          button.isEnabled = true
          await self.layout(page)
          XCTAssertEqual(displayedColor(), enabledColor)
        }
      }
    }
  }
}
#endif
