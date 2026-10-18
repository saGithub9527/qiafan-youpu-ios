import SnapKit
import UIKit
import WebKit

public enum QFOrbMode: String, CaseIterable { case calm, flow, spark }
public enum QFOrbDisplayState: Equatable { case loading, ready, failed }

/// Displays the approved light orb from package resources. No server or
/// remote page participates; the native button above this view owns touches.
@MainActor
public final class QFOrbView: UIView, WKNavigationDelegate {
  private let webView: WKWebView
  private let fallback = OrbFallbackView()
  private let messageHandler = WeakOrbMessageHandler()
  private let resourceRoot: URL?
  private var ready = false
  private var requestedRunning = false
  private var pendingPulse = false
  private var mode: QFOrbMode = .flow
  private var processReloads = 0
  private var needsProcessReload = false
  private var loadGeneration = 0
  private var currentNavigation: WKNavigation?
  private var readyDeadline: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  public private(set) var displayState: QFOrbDisplayState = .loading
  public var onDisplayStateChanged: (() -> Void)?

  public override init(frame: CGRect) {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.suppressesIncrementalRendering = true
    webView = WKWebView(frame: .zero, configuration: configuration)
    resourceRoot = Bundle.module.url(forResource: "Web", withExtension: nil)
    super.init(frame: frame)
    isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false
    webView.isOpaque = false; webView.backgroundColor = .clear
    webView.scrollView.backgroundColor = .clear
    webView.scrollView.isScrollEnabled = false
    webView.isUserInteractionEnabled = false
    webView.navigationDelegate = self
    messageHandler.owner = self
    configuration.userContentController.add(messageHandler, name: "qfOrb")
    addSubview(webView); webView.snp.makeConstraints { $0.edges.equalToSuperview() }
    addSubview(fallback); fallback.snp.makeConstraints { $0.edges.equalToSuperview() }
    fallback.isHidden = true
    let center = NotificationCenter.default
    for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                 UIAccessibility.reduceMotionStatusDidChangeNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in self?.applyState() }
      })
    }
    loadPage()
  }
  required init?(coder: NSCoder) { nil }

  deinit {
    readyDeadline?.cancel()
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "qfOrb")
    webView.navigationDelegate = nil
    webView.stopLoading()
  }

  public override func didMoveToWindow() { super.didMoveToWindow(); applyState() }
  public override func layoutSubviews() { super.layoutSubviews(); scheduleReadinessDeadline() }

  public func setMode(_ value: QFOrbMode) { mode = value; applyState() }
  public func setRendering(_ active: Bool) {
    requestedRunning = active
    if !active { pendingPulse = false }
    applyState()
  }
  public func pulse() {
    guard requestedRunning, shouldRender else { return }
    pendingPulse = true; applyState()
  }

  private var shouldRender: Bool {
    requestedRunning && window != nil && !isHidden &&
      window?.windowScene?.activationState == .foregroundActive &&
      UIApplication.shared.applicationState == .active
  }

  fileprivate func pageReady() {
    readyDeadline?.cancel(); readyDeadline = nil
    ready = true
    webView.isHidden = false
    fallback.setRendering(false); fallback.isHidden = true
    updateDisplayState(.ready)
    applyState()
  }

  fileprivate func pageFailed() {
    readyDeadline?.cancel(); readyDeadline = nil
    ready = false; webView.isHidden = true; fallback.isHidden = false
    updateDisplayState(.failed)
    applyState()
  }

  fileprivate func receive(kind: String, generation: Int) {
    guard generation == loadGeneration else { return }
    if kind == "ready" { pageReady() }
    else if kind == "error" { pageFailed() }
  }

  private func updateDisplayState(_ value: QFOrbDisplayState) {
    guard displayState != value else { return }
    displayState = value; onDisplayStateChanged?()
  }

  private func scheduleReadinessDeadline() {
    guard displayState == .loading, readyDeadline == nil, bounds.width > 0, bounds.height > 0,
      UIApplication.shared.applicationState == .active,
      window?.windowScene?.activationState == .foregroundActive else { return }
    let generation = loadGeneration
    readyDeadline = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
      guard let self, self.loadGeneration == generation, self.displayState == .loading else { return }
      self.readyDeadline = nil
      guard UIApplication.shared.applicationState == .active,
        self.window?.windowScene?.activationState == .foregroundActive else { return }
      self.pageFailed()
    }
  }

  private func applyState() {
    let active = shouldRender
    let reduceMotion = UIAccessibility.isReduceMotionEnabled
    if UIApplication.shared.applicationState != .active || window?.windowScene?.activationState != .foregroundActive {
      readyDeadline?.cancel(); readyDeadline = nil
    } else { scheduleReadinessDeadline() }
    fallback.setRendering(displayState == .failed && active && !reduceMotion)
    if needsProcessReload && active && processReloads < 1 {
      needsProcessReload = false; processReloads += 1
      loadPage(); return
    }
    guard ready else { return }
    let pulse = pendingPulse && active && !reduceMotion
    pendingPulse = false
    webView.callAsyncJavaScript(
      "window.QFOrb.configure(state); if (pulse) window.QFOrb.pulse();",
      arguments: ["state": ["active": active, "reduceMotion": reduceMotion, "mode": mode.rawValue], "pulse": pulse],
      in: nil, in: .page, completionHandler: nil)
  }

  private func loadPage() {
    readyDeadline?.cancel(); readyDeadline = nil
    loadGeneration += 1
    ready = false; webView.isHidden = false; fallback.isHidden = true
    fallback.setRendering(false); updateDisplayState(.loading)
    let content = webView.configuration.userContentController
    content.removeAllUserScripts()
    content.addUserScript(WKUserScript(source: "window.qfOrbLoadGeneration = \(loadGeneration);",
      injectionTime: .atDocumentStart, forMainFrameOnly: true))
    guard let resourceRoot else { pageFailed(); return }
    currentNavigation = webView.loadFileURL(resourceRoot.appendingPathComponent("index.html"), allowingReadAccessTo: resourceRoot)
    scheduleReadinessDeadline()
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    // The message is normally sent by the bundled script. This also handles a
    // ready message delivered before WebKit's navigation callback is installed.
    guard let navigation, let currentNavigation, navigation === currentNavigation else { return }
    let generation = loadGeneration
    webView.callAsyncJavaScript("return window.QFOrb?.isReady() === true;", arguments: [:], in: nil, in: .page) { [weak self] result in
      guard case .success(let value) = result, value as? Bool == true else { return }
      guard self?.loadGeneration == generation else { return }
      self?.pageReady()
    }
  }
  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    // Invalidate callbacks from the terminated document before a foreground reload.
    readyDeadline?.cancel(); readyDeadline = nil
    loadGeneration += 1; currentNavigation = nil; ready = false
    guard processReloads < 1 else { needsProcessReload = false; pageFailed(); return }
    fallback.isHidden = true; fallback.setRendering(false)
    updateDisplayState(.loading)
    needsProcessReload = true
    applyState()
  }
  public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    guard let navigation, let currentNavigation, navigation === currentNavigation else { return }; pageFailed()
  }
  public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    guard let navigation, let currentNavigation, navigation === currentNavigation else { return }; pageFailed()
  }
  public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url, let root = resourceRoot,
      url.isFileURL, url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    else { decisionHandler(.cancel); return }
    decisionHandler(.allow)
  }
}

@MainActor
private final class WeakOrbMessageHandler: NSObject, WKScriptMessageHandler {
  weak var owner: QFOrbView?
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
      let kind = body["kind"] as? String, let generation = body["generation"] as? Int else { return }
    owner?.receive(kind: kind, generation: generation)
  }
}

@MainActor
private final class OrbFallbackView: UIView {
  private let core = CAGradientLayer()
  private let ring = CAShapeLayer()
  private var running = false
  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false
    core.type = .radial
    core.colors = [UIColor(red: 7 / 255, green: 143 / 255, blue: 139 / 255, alpha: 1).cgColor,
                   UIColor(red: 35 / 255, green: 68 / 255, blue: 166 / 255, alpha: 1).cgColor,
                   UIColor(red: 16 / 255, green: 32 / 255, blue: 57 / 255, alpha: 1).cgColor]
    core.startPoint = CGPoint(x: 0.35, y: 0.3); core.endPoint = CGPoint(x: 1, y: 1)
    layer.addSublayer(core)
    ring.fillColor = UIColor.clear.cgColor
    ring.strokeColor = UIColor(red: 7 / 255, green: 143 / 255, blue: 139 / 255, alpha: 0.45).cgColor
    ring.lineWidth = 0.7; layer.addSublayer(ring)
  }
  required init?(coder: NSCoder) { nil }
  override func layoutSubviews() {
    super.layoutSubviews()
    let side = min(bounds.width, bounds.height) * 0.72
    CATransaction.begin(); CATransaction.setDisableActions(true)
    core.bounds = CGRect(x: 0, y: 0, width: side, height: side)
    core.position = CGPoint(x: bounds.midX, y: bounds.midY); core.cornerRadius = side / 2
    core.masksToBounds = true
    ring.frame = bounds
    ring.path = UIBezierPath(ovalIn: CGRect(x: bounds.midX - side * 0.57, y: bounds.midY - side * 0.57,
                                          width: side * 1.14, height: side * 1.14)).cgPath
    CATransaction.commit()
  }
  func setRendering(_ active: Bool) {
    guard active != running else { return }; running = active
    if !active { core.removeAllAnimations(); ring.removeAllAnimations(); return }
    let scale = CAKeyframeAnimation(keyPath: "transform.scale")
    scale.values = [1, 0.935, 1.025, 1]; scale.keyTimes = [0, 0.26, 0.59, 1]
    scale.duration = 3.4; scale.repeatCount = .infinity
    scale.calculationMode = .cubic
    core.add(scale, forKey: "heartbeat"); ring.add(scale, forKey: "heartbeat")
    let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
    rotation.fromValue = 0; rotation.toValue = Double.pi * 2
    rotation.duration = 48; rotation.repeatCount = .infinity
    core.add(rotation, forKey: "rotation")
    let light = CAKeyframeAnimation(keyPath: "opacity")
    light.values = [0.88, 0.88, 1, 0.88]; light.keyTimes = [0, 0.26, 0.59, 1]
    light.duration = 3.4; light.repeatCount = .infinity; light.calculationMode = .cubic
    core.add(light, forKey: "light")
  }
}
