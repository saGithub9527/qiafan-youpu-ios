import Foundation
import MJRefresh
import SnapKit
import UIKit
import XCTest

@testable import QiafanYoupu

#if DEBUG
private final class QFIngredientLayoutOfflineProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var requests = 0
  static func count() -> Int { lock.lock(); defer { lock.unlock() }; return requests }
  static func reset() { lock.lock(); defer { lock.unlock() }; requests = 0 }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock(); Self.requests += 1; Self.lock.unlock()
    client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
  }
  override func stopLoading() {}
}

@MainActor
private final class QFInventoryLayoutPageGate {
  struct Read {
    let page: Int
    let category: String?
    let query: String
    let expiry: String?
    let householdID: String?
  }
  private(set) var reads: [Read] = []
  private var pending: CheckedContinuation<QFContentPage<QFInventoryLot>, Error>?
  private var closed = false
  func read(_ page: Int, _ category: String?, _ query: String, _ expiry: String?, _ householdID: String?) async throws -> QFContentPage<QFInventoryLot> {
    try Task.checkCancellation()
    guard !closed else { throw CancellationError() }
    reads.append(Read(page: page, category: category, query: query, expiry: expiry, householdID: householdID))
    guard page == 1, pending == nil else { throw URLError(.badServerResponse) }
    return try await withCheckedThrowingContinuation { pending = $0 }
  }
  func finish(_ result: QFContentPage<QFInventoryLot>) {
    let continuation = pending; pending = nil
    continuation?.resume(returning: result)
  }
  func cancelPending() {
    closed = true
    let continuation = pending; pending = nil
    continuation?.resume(throwing: CancellationError())
  }
}

@MainActor
final class QFIngredientLayoutTests: XCTestCase {
  private func layout(_ page: UIViewController) async {
    // Axis changes in viewDidLayoutSubviews invalidate nested stack constraints.
    // Observe the following UIKit pass before measuring the arranged views.
    for _ in 0..<2 {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async {
          page.view.window?.setNeedsLayout()
          page.view.window?.layoutIfNeeded()
          page.view.setNeedsLayout()
          page.view.layoutIfNeeded()
          continuation.resume()
        }
      }
    }
  }

  private func withPage(
    _ language: String,
    configure: ((QFIngredientViewController) throws -> Void)? = nil,
    body: (QFIngredientViewController) async throws -> Void
  ) async throws {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
    else { throw XCTSkip("A foreground host scene is required") }
    QFIngredientLayoutOfflineProtocol.reset()
    let service = "QFIngredientLayoutTests." + UUID().uuidString
    let identity = QFDeviceIdentity(service: service)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QFIngredientLayoutOfflineProtocol.self]
    let api = QFAPIClient(
      environment: QFAPIEnvironment(name: service,
        baseURL: URL(string: "https://inventory-layout-\(UUID().uuidString.lowercased()).invalid/api/v1")),
      identity: identity, transportConfiguration: configuration)
    api.recordsRequests = false
    let app = QFAppSession(api: api, identity: identity, keychain: QFKeychainStore(service: service))
    app.setInterfaceLanguage(language)
    let page = QFIngredientViewController(app: app)
    if let configure { try configure(page) } else { page.debugUseReadFreeLayoutFixture() }
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
    XCTAssertEqual(QFIngredientLayoutOfflineProtocol.count(), 0)
    try await body(page)
    await layout(page)
    XCTAssertEqual(QFIngredientLayoutOfflineProtocol.count(), 0,
      "Page-level fixture must not call authentication, unit metadata or HTTP transport")
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func assertDiscoveryReadable(_ language: String) async throws {
    try await withPage(language) { page in
      let discovery = try XCTUnwrap(page.contentStack.arrangedSubviews.compactMap { $0 as? UIStackView }.first {
        $0.arrangedSubviews.count == 2 && $0.arrangedSubviews.allSatisfy { $0 is UIButton }
      })
      let buttons = discovery.arrangedSubviews.compactMap { $0 as? UIButton }
      let search = try XCTUnwrap(self.descendants(page.view).compactMap { $0 as? UITextField }.first)
      search.text = "layout fixture"
      for (width, left, right): (CGFloat, CGFloat, CGFloat) in [
        (390, 0, 0), (390, 40, 20), (390, 80, 20), (390, 12, 100), (320, 0, 0), (390, 0, 0),
      ] {
        page.additionalSafeAreaInsets = .zero
        page.view.snp.updateConstraints { $0.width.equalTo(width) }
        await self.layout(page)
        let baseline = page.view.safeAreaLayoutGuide.layoutFrame
        page.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: left, bottom: 0, right: right)
        await self.layout(page)
        let safe = page.view.safeAreaLayoutGuide.layoutFrame
        let context = "\(language) view=\(width) insets=\(left)/\(right) axis=\(discovery.axis.rawValue)"
        print("D06 geometry: \(context) scroll=\(page.scrollView.bounds.width)")
        XCTAssertEqual(page.view.bounds.width, width, accuracy: 0.5, context)
        XCTAssertEqual(safe.minX, baseline.minX + left, accuracy: 0.5, context)
        XCTAssertEqual(safe.maxX, baseline.maxX - right, accuracy: 0.5, context)
        XCTAssertEqual(page.scrollView.frame.minX, safe.minX, accuracy: 0.5, context)
        XCTAssertEqual(page.scrollView.frame.maxX, safe.maxX, accuracy: 0.5, context)
        XCTAssertEqual(search.text, "layout fixture")
        XCTAssertTrue(page.parent != nil)
        XCTAssertNil(page.presentedViewController)
        XCTAssertFalse(buttons[0].frame.intersects(buttons[1].frame), context)
        for button in buttons {
          XCTAssertGreaterThanOrEqual(button.bounds.height, 44, context)
          XCTAssertFalse(button.isHidden)
          XCTAssertTrue(button.isEnabled)
          XCTAssertNotNil(button.accessibilityLabel)
          let rect = button.convert(button.bounds, to: discovery)
          XCTAssertGreaterThanOrEqual(rect.minX, -0.5, context)
          XCTAssertGreaterThanOrEqual(rect.minY, -0.5, context)
          XCTAssertLessThanOrEqual(rect.maxX, discovery.bounds.width + 0.5, context)
          XCTAssertLessThanOrEqual(rect.maxY, discovery.bounds.height + 0.5, context)
          let labels = self.descendants(button).compactMap { $0 as? UILabel }.filter { !($0.text ?? "").isEmpty }
          XCTAssertEqual(labels.count, 2, context)
          for label in labels {
            let frame = label.convert(label.bounds, to: button)
            XCTAssertGreaterThan(label.bounds.width, 0, context)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, context)
            XCTAssertGreaterThanOrEqual(frame.minY, -0.5, context)
            XCTAssertLessThanOrEqual(frame.maxX, button.bounds.width + 0.5, context)
            XCTAssertLessThanOrEqual(frame.maxY, button.bounds.height + 0.5, context)
            let fullText = UILabel()
            fullText.font = label.font; fullText.text = label.text
            fullText.numberOfLines = 0; fullText.lineBreakMode = .byWordWrapping
            let required = fullText.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
            var metrics = "button=\(button.bounds.size) titleWidth=\(label.bounds.width)"
            if let heading = label.superview as? UIStackView,
              heading.arrangedSubviews.count >= 2, heading.arrangedSubviews.first === label,
              let icon = heading.arrangedSubviews.last {
              let spacerWidth = heading.arrangedSubviews.count == 3 ? heading.arrangedSubviews[1].bounds.width : 0
              metrics += " headingWidth=\(heading.bounds.width) spacerWidth=\(spacerWidth) iconWidth=\(icon.bounds.width) intrinsic=\(label.intrinsicContentSize) preferredMax=\(label.preferredMaxLayoutWidth) hugging=\(label.contentHuggingPriority(for: .horizontal).rawValue)"
              if page.scrollView.bounds.width < 360 { print("D06 title: \(context) \(metrics)") }
            }
            XCTAssertLessThanOrEqual(required.height, label.bounds.height + 0.5,
              "\(context) text=\(label.text ?? "") \(metrics)")
          }
        }
      }
    }
  }

  func testChineseDiscoveryTextFitsAfterSafeAreaAndWidthChanges() async throws {
    try await assertDiscoveryReadable("zh-Hans")
  }

  func testEnglishDiscoveryTextFitsAfterSafeAreaAndWidthChanges() async throws {
    try await assertDiscoveryReadable("en")
  }

  private func lot(_ index: Int, revision: Int = 0) -> QFInventoryLot {
    let suffix = String(format: "%012d", index)
    return QFInventoryLot(
      id: "d0600000-0000-4000-8000-\(suffix)", ingredientId: "d0600000-0000-4000-9000-\(suffix)",
      ingredientName: "Inventory layout fixture \(index)", mediaId: nil, contentAvailable: true,
      categoryCode: "VEGETABLE", unitCode: "g", initialQuantity: "100", currentQuantity: "100",
      expiresOn: nil, location: "fridge", householdId: nil, status: "ACTIVE", revision: revision)
  }

  private func waitUntil(_ predicate: () -> Bool) async {
    for _ in 0..<40 {
      if predicate() { return }
      try? await Task.sleep(nanoseconds: 25_000_000)
    }
  }

  func testLoadedInventoryResizePreservesRowsOffsetAndPageWithoutRead() async throws {
    let gate = QFInventoryLayoutPageGate()
    defer { gate.cancelPending() }
    let page0 = QFContentPage(items: (0..<15).map { lot($0) }, total: 17)
    try await withPage("en", configure: { page in
      page.debugInstallLoadedInventoryFixture(page0, readPage: gate.read)
    }) { page in
      let list = try XCTUnwrap(self.descendants(page.view).compactMap { $0 as? UIStackView }.first {
        $0.accessibilityIdentifier == "ingredient.list"
      })
      let rowObjects = list.arrangedSubviews.map(ObjectIdentifier.init)
      XCTAssertEqual(rowObjects.count, 15)
      XCTAssertGreaterThan(page.scrollView.contentSize.height, page.scrollView.bounds.height + 600)
      page.scrollView.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
      await self.layout(page)
      let offset = page.scrollView.contentOffset.y
      let anchorRow = try XCTUnwrap(list.arrangedSubviews.dropFirst(3).first)
      let firstRowTop = anchorRow.convert(.zero, to: page.scrollView).y - offset
      for (width, left, right, bottom): (CGFloat, CGFloat, CGFloat, CGFloat) in [
        (390, 40, 20, 0), (320, 0, 0, 80), (390, 0, 0, 0),
      ] {
        page.view.snp.updateConstraints { $0.width.equalTo(width) }
        page.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: left, bottom: bottom, right: right)
        await self.layout(page)
        let snapshot = page.debugInventoryLayoutSnapshot()
        XCTAssertEqual(snapshot.items.map(\.id), page0.items.map(\.id))
        XCTAssertEqual(snapshot.nextPage, 1); XCTAssertEqual(snapshot.total, 17)
        XCTAssertFalse(snapshot.loading); XCTAssertTrue(snapshot.hasMore)
        XCTAssertEqual(list.arrangedSubviews.map(ObjectIdentifier.init), rowObjects)
        XCTAssertEqual(page.scrollView.contentOffset.y, offset, accuracy: 0.5)
        XCTAssertTrue(gate.reads.isEmpty, "Size-only layout at a stable offset must not read another page")
        let anchorTop = anchorRow.convert(.zero, to: page.scrollView).y - page.scrollView.contentOffset.y
        print("D06 loaded layout: width=\(width), viewport=\(page.scrollView.bounds.size), offset=\(page.scrollView.contentOffset.y), anchorDelta=\(anchorTop - firstRowTop), pageReads=\(gate.reads.count)")
      }
    }
  }

  func testAutoFooterReadRemainsSingleDuringResizeAndMergesFinalPage() async throws {
    let gate = QFInventoryLayoutPageGate()
    defer { gate.cancelPending() }
    let page0 = QFContentPage(items: (0..<15).map { lot($0) }, total: 17)
    let page1 = QFContentPage(items: [lot(14, revision: 1), lot(15), lot(16)], total: 17)
    try await withPage("en", configure: { page in
      page.debugInstallLoadedInventoryFixture(page0, readPage: gate.read)
    }) { page in
      let footer = try XCTUnwrap(page.scrollView.mj_footer)
      XCTAssertFalse(footer.isHidden)
      XCTAssertTrue(gate.reads.isEmpty, "Already-loaded fixture does not prove page0 transport")
      let bottom = page.scrollView.contentSize.height - page.scrollView.bounds.height
        + page.scrollView.adjustedContentInset.bottom
      page.scrollView.setContentOffset(CGPoint(x: 0, y: bottom + 40), animated: false)
      await self.waitUntil { gate.reads.count == 1 }
      XCTAssertEqual(gate.reads.count, 1, "Real MJRefresh offset observation should request page1")
      XCTAssertTrue(page.debugInventoryLayoutSnapshot().loading)
      XCTAssertEqual(gate.reads.first?.page, 1)
      XCTAssertNil(gate.reads.first?.category); XCTAssertEqual(gate.reads.first?.query, "")
      XCTAssertNil(gate.reads.first?.expiry); XCTAssertNil(gate.reads.first?.householdID)
      for width: CGFloat in [320, 390, 320, 390] {
        page.view.snp.updateConstraints { $0.width.equalTo(width) }
        await self.layout(page)
        XCTAssertEqual(gate.reads.count, 1, "Pending page1 and resize must not create concurrent reads")
      }
      gate.finish(page1)
      await self.waitUntil { !page.debugInventoryLayoutSnapshot().loading }
      await self.layout(page)
      let snapshot = page.debugInventoryLayoutSnapshot()
      XCTAssertEqual(snapshot.items.count, 17)
      XCTAssertEqual(Set(snapshot.items.map(\.id)).count, 17)
      XCTAssertEqual(snapshot.items.map(\.id), (0..<17).map { self.lot($0).id })
      XCTAssertEqual(snapshot.items.first { $0.id == self.lot(14).id }?.revision, 1)
      XCTAssertEqual(snapshot.nextPage, 2); XCTAssertFalse(snapshot.hasMore)
      XCTAssertEqual(footer.state, .noMoreData)
      page.view.snp.updateConstraints { $0.width.equalTo(320) }
      await self.layout(page)
      page.scrollView.setContentOffset(CGPoint(x: 0, y: page.scrollView.contentSize.height + 40), animated: false)
      await self.layout(page)
      XCTAssertEqual(gate.reads.count, 1, "Exhausted data must not request another page after resize/offset changes")
    }
  }
}
#endif
