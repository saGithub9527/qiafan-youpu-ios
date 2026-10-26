import Combine
import Kingfisher
import SnapKit
import UIKit

/// Existing device-local history only: no composer, provider, tool, or task restoration.
@MainActor
final class QFAssistantHistoryViewController: QFProfileContentController {
  private let binding: QFAgentScope
  private let history: QFAssistantConversationStore

  init(app: QFAppSession) {
    binding = QFAssistantAgent.scope(app)
    history = QFAssistantConversationStore(scope: binding)
    super.init(app: app, title: app.text("历史聊天记录", "Chat history"))
  }
  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    setReloadAction(allowsPullToRefresh: false) { [weak self] in self?.render() }
    app.$planningScope.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.checkScope() }.store(in: &cancellables)
    app.$interfaceLanguage.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.checkScope() }.store(in: &cancellables)
    render()
  }

  private func checkScope() {
    guard binding != QFAssistantAgent.scope(app) else { return }
    bodyStack.isHidden = true
    navigationController?.popToRootViewController(animated: false)
  }

  private func render() {
    guard app.user != nil, binding == QFAssistantAgent.scope(app) else { checkScope(); return }
    let messages = history.readOnlyMessages()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    formatter.dateStyle = .medium; formatter.timeStyle = .short
    bodyStack.beginUpdates()
    bodyStack.row("history.scope") { [app] in
      QFContentUI.label(app.text("仅显示当前账号、家庭和语言的历史记录，不发送新请求。", "Shows history for the current account, household, and language. No new requests are sent."), size: 13, color: QFUI.secondary)
    }
    if messages.isEmpty {
      bodyStack.row("history.empty") { [app] in
        QFContentUI.label(app.text("没有此范围的聊天记录。", "There is no chat history in this scope."), size: 15, color: QFUI.secondary)
      }
    }
    for message in messages {
      bodyStack.row(message.id.uuidString) { [self] in
        let role = message.role == "user" ? app.text("我的", "Me") : app.text("AI 助手", "AI assistant")
        var rows: [UIView] = [QFContentUI.label(role + " · " + formatter.string(from: message.createdAt), size: 12, color: QFUI.secondary)]
        if message.role != "user", let state = message.state, state != "complete" {
          rows.append(QFContentUI.label(state == "failed" ? app.text("生成失败", "Generation failed") : app.text("已停止生成", "Generation stopped"), size: 13, color: QFUI.secondary))
        }
        if !message.text.isEmpty { rows.append(QFContentUI.label(message.text)) }
        if let notice = message.notice, !notice.isEmpty { rows.append(QFContentUI.label(notice, size: 13, color: QFUI.secondary)) }
        for source in message.sources ?? [] {
          rows.append(QFContentUI.label([source.title, source.url].compactMap { $0 }.joined(separator: "\n"), size: 12, color: QFUI.secondary))
        }
        if let url = history.imageURL(message.imageID) {
          let image = UIImageView(); image.contentMode = .scaleAspectFit
          image.snp.makeConstraints { $0.height.equalTo(240) }
          image.kf.setImage(with: .provider(LocalFileImageDataProvider(fileURL: url)), options: [
            .processor(DownsamplingImageProcessor(size: CGSize(width: 600, height: 240))),
            .targetCache(QFContentImageCache.shared), .cacheMemoryOnly,
          ])
          rows.append(image)
        }
        return QFTabUI.card(QFTabUI.stack(rows, spacing: 10), padding: 16)
      }
    }
    bodyStack.endUpdates()
  }
}
