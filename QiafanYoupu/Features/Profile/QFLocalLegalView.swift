import SafariServices
import SnapKit
import UIKit
import WebKit

/// Published bundled legal documents for offline reading from settings and sign-in flows.
@MainActor
final class QFLocalLegalViewController: UIViewController, WKNavigationDelegate {
  private let document: String
  private let heading: String
  private let language: QFInterfaceLanguage
  private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
  init(document: String, title: String, language: String = "zh-Hans") {
    self.document = document
    heading = title
    self.language = QFInterfaceLanguage.normalized(language)
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    let header = QFSettingsPageUI.header(
      heading, backLabel: language.text(chinese: "返回", english: "Back")
    ) { [weak self] in self?.qfClose() }
    QFSettingsPageUI.installHeader(header, in: view)
    view.addSubview(webView)
    webView.snp.makeConstraints {
      $0.top.equalTo(header.snp.bottom)
      $0.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
    }
    webView.navigationDelegate = self
    webView.isOpaque = false
    webView.backgroundColor = QFUI.background
    webView.accessibilityIdentifier = "legal.\(document)"
    let subdirectory = language == .simplifiedChinese ? "Legal" : "Legal/\(language.rawValue)"
    if let url = Bundle.main.url(
      forResource: document, withExtension: "html", subdirectory: subdirectory)
    {
      let legalRoot = Bundle.main.resourceURL?.appendingPathComponent("Legal", isDirectory: true)
        ?? url.deletingLastPathComponent()
      webView.loadFileURL(url, allowingReadAccessTo: legalRoot)
    } else {
      webView.loadHTMLString(
        "<meta name='viewport' content='width=device-width'><p>"
          + language.text(
            chinese: "文档暂时不可用，请联系 15871731171shuao@gmail.com。",
            english: "This document is temporarily unavailable. Contact 15871731171shuao@gmail.com.")
          + "</p>",
        baseURL: nil)
    }
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    if url.isFileURL || url.scheme == "about" {
      decisionHandler(.allow)
      return
    }
    decisionHandler(.cancel)
    guard navigationAction.navigationType == .linkActivated else { return }
    if url.scheme == "https" {
      present(SFSafariViewController(url: url), animated: true)
    } else if url.scheme == "mailto" {
      UIApplication.shared.open(url)
    }
  }
}
