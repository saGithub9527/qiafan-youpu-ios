import Combine
import SafariServices
import SnapKit
import StoreKit
import UIKit

private struct QFMembershipWallet: Decodable {
  let billingEnabled: Bool
  let balanceUnits: Int64
}

@MainActor
final class QFMembershipViewController: UIViewController {
  private let app: QFAppSession
  private let entryGate: Bool
  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private var subscriptions = Set<AnyCancellable>()
  private var action: Task<Void, Never>?
  private var renderQueued = false
  private var header: UIView?

  init(app: QFAppSession, entryGate: Bool = false) {
    self.app = app; self.entryGate = entryGate
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { nil }
  deinit { action?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.accessibilityIdentifier = "membership.screen"
    let header = QFSettingsPageUI.header(app.text("会员订阅", "Membership"),
      backLabel: entryGate ? app.text("退出登录", "Sign out") : app.text("返回", "Back")) { [weak self] in
        self?.leave()
      }
    self.header = header
    if entryGate, let row = header as? UIStackView {
      // The entry gate has no business page to go back to. Account switching
      // is the explicit, visible Sign out action below, not a back chevron.
      row.arrangedSubviews.first?.isHidden = true
      row.arrangedSubviews.last?.isHidden = true
    }
    stack.axis = .vertical; stack.spacing = 16
    QFSettingsPageUI.installScroll(scroll, stack: stack, in: view, header: header)
    app.membership.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      // @Published emits before the mutation; render on the next main-queue turn.
      guard let self, !self.renderQueued else { return }
      self.renderQueued = true
      DispatchQueue.main.async { [weak self] in self?.renderQueued = false; self?.render() }
    }.store(in: &subscriptions)
    app.$interfaceLanguage.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.render()
    }.store(in: &subscriptions)
    app.$configuration.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.render()
    }.store(in: &subscriptions)
    app.membership.activate()
    render()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    app.membership.refresh()
  }

  private func render() {
    let membership = app.membership
    QFSettingsPageUI.updateHeader(header, title: app.text("会员订阅", "Membership"),
      backLabel: entryGate ? app.text("退出登录", "Sign out") : app.text("返回", "Back"))
    for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
    let heading: String
    let detail: String
    if membership.isComplimentaryOnly {
      heading = app.text("已获赠使用权益", "Complimentary access active")
      detail = app.text("当前账号已获赠使用权益，没有产生订阅扣费。你仍可查看下方订阅方案。", "This account has complimentary access and has not been charged for a subscription. You can still view the plans below.")
    } else if membership.hasBusinessAccess {
      heading = app.text("会员订阅已生效", "Membership active")
      detail = app.text("当前权益已由服务器确认。", "Your current benefits are confirmed by the server.")
    } else if let issue = membership.issue {
      switch issue {
      case .pending:
        heading = app.text("购买等待批准", "Purchase awaiting approval")
        detail = app.text("Apple 批准后会自动确认权益，无需再次购买。", "Your access will be confirmed after Apple approves the purchase. You do not need to buy again.")
      case .conflict:
        heading = app.text("订阅已绑定其他账号", "Subscription linked to another account")
        detail = app.text("请切换到原恰饭有谱账号或联系支持，不要重复购买。", "Switch to your original Qiafan Youpu account or contact support. Do not purchase again.")
      case .unavailable, .unverified:
        heading = app.text("订阅状态尚未确认", "Subscription not yet confirmed")
        detail = app.text("请重试检查或恢复购买。确认前不会要求你再次购买。", "Retry verification or restore purchases. You will not be asked to buy again before verification.")
      case .productsUnavailable:
        heading = app.text("订阅产品暂不可用", "Subscription products are unavailable")
        detail = app.text("请稍后重试，已有订阅可通过恢复购买核对。", "Try again later. You can verify an existing subscription by restoring purchases.")
      }
    } else if membership.isBusy {
      heading = app.text("正在检查订阅", "Checking subscription")
      detail = app.text("正在核对当前账号和 Apple 购买记录。", "Verifying your current account and Apple purchases.")
    } else {
      heading = app.text("订阅后进入恰饭有谱", "Subscribe to enter Qiafan Youpu")
      detail = app.text("月付和年付包含相同权益。", "Monthly and yearly plans include the same benefits.")
    }
    let title = QFSettingsPageUI.label(heading, size: 23, weight: .semibold, style: .title2)
    title.accessibilityIdentifier = "membership.status"
    stack.addArrangedSubview(QFTabUI.card(QFTabUI.stack([
      title, QFSettingsPageUI.label(detail, size: 15, color: QFUI.secondary)
    ], spacing: 12), padding: 24))
    stack.addArrangedSubview(QFTabUI.card(QFSettingsPageUI.label(
      app.text("菜谱、饮食计划、食材库存、账号云端同步和基础家庭协作。", "Recipes, meal plans, ingredient inventory, account cloud sync and basic household collaboration."),
      size: 15), padding: 24))
    // An unlocked account must still be able to inspect the real subscription
    // catalog. Access controls purchasing, not visibility of prices and terms.
    for product in membership.products {
      let monthly = product.subscription?.subscriptionPeriod.unit == .month
      let period = monthly ? app.text("月付", "Monthly") : app.text("年付", "Yearly")
      let price = monthly
        ? app.format("%@／月", "%@ per month", product.displayPrice)
        : app.format("%@／年", "%@ per year", product.displayPrice)
      if membership.hasBusinessAccess {
        let card = QFTabUI.card(QFSettingsPageUI.label(period + " · " + price, size: 16), padding: 24)
        card.accessibilityIdentifier = "membership.plan." + product.id
        stack.addArrangedSubview(card)
      } else {
        let button = makeButton(period + " · " + price, id: "membership.buy." + product.id) { [weak self] in
          self?.app.membership.purchase(product)
        }
        button.isEnabled = membership.canPurchase && legalURLsAvailable
        button.alpha = button.isEnabled ? 1 : 0.45
        stack.addArrangedSubview(button)
      }
    }
    if membership.products.isEmpty && !membership.isBusy {
      stack.addArrangedSubview(QFSettingsPageUI.label(
        app.text("订阅产品暂不可用", "Subscription products are unavailable"),
        size: 13, color: QFUI.secondary, style: .footnote))
    }
    stack.addArrangedSubview(QFSettingsPageUI.label(
      app.text("月付和年付包含相同权益。", "Monthly and yearly plans include the same benefits."),
      size: 13, color: QFUI.secondary, style: .footnote))
    stack.addArrangedSubview(QFSettingsPageUI.label(
      app.text("费用由 Apple 账号支付，订阅自动续期，除非在当前周期结束前取消。可在 Apple 订阅设置中管理或取消。", "Payment is charged to your Apple Account. The subscription renews automatically unless cancelled before the current period ends. Manage or cancel in Apple Subscriptions."),
      size: 13, color: QFUI.secondary, style: .footnote))
    if !legalURLsAvailable {
      stack.addArrangedSubview(QFSettingsPageUI.label(
        app.text("订阅条款与隐私链接尚未就绪，暂不可购买。", "Subscription terms and privacy links are not ready. Purchases are unavailable."),
        size: 13, color: QFUI.secondary, style: .footnote))
    }
    addButton(app.text("重新检查", "Check again"), id: "membership.retry") { [weak self] in self?.app.membership.refresh() }
    addButton(app.text("恢复购买", "Restore purchases"), id: "membership.restore") { [weak self] in self?.app.membership.restore() }
    addButton(app.text("管理订阅", "Manage subscriptions"), id: "membership.manage") { [weak self] in self?.manage() }
    addButton(app.text("用户协议", "Terms of service"), id: "membership.terms") { [weak self] in self?.legal(privacy: false) }
    addButton(app.text("隐私政策", "Privacy policy"), id: "membership.privacy") { [weak self] in self?.legal(privacy: true) }
    addButton(app.text("帮助与反馈", "Help and feedback"), id: "membership.support") { [weak self] in
      guard let self else { return }; self.open(QFHelpFeedbackViewController(app: self.app))
    }
    addButton(app.text("账号与隐私", "Account and privacy"), id: "membership.account") { [weak self] in
      guard let self, let user = self.app.user else { return }
      self.open(QFAccountPrivacyViewController(app: self.app, initialProfile: user, onSessionExpired: {}))
    }
    if QFAIAvailability.isEnabled {
      addButton(app.text("历史权益与余额", "Past benefits and balance"), id: "membership.history") { [weak self] in
        guard let self else { return }; self.open(QFMembershipHistoryViewController(app: self.app))
      }
    }
    if entryGate {
      addButton(app.text("退出登录", "Sign out"), id: "membership.sign-out") { [weak self] in self?.leave() }
    }
  }

  private var legalURLsAvailable: Bool {
    Self.https(app.configuration?.agreements.userAgreementUrl) != nil
      && Self.https(app.configuration?.agreements.privacyPolicyUrl) != nil
  }
  static func https(_ raw: String?) -> URL? {
    guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https",
      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
    return url
  }
  private func legal(privacy: Bool) {
    let raw = privacy ? app.configuration?.agreements.privacyPolicyUrl : app.configuration?.agreements.userAgreementUrl
    if let url = Self.https(raw) { present(SFSafariViewController(url: url), animated: true) }
    else {
      open(QFLocalLegalViewController(document: privacy ? "privacy-policy" : "user-agreement",
        title: privacy ? app.text("隐私政策", "Privacy policy") : app.text("用户协议", "Terms of service"),
        language: app.interfaceLanguage))
    }
  }
  private func manage() {
    guard action == nil, let scene = view.window?.windowScene else { return }
    action = Task { [weak self] in
      defer { self?.action = nil }
      do { try await AppStore.showManageSubscriptions(in: scene); self?.app.membership.refresh() }
      catch { guard let self else { return }; QFOperationHUD.toast(self.app.text("操作失败，请重试。", "Operation failed. Please try again."), in: self.view) }
    }
  }
  private func leave() {
    guard !entryGate else {
      guard action == nil else { return }
      action = Task { [weak self] in
        guard let self else { return }
        defer { self.action = nil }
        do { try await self.app.logout() }
        catch { QFOperationHUD.toast(self.app.text("退出失败，请重试。", "Sign out failed. Please try again."), in: self.view) }
      }
      return
    }
    if let navigationController { navigationController.popViewController(animated: true) }
    else { dismiss(animated: true) }
  }
  private func open(_ controller: UIViewController) {
    guard presentedViewController == nil else { return }
    let navigation = UINavigationController(rootViewController: controller)
    navigation.setNavigationBarHidden(true, animated: false)
    navigation.modalPresentationStyle = .fullScreen
    present(navigation, animated: true)
  }
  private func makeButton(_ title: String, id: String, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal); button.titleLabel?.numberOfLines = 0
    button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
    button.titleLabel?.adjustsFontForContentSizeCategory = true
    button.accessibilityIdentifier = id
    button.contentEdgeInsets = UIEdgeInsets(top: 13, left: 16, bottom: 13, right: 16)
    button.backgroundColor = QFUI.surface; button.layer.cornerRadius = 16
    button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(48) }
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }
  private func addButton(_ title: String, id: String, action: @escaping () -> Void) {
    stack.addArrangedSubview(makeButton(title, id: id, action: action))
  }
}

@MainActor
private final class QFMembershipHistoryViewController: QFProfileContentController {
  init(app: QFAppSession) { super.init(app: app, title: app.text("历史权益与余额", "Past benefits and balance")) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    setReloadAction { [weak self] in self?.load() }
    load()
  }
  private func load() {
    execute(reloadOnFailure: true) { [self] in
      let scope = app.contentScope
      let wallet: QFMembershipWallet = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.contentRequest(path: "me/assistant/credits")
      }
      guard scope == app.contentScope else { return }
      bodyStack.beginUpdates()
      bodyStack.row("history", version: String(wallet.balanceUnits) + app.interfaceLanguage) { [self] in
        QFTabUI.card(QFTabUI.stack([
          QFSettingsPageUI.label(app.text("云端 AI 积分", "Cloud AI credits"), size: 18, weight: .semibold),
          QFSettingsPageUI.label(NumberFormatter.localizedString(from: NSNumber(value: wallet.balanceUnits), number: .decimal), size: 30),
          QFSettingsPageUI.label(app.text("历史余额仅供查看，不属于当前订阅权益。", "Past balances are view-only and are not part of the current subscription."), size: 13, color: QFUI.secondary)
        ], spacing: 12), padding: 24)
      }
      bodyStack.endUpdates()
    }
  }
}

#if DEBUG
@MainActor
enum QFMembershipDeviceCheck {
  static func collectIfRequested(app: QFAppSession) async {
    let args = ProcessInfo.processInfo.arguments
    guard args.contains("-QFReadMembershipStatus"), let index = args.firstIndex(of: "-QFCheckRun"),
      args.indices.contains(index + 1), let run = UUID(uuidString: args[index + 1]) else { return }
    let scope = app.contentScope
    var result: [String: Any] = ["runID": run.uuidString.lowercased(), "modelCalls": 0, "businessWrites": 0]
    do {
      let status: QFMembershipStatus = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.contentRequest(path: "me/membership") }
      let wallet: QFMembershipWallet = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.contentRequest(path: "me/assistant/credits") }
      guard app.contentScope == scope else { return }
      result.merge(["status": "READ_ONLY_MEMBERSHIP_STATUS", "signedIn": app.user != nil,
        "benefitsActive": status.benefitsActive ?? false, "entitlementSource": status.entitlementSource ?? "NONE",
        "activeAppleSubscription": status.activeSubscription, "launchState": status.launchState,
        "entitlements": status.entitlements ?? [], "expiresAt": status.expiresAt as Any? ?? NSNull(),
        "balanceUnits": wallet.balanceUnits, "billingEnabled": wallet.billingEnabled]) { _, new in new }
    } catch {
      result["status"] = "READ_FAILED"; result["errorType"] = String(describing: type(of: error))
      result["errorCode"] = (error as? QFAPIError)?.code as Any? ?? NSNull()
    }
    if args.contains("-QFShowMembership"), app.contentScope == scope {
      func tabs(_ controller: UIViewController) -> UITabBarController? {
        if let tab = controller as? UITabBarController { return tab }
        return controller.children.lazy.compactMap { tabs($0) }.first
      }
      func label(_ view: UIView, id: String) -> UILabel? {
        if view.accessibilityIdentifier == id { return view as? UILabel }
        return view.subviews.lazy.compactMap { label($0, id: id) }.first
      }
      let root = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
      if let root, let tab = tabs(root), let index = QFTab.allCases.firstIndex(of: .profile),
        let navigation = tab.viewControllers?[index] as? UINavigationController {
        tab.selectedIndex = index
        let page = QFMembershipViewController(app: app); page.hidesBottomBarWhenPushed = true
        navigation.pushViewController(page, animated: false)
        let deadline = Date().addingTimeInterval(10)
        while label(page.view, id: "membership.status") == nil, Date() < deadline {
          do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
        }
        result["membershipPageOpened"] = navigation.topViewController === page
        result["v2StatusRendered"] = label(page.view, id: "membership.status") != nil
        result["walletRendered"] = label(page.view, id: "membership.credits")?.text == NumberFormatter.localizedString(from: NSNumber(value: result["balanceUnits"] as? Int64 ?? -1), number: .decimal)
      }
    }
    let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("membership-status-" + run.uuidString.lowercased() + ".json")
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
      try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
  }
}
#endif
