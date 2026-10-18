import Combine
import SafariServices
import UIKit

@MainActor
final class QFLocalModelViewController: UITableViewController {
  private let app: QFAppSession
  private let store = QFLocalModelStore.shared
  private var observation: AnyCancellable?
  static func networkKey(_ app: QFAppSession) -> String { QFAssistantNetworkPreference.key(scope: app.contentScope) }
  static func networkEnabled(_ app: QFAppSession) -> Bool { QFAssistantNetworkPreference.isEnabled(key: networkKey(app)) }

  init(app: QFAppSession) { self.app = app; super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    title = app.text("本地千问模型", "On-device Qwen model")
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: app.text("关闭", "Close"),
      style: .done, target: self, action: #selector(close))
    observation = store.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.tableView.reloadData() }
  }
  @objc private func close() { dismiss(animated: true) }
  override func numberOfSections(in tableView: UITableView) -> Int { 3 }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? 1 : (section == 1 ? 3 : 1)
  }
  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    if section == 0 {
      return app.format("模型约%.2f GB，首次使用需下载。安装后推理在手机上完成；模型不计入iCloud备份。", "The model is about %.2f GB and requires an initial download. Inference then runs on your phone; the model is excluded from iCloud backup.", Double(store.descriptor.bytes) / 1_000_000_000)
    }
    if section == 2 {
      return app.text("关闭时不查询网络数据。开启后可查询App数据；联网找资料仅发送本次问题，不发送聊天历史。模型下载需单独点击，不会自动切换云端推理。", "When off, no network data is fetched. When on, App data can be queried; reference searches send only the current question, not chat history. Model download needs a separate tap; inference never switches to the cloud automatically.")
    }
    return nil
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
    cell.textLabel?.adjustsFontForContentSizeCategory = true
    cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
    if indexPath.section == 0 {
      cell.textLabel?.text = "Qwen3.5-2B · " + store.descriptor.quantization
      switch store.state {
      case .absent: cell.detailTextLabel?.text = app.text("模型未安装或下载已暂停", "Model not installed or download paused")
      case .downloading(let progress): cell.detailTextLabel?.text = app.format("下载中：%d%%", "Downloading: %d%%", Int(progress * 100))
      case .verifying: cell.detailTextLabel?.text = app.text("正在校验模型完整性…", "Verifying model integrity…")
      case .ready: cell.detailTextLabel?.text = app.text("模型已校验，可离线使用", "Model verified; available offline")
      case .failed: cell.detailTextLabel?.text = app.text("安装未完成，请检查Wi-Fi、可用空间或重新下载。", "Installation incomplete. Check Wi-Fi and free space, or download again.")
      }
      cell.selectionStyle = .none
    } else if indexPath.section == 1 {
      if indexPath.row == 0 {
        if case .downloading = store.state { cell.textLabel?.text = app.text("暂停下载", "Pause download") }
        else { cell.textLabel?.text = app.text("下载模型（仅Wi-Fi）", "Download model (Wi-Fi only)") }
        cell.textLabel?.textColor = QFUI.primary
        cell.isUserInteractionEnabled = store.state != .ready && store.state != .verifying
        cell.textLabel?.alpha = cell.isUserInteractionEnabled ? 1 : 0.4
      } else if indexPath.row == 1 {
        cell.textLabel?.text = app.text("删除本地模型", "Delete on-device model")
        cell.textLabel?.textColor = .systemRed
      } else {
        cell.textLabel?.text = app.text("模型来源与许可证", "Model source and license")
        cell.accessoryType = .disclosureIndicator
      }
    } else {
      cell.textLabel?.text = app.text("允许本地助手联网查询", "Allow network lookups for local assistant")
      let toggle = UISwitch()
      toggle.isOn = Self.networkEnabled(app)
      toggle.accessibilityLabel = cell.textLabel?.text
      toggle.addTarget(self, action: #selector(changeNetwork(_:)), for: .valueChanged)
      cell.accessoryView = toggle; cell.selectionStyle = .none
    }
    return cell
  }
  @objc private func changeNetwork(_ sender: UISwitch) {
    UserDefaults.standard.set(sender.isOn, forKey: Self.networkKey(app))
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard indexPath.section == 1 else { return }
    if indexPath.row == 0 {
      if case .downloading = store.state { store.pause() } else { store.download() }
    } else if indexPath.row == 1 {
      let alert = UIAlertController(title: app.text("删除本地模型", "Delete on-device model"),
        message: app.text("仅删除下载的模型文件，对话和账号数据不会删除。", "Only the downloaded model is deleted. Conversations and account data are kept."), preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
      alert.addAction(UIAlertAction(title: app.text("删除", "Delete"), style: .destructive) { [weak self] _ in self?.store.delete() })
      present(alert, animated: true)
    } else { present(SFSafariViewController(url: store.descriptor.licenseURL), animated: true) }
  }
}
