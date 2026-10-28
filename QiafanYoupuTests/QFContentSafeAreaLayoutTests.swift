import UIKit
import XCTest

@testable import QiafanYoupu

private final class QFLayoutOfflineProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
  }
  override func stopLoading() {}
}

@MainActor
final class QFContentSafeAreaLayoutTests: XCTestCase {
  private func mounted(
    _ controller: UIViewController, body: () async throws -> Void
  ) async throws {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
    else { throw XCTSkip("A foreground host scene is required for UIKit layout checks") }
    let window = UIWindow(windowScene: scene)
    window.rootViewController = controller
    window.isHidden = false
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }
    await finishLayout(controller)
    guard controller.view.bounds.width > 100, controller.view.bounds.height > 100
    else { throw XCTSkip("The host scene has not supplied a usable viewport") }
    try await body()
  }

  private func finishLayout(_ controller: UIViewController) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.main.async {
        controller.view.window?.setNeedsLayout()
        controller.view.window?.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        continuation.resume()
      }
    }
  }

  private func setHorizontalInsets(_ left: CGFloat, _ right: CGFloat, baseline: CGRect, on controller: UIViewController) async {
    controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: left, bottom: 0, right: right)
    controller.view.setNeedsLayout()
    await finishLayout(controller)
    let available = controller.view.safeAreaLayoutGuide.layoutFrame
    XCTAssertEqual(available.minX, baseline.minX + left, accuracy: 0.5, "Fixture inset must take effect")
    XCTAssertEqual(available.maxX, baseline.maxX - right, accuracy: 0.5, "Fixture inset must take effect")
  }

  private func assertContained(_ element: UIView, in controller: UIViewController, file: StaticString = #filePath, line: UInt = #line) {
    let available = controller.view.safeAreaLayoutGuide.layoutFrame
    XCTAssertEqual(element.frame.midX, available.midX, accuracy: 0.5, file: file, line: line)
    XCTAssertEqual(element.frame.width, min(620, available.width - 40), accuracy: 0.5, file: file, line: line)
    XCTAssertGreaterThanOrEqual(element.frame.minX + 0.5, available.minX + 20, file: file, line: line)
    XCTAssertLessThanOrEqual(element.frame.maxX - 0.5, available.maxX - 20, file: file, line: line)
  }

  func testHeaderTracksAsymmetricSafeAreaChanges() async throws {
    let controller = UIViewController()
    controller.loadViewIfNeeded()
    let header = UIView()
    QFSettingsPageUI.installHeader(header, in: controller.view)
    try await mounted(controller) {
      let baseline = controller.view.safeAreaLayoutGuide.layoutFrame
      for (left, right): (CGFloat, CGFloat) in [(80, 20), (12, 100), (0, 0)] {
        await setHorizontalInsets(left, right, baseline: baseline, on: controller)
        assertContained(header, in: controller)
      }
    }
  }

  func testNoAdditionalInsetsRetainExistingSafeAreaPadding() async throws {
    let controller = UIViewController()
    controller.loadViewIfNeeded()
    let header = UIView()
    QFSettingsPageUI.installHeader(header, in: controller.view)
    try await mounted(controller) {
      let baseline = controller.view.safeAreaLayoutGuide.layoutFrame
      await setHorizontalInsets(0, 0, baseline: baseline, on: controller)
      assertContained(header, in: controller)
    }
  }

  func testFooterTracksSafeAreaWithoutChangingInputOrInvokingSave() async throws {
    let service = "QFContentSafeAreaLayoutTests." + UUID().uuidString
    let identity = QFDeviceIdentity(service: service)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QFLayoutOfflineProtocol.self]
    let api = QFAPIClient(
      environment: QFAPIEnvironment(name: service, baseURL: URL(string: "https://layout.invalid/api/v1")),
      identity: identity, transportConfiguration: configuration)
    #if DEBUG
      api.recordsRequests = false
    #endif
    let store = QFKeychainStore(service: service)
    // Construction does not start sign-in or write credentials; this fixture only lays out views.
    let page = QFProfileContentController(
      app: QFAppSession(api: api, identity: identity, keychain: store), title: "Layout")
    page.loadViewIfNeeded()
    let field = UITextField()
    field.text = "73.50"
    page.bodyStack.addArrangedSubview(field)
    var saves = 0
    let button = page.addFooter("Save") { saves += 1 }
    try await mounted(page) {
      let baseline = page.view.safeAreaLayoutGuide.layoutFrame
      for (left, right): (CGFloat, CGFloat) in [(80, 20), (12, 100), (0, 0)] {
        await setHorizontalInsets(left, right, baseline: baseline, on: page)
        assertContained(page.footer, in: page)
        XCTAssertEqual(field.text, "73.50")
        XCTAssertTrue(page.footer.arrangedSubviews.contains { $0 === button })
        XCTAssertEqual(saves, 0)
      }
      button.sendActions(for: .touchUpInside)
      XCTAssertEqual(saves, 1)
    }
  }
}
