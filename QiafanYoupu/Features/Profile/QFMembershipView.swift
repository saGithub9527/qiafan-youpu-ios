import SnapKit
import UIKit

struct QFMembershipStatus: Decodable {
  let launchState: String
  let activeSubscription: Bool
  let productIds: [String]
  let benefitsActive: Bool?
  let entitlementSource: String?
  let expiresAt: String?
  let entitlements: [String]?
  var isTestAccess: Bool { benefitsActive == true && entitlementSource == "TEST" }
}

private struct QFMembershipWallet: Decodable {
  let billingEnabled: Bool
  let balanceUnits: Int64
}

@MainActor
final class QFMembershipViewController: QFProfileContentController {
  private var hasRendered = false
  init(app: QFAppSession) { super.init(app: app, title: app.text("会员订阅", "Membership")) }
  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    setReloadAction { [weak self] in self?.load() }
    bodyStack.beginUpdates()
    bodyStack.row("loading", version: "1") { [self] in
      QFTabUI.card(QFContentUI.label(app.text("加载中", "Loading"), size: 15, color: QFUI.secondary))
    }
    bodyStack.endUpdates()
    load()
  }

  private func load() {
    let scope = app.contentScope, language = app.interfaceLanguage
    execute(reloadOnFailure: true, showsInitialReadProgress: false) { [self] in
      async let state = readStatus()
      async let wallet = readWallet()
      do {
        let (membership, balance) = try await (state, wallet)
        try Task.checkCancellation()
        guard app.contentScope == scope, app.interfaceLanguage == language else { return }
        render(membership, wallet: balance); hasRendered = true
      } catch {
        try Task.checkCancellation()
        guard app.contentScope == scope, app.interfaceLanguage == language else { return }
        if !hasRendered {
          bodyStack.beginUpdates()
          bodyStack.row("error", version: language) {
            QFTabUI.card(QFContentUI.label(app.text("权益暂时无法读取，下拉可重试。", "Benefits could not be loaded. Pull down to retry."), size: 15, color: QFUI.secondary), padding: 24)
          }
          bodyStack.endUpdates()
        }
        throw error
      }
    }
  }

  private func readStatus() async throws -> QFMembershipStatus {
    try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.contentRequest(path: "me/membership") }
  }
  private func readWallet() async -> QFMembershipWallet? {
    try? await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.contentRequest(path: "me/assistant/credits") }
  }

  private func render(_ status: QFMembershipStatus, wallet: QFMembershipWallet?) {
    let active = status.benefitsActive ?? status.activeSubscription
    let version = [status.launchState, status.entitlementSource ?? "", status.expiresAt ?? "", String(active),
      (status.entitlements ?? []).joined(separator: ","), app.interfaceLanguage].joined(separator: "|")
    bodyStack.beginUpdates()
    bodyStack.row("status", version: version) { [self] in
      let symbol = UIImageView(image: UIImage(systemName: "crown.fill"))
      symbol.contentMode = .scaleAspectFit; symbol.tintColor = active ? QFUI.primary : QFUI.secondary
      symbol.snp.makeConstraints { $0.height.equalTo(56) }
      let heading: String
      let description: String
      if status.isTestAccess {
        heading = app.text("测试权益已开通", "Test benefits are active")
        description = app.text("此账号可使用全部已上线会员功能，无需购买。", "This account can use all released member features without a purchase.")
      } else if active {
        heading = app.text("会员订阅已生效", "Membership active")
        description = app.text("当前权益已由服务器确认。", "Your current benefits are confirmed by the server.")
      } else {
        heading = app.text("尚未开通会员", "No active membership")
        description = app.text("付费订阅尚未开放，基础功能可照常使用。", "Paid subscriptions are not open yet. Your existing basic features remain available.")
      }
      let title = QFContentUI.label(heading, size: 23, bold: true); title.textAlignment = .center
      title.accessibilityIdentifier = "membership.status"
      let detail = QFContentUI.label(description, size: 15, color: QFUI.secondary); detail.textAlignment = .center
      var views: [UIView] = [symbol, title, detail]
      if let raw = status.expiresAt, let date = Self.date(raw) {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: app.interfaceLanguage)
        formatter.dateStyle = .medium; formatter.timeStyle = .none
        let expiry = QFContentUI.label(app.format("有效期至 %@", "Valid until %@", formatter.string(from: date)), size: 13, color: QFUI.secondary)
        expiry.textAlignment = .center; views.append(expiry)
      }
      return QFTabUI.card(QFTabUI.stack(views, spacing: 16), padding: 24)
    }
    if active {
      bodyStack.row("benefits", version: version) { [self] in
        let known: [(String, String)] = [
          ("PRODUCT_BARCODE_LOOKUP", app.text("商品条码联网查询", "Online product barcode lookup")),
          ("PRODUCT_BARCODE_BATCH", app.text("连续扫码与批量核对", "Continuous scanning and batch review")),
          ("DEEPSEEK_CREDITS", app.text("DeepSeek 积分使用", "Use DeepSeek credits"))]
        let available = Set(status.entitlements ?? [])
        let rows: [UIView] = [QFContentUI.label(app.text("已开通权益", "Active benefits"), size: 18, bold: true)] + known.filter { available.contains($0.0) }.map { item in
          let label = QFContentUI.label("✓ " + item.1, size: 15)
          label.accessibilityIdentifier = "membership.benefit." + item.0
          return label
        }
        return QFTabUI.card(QFTabUI.stack(rows, spacing: 16), padding: 24)
      }
    }
    let walletVersion = String(wallet?.balanceUnits ?? -1) + ":" + String(wallet?.billingEnabled ?? false) + ":" + app.interfaceLanguage
    bodyStack.row("credits", version: walletVersion) { [self] in
      let title = QFContentUI.label(app.text("云端 AI 积分", "Cloud AI credits"), size: 18, bold: true)
      let value = QFContentUI.label(wallet.map { NumberFormatter.localizedString(from: NSNumber(value: $0.balanceUnits), number: .decimal) } ?? "—", size: 30, bold: true)
      value.accessibilityIdentifier = "membership.credits"
      let explanation = wallet == nil ? app.text("积分暂时无法读取，下拉可重试。", "Credits could not be loaded. Pull down to retry.") : wallet!.billingEnabled
        ? app.text("仅主动使用 DeepSeek 时消耗积分，免费 GLM 不扣积分。", "Credits are used only when you choose DeepSeek. Free GLM does not use credits.")
        : app.text("积分已记录，当前尚未启用积分扣费。", "Your credits are recorded. Credit billing is not enabled yet.")
      return QFTabUI.card(QFTabUI.stack([title, value, QFContentUI.label(explanation, size: 13, color: QFUI.secondary)], spacing: 12), padding: 24)
    }
    bodyStack.row("basic", version: app.interfaceLanguage) { [self] in
      QFTabUI.card(QFContentUI.label(app.text("菜谱、计划、手动入库、基础提醒和免费 GLM 继续按原有规则使用。", "Recipes, plans, manual inventory entry, basic reminders and free GLM continue under their existing rules."), size: 13, color: QFUI.secondary), padding: 24)
    }
    bodyStack.endUpdates()
  }

  private static func date(_ raw: String) -> Date? {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) { return date }
    formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: raw)
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
        result["testStatusRendered"] = label(page.view, id: "membership.status")?.text == app.text("测试权益已开通", "Test benefits are active")
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
