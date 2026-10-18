import SnapKit
import UIKit

@MainActor
final class QFMembershipViewController: QFProfileContentController {
  private struct MembershipStatus: Decodable {
    let launchState: String
    let activeSubscription: Bool
    let productIds: [String]
  }

  private var statusTask: Task<Void, Never>?
  init(app: QFAppSession) { super.init(app: app, title: app.text("会员订阅", "Membership")) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    let symbol = UIImageView(image: UIImage(systemName: "crown.fill"))
    symbol.contentMode = .scaleAspectFit
    symbol.tintColor = QFUI.primary
    symbol.snp.makeConstraints { $0.height.equalTo(64) }
    let title = QFContentUI.label(app.text("会员订阅尚未开放", "Membership is not available yet"), size: 23, bold: true)
    title.textAlignment = .center
    let detail = QFContentUI.label(app.text("开放后，你可以在这里查看会员方案与管理订阅。", "When available, you can view plans and manage your subscription here."), size: 15, color: QFUI.secondary)
    detail.textAlignment = .center
    bodyStack.addArrangedSubview(QFTabUI.card(QFTabUI.stack([symbol, title, detail], spacing: 20), padding: 24))
    guard app.user != nil else { return }
    let session = app
    statusTask = Task { [weak self, session] in
      do {
        let status: MembershipStatus = try await session.contentRequest(path: "me/membership")
        guard let self, self.view.window != nil, !Task.isCancelled else { return }
        if status.activeSubscription {
          title.text = self.app.text("会员订阅已生效", "Membership active")
          detail.text = self.app.text("你的订阅状态已记录；具体权益将在方案确定后公布。",
                                 "Your subscription is recorded. Benefits will be published when the plans are finalized.")
        } else if status.launchState != "NOT_LAUNCHED" {
          title.text = self.app.text("当前没有有效订阅", "No active subscription")
          detail.text = self.app.text("当前没有可购买的会员方案。", "No membership plan is available to purchase right now.")
        }
      } catch is CancellationError {
      } catch {
        guard let self, self.view.window != nil, !Task.isCancelled else { return }
        title.text = self.app.text("暂时无法获取订阅状态", "Subscription status is unavailable")
        detail.text = self.app.text("请稍后重新进入此页面。", "Please open this page again later.")
      }
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    statusTask?.cancel()
    statusTask = nil
  }
}
