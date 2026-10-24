import CryptoKit
import UIKit

@MainActor
final class QFAccountEditorViewController: QFProfileContentController {
  enum Kind { case account, password }
  private let kind: Kind
  private let needsOldPassword: Bool
  private var account = ""
  private var password = ""
  private var oldPassword = ""
  private var confirmation = ""
  private var operationID = UUID()
  private var requestDigest: SHA256.Digest?
  override var hasUnsavedChanges: Bool { !account.isEmpty || !password.isEmpty || !oldPassword.isEmpty }
  init(app: QFAppSession, kind: Kind) {
    self.kind = kind
    needsOldPassword = app.user?.passwordConfigured == true
    super.init(app: app, title: kind == .account ? app.text("绑定账号", "Link account") : (needsOldPassword ? app.text("修改密码", "Change password") : app.text("设置密码", "Set password")))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    if kind == .account {
      let field = QFContentUI.field(app.text("1–64位小写字母、数字或下划线", "1–64 lowercase letters, numbers, or underscores"), limit: 64) { [weak self] in self?.account = $0 }
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
      field.textContentType = .username
      bodyStack.addArrangedSubview(QFContentUI.label(app.text("自定义账号", "Custom account"), size: 18, bold: true))
      bodyStack.addArrangedSubview(field)
      bodyStack.addArrangedSubview(QFContentUI.label(app.text("账号绑定后不可修改。", "The account name cannot be changed after linking."), size: 13, color: QFUI.secondary))
    } else {
      if needsOldPassword {
        addPasswordField(app.text("当前密码", "Current password"), contentType: .password) { [weak self] in self?.oldPassword = $0 }
      }
      addPasswordField(app.text("新密码（8–128位）", "New password (8–128 characters)"), contentType: .newPassword) { [weak self] in self?.password = $0 }
      addPasswordField(app.text("再次输入新密码", "Enter the new password again"), contentType: .newPassword) { [weak self] in self?.confirmation = $0 }
    }
    _ = addFooter(kind == .account ? app.text("绑定账号", "Link account") : app.text("保存密码", "Save password")) { [weak self] in self?.save() }
  }
  private func addPasswordField(_ title: String, contentType: UITextContentType, onChange: @escaping (String) -> Void) {
    let field = QFContentUI.field(title, limit: 128, changed: onChange)
    field.isSecureTextEntry = true
    field.textContentType = contentType
    field.autocorrectionType = .no
    field.autocapitalizationType = .none
    bodyStack.addArrangedSubview(field)
  }
  private func save() {
    let account = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let password = password, oldPassword = oldPassword
    if kind == .account {
      guard account.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) != nil, !account.hasPrefix("sys_") else {
        message(app.text("账号需为1–64位小写字母、数字或下划线，不能以 sys_ 开头。", "Use 1–64 lowercase letters, numbers, or underscores; the account cannot start with sys_."), error: true); return
      }
    } else {
      guard (8...128).contains(password.utf16.count), !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        password == confirmation, !needsOldPassword || !oldPassword.isEmpty else {
        message(app.text("请填写完整密码；新密码需为8–128位，且两次输入一致。", "Complete all password fields. The new password must be 8–128 characters and both entries must match."), error: true); return
      }
    }
    // Keep only a digest in memory so a retry of the same form uses the same idempotency key.
    let digest = SHA256.hash(data: (try? JSONEncoder().encode([account, password, oldPassword])) ?? Data())
    if requestDigest != digest { requestDigest = digest; operationID = UUID() }
    let operationID = operationID
    execute(label: kind == .account ? app.text("绑定中", "Linking") : app.text("保存密码中", "Saving password")) { [self] in
      do {
        if kind == .account { try await app.bindAccount(account, operationID: operationID) }
        else { try await app.setPassword(password, oldPassword: needsOldPassword ? oldPassword : nil, operationID: operationID) }
      } catch let error as QFAPIError where error.code == 40302 {
        throw QFAPIError(code: 40302, message: app.text("请先在设置中退出并重新登录，再修改账号或密码。", "Sign out in Settings and sign in again before changing the account or password."))
      }
      self.password = ""; self.oldPassword = ""; confirmation = ""
      onChanged?(); qfClose()
    }
  }
  override func close() {
    guard hasUnsavedChanges else { super.close(); return }
    confirm(app.text("放弃未保存的修改？", "Discard unsaved changes?"), detail: app.text("输入的账号或密码尚未提交。", "The account or password has not been submitted."), actionTitle: app.text("放弃修改", "Discard changes"), destructive: true) { [weak self] in self?.qfClose() }
  }
}

@MainActor
final class QFAccountDeletionViewController: QFProfileContentController {
  override var reloadsOnAppearance: Bool { false }

  init(app: QFAppSession) {
    super.init(app: app, title: app.text("注销账号", "Delete account"))
  }
  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "account.deletion.screen"
    let details = [
      app.text("个人资料、作品、做菜记录、采购账单、个人计划和库存将永久删除，无法恢复。", "Your profile, works, cooking records, purchase bills, personal plans and inventory will be permanently deleted and cannot be restored."),
      app.text("家庭共享记录会保留并去标识，管理权转交其他家庭成员；只有你一位成员的家庭将解散。", "Shared household records remain without your identity and pass to another member. A household with no other members will be removed."),
      app.text("请在最近 15 分钟内重新登录后操作。注销成功后，本机登录凭证和未提交草稿会清除。", "Sign in again within 15 minutes before continuing. On success, this device's sign-in credentials and unsent drafts are removed."),
      app.text("若使用 Apple 登录，旧授权可能需要在 Apple 设置中手动撤销。App Store 自动续订需在系统订阅设置中单独管理。", "For Sign in with Apple, an older authorization may need manual revocation in Apple Settings. Manage any App Store auto-renewal separately in system Subscriptions.")
    ]
    let rows = details.map { QFSettingsPageUI.label($0, size: 14, color: QFUI.secondary) }
    bodyStack.addArrangedSubview(QFSettingsPageUI.section(
      app.text("注销后会发生什么", "What happens after deletion"), rows: rows))
    let button = addFooter(app.text("永久注销账号", "Permanently delete account"), primary: false) { [weak self] in
      self?.askForConfirmation()
    }
    button.setTitleColor(QFUI.danger, for: .normal)
    button.accessibilityIdentifier = "account.deletion.submit"
  }

  private func askForConfirmation() {
    confirm(
      app.text("确认永久注销账号？", "Permanently delete this account?"),
      detail: app.text("这会删除个人记录并退出所有设备，操作无法撤销。", "This deletes personal records and signs out every device. It cannot be undone."),
      actionTitle: app.text("确认注销", "Delete account"), destructive: true
    ) { [weak self] in self?.submit() }
  }

  private func submit() {
    let landing = navigationController?.viewControllers.first
    execute(label: app.text("正在注销账号", "Deleting account")) { [self] in
      await QFMealLivePushService.shared.unregisterBeforeSignOut()
          await QFGetuiPushService.shared.unregisterBeforeSignOut()
      do {
        let outcome = try await app.deleteAccount()
        let notice: String
        if !outcome.localCleanupComplete {
          notice = app.text("账号已注销，但部分本机数据未能清除，请在设备设置中移除应用数据。", "Account deleted, but some local data could not be removed. Clear the app's data in device Settings.")
        } else if outcome.appleAuthorizationRevocation == "MANUAL_REQUIRED" {
          notice = app.text("账号已注销。请在 Apple 设置中手动撤销旧授权。", "Account deleted. Revoke the older authorization in Apple Settings.")
        } else {
          notice = app.text("账号已注销", "Account deleted")
        }
        // A toast on the hidden root controller disappears behind this pushed page. Return to
        // the signed-out profile first, then keep important Apple/local-cleanup advice visible.
        navigationController?.popToRootViewController(animated: false)
        if let landing, landing.viewIfLoaded?.window != nil {
          let alert = UIAlertController(
            title: app.text("账号已注销", "Account deleted"), message: notice,
            preferredStyle: .alert)
          alert.addAction(UIAlertAction(title: app.text("知道了", "OK"), style: .default))
          landing.present(alert, animated: true)
        }
        UIAccessibility.post(notification: .announcement, argument: notice)
      } catch let error as QFAPIError where error.code == 40302 {
        QFGetuiPushService.shared.signOutDidFail()
        QFMealLivePushService.shared.signOutDidFail()
        message(app.text("请先退出并重新登录，再注销账号。", "Sign out and sign in again before deleting this account."), error: true)
      } catch {
        QFGetuiPushService.shared.signOutDidFail()
        QFMealLivePushService.shared.signOutDidFail()
        message(app.text("注销结果尚未确认，请在此页重试。", "Deletion is not confirmed. Retry from this page."), error: true)
      }
    }
  }
}
