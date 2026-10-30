import UIKit

/// Retained class name keeps existing navigation and network preference callers compatible.
@MainActor
final class QFLocalModelViewController: UITableViewController {
  private let app: QFAppSession
  private let models: [String]
  static func networkKey(_ app: QFAppSession) -> String { QFAssistantNetworkPreference.key(scope: app.contentScope) }
  static func networkEnabled(_ app: QFAppSession) -> Bool { QFAssistantNetworkPreference.isEnabled(key: networkKey(app)) }
  init(app: QFAppSession) {
    self.app = app
    let gemini = QFAssistantProvider.gemini.available(in: app.configuration?.assistantCapabilities?.chatProviders,
      processingRegion: app.configuration?.assistantCapabilities?.chatProviderRegions?["GEMINI"])
    models = (gemini ? ["Gemini 3.8 Flash"] : []) + ["GLM-4.7-Flash", "GLM-4.6V-Flash", "DeepSeek"]
    super.init(style: .insetGrouped)
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    title = app.text("模型管理", "Manage model")
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: app.text("关闭", "Close"), style: .done, target: self, action: #selector(close))
  }
  @objc private func close() { dismiss(animated: true) }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { models.count }
  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    app.text("问答需要联网。本地千问暂时停用，已有模型文件和聊天记录保留。", "Chat requires internet. On-device Qwen is paused; existing model files and conversations are kept.")
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
    cell.textLabel?.adjustsFontForContentSizeCategory = true; cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
    cell.selectionStyle = .none
    let model = models[indexPath.row]; cell.textLabel?.text = model
    switch model {
    case "Gemini 3.8 Flash":
      cell.detailTextLabel?.text = app.text("文字和图片问答，使用云端额度或积分。", "Text and image chat using cloud allowance or credits.")
    case "GLM-4.7-Flash":
      cell.detailTextLabel?.text = app.text("免费文字问答，可手动选择。", "Free text chat, available as an option.")
    case "GLM-4.6V-Flash":
      cell.detailTextLabel?.text = app.text("免费图片理解；文字模型繁忙时也可接续回答。", "Free image understanding; also answers when the text model is busy.")
    default:
      cell.detailTextLabel?.text = app.text("可手动选择，使用云端额度或积分。", "Optional; uses cloud allowance or credits.")
    }
    return cell
  }
}
