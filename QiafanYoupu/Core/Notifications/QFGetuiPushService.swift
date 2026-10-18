import Combine
import Foundation
@preconcurrency import GTSDK
import UIKit
import UserNotifications

extension Notification.Name {
  static let qfLocalSettingsDidChange = Notification.Name("com.talka.qiafanyoupu.local-settings-changed")
  static let qfDidReceiveRemoteNotification = Notification.Name("com.talka.qiafanyoupu.remote-notification")
}

private struct QFGetuiConfiguration {
  let appID: String
  let appKey: String
  let appSecret: String

  static func load(bundle: Bundle = .main) -> Self? {
    func value(_ key: String) -> String? {
      guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
      let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, !value.contains("$(") else { return nil }
      return value
    }
    guard let appID = value("QFGetuiAppID"), let appKey = value("QFGetuiAppKey"),
      let appSecret = value("QFGetuiAppSecret")
    else { return nil }
    return Self(appID: appID, appKey: appKey, appSecret: appSecret)
  }
}

private struct QFGetuiRegistration: Codable, Equatable {
  let environment: String
  let userID: String
  let deviceID: String
  let cid: String
  let language: String
  let revision: Int
  let active: Bool?

  var isActive: Bool { active ?? true }
}

struct QFOnlinePushContent {
  let id: String
  let title: String
  let body: String
  let route: [String: String]

  static func decode(_ value: Any, depth: Int = 0) -> Self? {
    guard depth < 5 else { return nil }
    if let text = value as? String, let data = text.data(using: .utf8),
      let decoded = try? JSONSerialization.jsonObject(with: data)
    {
      return decode(decoded, depth: depth + 1)
    }
    guard let object = value as? [String: Any] else { return nil }
    if let id = object["notificationId"] as? String, UUID(uuidString: id) != nil,
      let title = object["title"] as? String, !title.isEmpty, title.count <= 100,
      let body = object["body"] as? String, !body.isEmpty, body.count <= 255,
      let payload = object["payload"] as? String, let data = payload.data(using: .utf8),
      let route = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
      let type = route["type"]
    {
      if type == "PLAN_REMINDER", let planID = route["plannedMealId"], UUID(uuidString: planID) != nil {
        return Self(id: id, title: title, body: body, route: route)
      }
      if type == "ASSISTANT_NUDGE" { return Self(id: id, title: title, body: body, route: route) }
    }
    for key in ["payload", "transmission", "data"] {
      if let nested = object[key], let content = decode(nested, depth: depth + 1) {
        return content
      }
    }
    return nil
  }
}

/// Owns the SDK lifecycle and bridges one Getui CID to the authenticated API device.
/// The SDK is not initialized until the app privacy agreement has been accepted.
@MainActor
final class QFGetuiPushService: NSObject, @preconcurrency GeTuiSdkDelegate {
  static let shared = QFGetuiPushService()

  private static let registrationKey = "qfyp.getui.registration.v1"
  private static let localDisabledPrefix = "qfyp.getui.local-disabled."
  private static let assistantEnabledPrefix = "qfyp.getui.assistant-enabled."

  private weak var app: QFAppSession?
  private let identity = QFDeviceIdentity()
  private var launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  private var sceneConnectionOptions: UIScene.ConnectionOptions?
  private var subscriptions = Set<AnyCancellable>()
  private var reconcileTask: Task<Void, Never>?
  private var settingsTask: Task<Void, Never>?
  private var sdkStarted = false
  private var didRegisterRemoteNotifications = false
  private var privacyConsentAccepted = false
  private var cid: String?
  private var lastSynchronizedFingerprint: String?
  private var displayedOnlineNotifications = Set<String>()
  private var onlineNotificationOrder: [String] = []

  private override init() { super.init() }

  func prepare(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
    self.launchOptions = launchOptions
  }

  func bind(to app: QFAppSession, privacyConsentAccepted: Bool) {
    self.app = app
    self.privacyConsentAccepted = privacyConsentAccepted
    subscriptions.removeAll()

    app.$user.receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.userDidChange()
    }.store(in: &subscriptions)
    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] _ in self?.scheduleReconcile()
    }.store(in: &subscriptions)
    app.$userSettings.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] settings in
      guard let self, let app = self.app else { return }
      if let settings {
        self.storeLocalDisabled(!settings.planReminders, scope: app.contentScope)
      }
      self.scheduleReconcile()
    }.store(in: &subscriptions)
    NotificationCenter.default.publisher(for: .qfLocalSettingsDidChange)
      .receive(on: DispatchQueue.main).sink { [weak self] notification in
        guard let self, let app = self.app,
          notification.userInfo?["scope"] as? String == app.contentScope,
          let enabled = notification.userInfo?["planReminders"] as? Bool
        else { return }
        self.storeLocalDisabled(!enabled, scope: app.contentScope)
        self.scheduleReconcile()
      }.store(in: &subscriptions)
    scheduleSettingsLoad()
  }

  func rememberSceneConnection(_ options: UIScene.ConnectionOptions) {
    sceneConnectionOptions = options
    if sdkStarted { GeTuiSdk.handleSceneWillConnect(with: options) }
  }

  func privacyConsentWasAccepted() {
    privacyConsentAccepted = true
    scheduleSettingsLoad()
  }

  func applicationDidBecomeActive() {
    scheduleReconcile()
  }

  /// Keeps the device registration alive when the user opts into assistant
  /// nudges but has turned off meal-plan reminders. The server preference is
  /// still authoritative; this local bit only decides whether reconciliation
  /// should run before the next settings refresh.
  func setAssistantRemoteEnabled(_ enabled: Bool, scope: String) {
    UserDefaults.standard.set(enabled, forKey: Self.assistantEnabledPrefix + scope)
    scheduleReconcile()
  }

  /// Called before revoking the app session so the authenticated device row can be disabled.
  func unregisterBeforeSignOut() async {
    reconcileTask?.cancel()
    settingsTask?.cancel()
    await unregisterDeviceIfPossible()
    stopSDK()
  }

  /// Restores the SDK lifecycle when the authenticated session could not be revoked.
  func signOutDidFail() {
    guard privacyConsentAccepted, let app, app.user != nil else { return }
    lastSynchronizedFingerprint = nil
    if app.userSettings == nil { scheduleSettingsLoad() }
    else { scheduleReconcile() }
  }

  func forgetDeletedAccount(environment: String, userID: String) {
    if let registration = storedRegistration(), registration.environment == environment,
      registration.userID == userID
    {
      UserDefaults.standard.removeObject(forKey: Self.registrationKey)
    }
  }

  private func userDidChange() {
    lastSynchronizedFingerprint = nil
    guard app?.user != nil else {
      settingsTask?.cancel()
      stopSDK()
      return
    }
    scheduleSettingsLoad()
  }

  private func scheduleSettingsLoad() {
    settingsTask?.cancel()
    guard privacyConsentAccepted, let app, app.user != nil else { return }
    settingsTask = Task { [weak self, weak app] in
      guard let self, let app else { return }
      if app.userSettings == nil { _ = try? await app.loadUserSettings() }
      guard !Task.isCancelled else { return }
      self.scheduleReconcile()
    }
  }

  private func scheduleReconcile() {
    reconcileTask?.cancel()
    reconcileTask = Task { [weak self] in
      guard let self else { return }
      await self.reconcile()
    }
  }

  private func reconcile() async {
    guard privacyConsentAccepted, let app, app.user != nil else {
      stopSDK()
      return
    }
    // A missing server setting is an unknown state. Do not interpret it as opt-out
    // and issue a second DELETE while a failed sign-out is being recovered.
    guard app.userSettings != nil else { return }
    guard remindersEnabled(app: app) else {
      await unregisterDeviceIfPossible()
      if sdkStarted { GeTuiSdk.setPushModeForOff(true) }
      return
    }
    guard startSDKIfConfigured() else { return }
    GeTuiSdk.setPushModeForOff(false)
    if !didRegisterRemoteNotifications {
      didRegisterRemoteNotifications = true
      GeTuiSdk.registerRemoteNotification([.alert, .badge, .sound])
    }

    let settings = await UNUserNotificationCenter.current().notificationSettings()
    guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
      if settings.authorizationStatus == .denied { await unregisterDeviceIfPossible() }
      return
    }
    guard let cid = normalizedCID(cid ?? GeTuiSdk.clientId()) else { return }
    await synchronize(cid: cid, app: app)
  }

  private func remindersEnabled(app: QFAppSession) -> Bool {
    let planEnabled = !isLocallyDisabled(scope: app.contentScope) && app.userSettings?.planReminders == true
    let assistantEnabled = UserDefaults.standard.bool(forKey: Self.assistantEnabledPrefix + app.contentScope)
    return planEnabled || assistantEnabled
  }

  @discardableResult
  private func startSDKIfConfigured() -> Bool {
    if sdkStarted { return true }
    guard let configuration = QFGetuiConfiguration.load() else { return false }
    GeTuiSdk.start(
      withAppId: configuration.appID, appKey: configuration.appKey,
      appSecret: configuration.appSecret, delegate: self,
      launchingOptions: launchOptions)
    // Disconnect the online channel on background entry so Getui can use APNs.
    // Leaving this unset keeps the socket until iOS eventually closes it.
    GeTuiSdk.runBackgroundEnable(false)
    sdkStarted = true
    if let options = sceneConnectionOptions { GeTuiSdk.handleSceneWillConnect(with: options) }
    return true
  }

  private func stopSDK() {
    reconcileTask?.cancel()
    lastSynchronizedFingerprint = nil
    guard sdkStarted else { return }
    GeTuiSdk.setPushModeForOff(true)
    GeTuiSdk.destroy()
    sdkStarted = false
    didRegisterRemoteNotifications = false
    cid = nil
  }

  private func synchronize(cid: String, app: QFAppSession) async {
    guard let userID = app.user?.userId else { return }
    let language = QFInterfaceLanguage.normalized(app.interfaceLanguage).rawValue
    let deviceID: String
    do { deviceID = try identity.deviceID() } catch { return }
    let environment = app.api.environment.name
    let fingerprint = [environment, userID, deviceID, cid, language].joined(separator: "|")
    guard lastSynchronizedFingerprint != fingerprint else { return }

    let previous = storedRegistration()
    let expectedRevision =
      previous.flatMap {
        $0.environment == environment && $0.userID == userID && $0.deviceID == deviceID
          ? $0.revision : nil
      }
    do {
      let device = try await app.savePushDevice(
        deviceID,
        draft: QFPushDeviceDraft(
          provider: "GETUI", cid: cid, platform: "IOS", language: language,
          expectedRevision: expectedRevision))
      guard !Task.isCancelled, app.user?.userId == userID else { return }
      storeRegistration(
        QFGetuiRegistration(
          environment: environment, userID: userID, deviceID: deviceID, cid: cid,
          language: language, revision: device.revision, active: true))
      lastSynchronizedFingerprint = fingerprint
    } catch is CancellationError {
      return
    } catch {
      // Reconcile again on the next foreground, CID, language, or settings event.
    }
  }

  private func unregisterDeviceIfPossible() async {
    guard let app, app.user != nil else { return }
    let deviceID: String
    do { deviceID = try identity.deviceID() } catch { return }
    if let previous = storedRegistration(), previous.environment == app.api.environment.name,
      previous.deviceID == deviceID, previous.userID == app.user?.userId, !previous.isActive
    {
      return
    }
    do {
      try await app.deletePushDevice(deviceID)
      if let previous = storedRegistration(), previous.deviceID == deviceID,
        previous.userID == app.user?.userId
      {
        storeRegistration(
          QFGetuiRegistration(
            environment: previous.environment, userID: previous.userID,
            deviceID: previous.deviceID, cid: previous.cid, language: previous.language,
            revision: previous.revision + (previous.isActive ? 1 : 0), active: false))
      }
      lastSynchronizedFingerprint = nil
    } catch is CancellationError {
      return
    } catch {
      // Logout must remain available offline; the next authenticated lifecycle retries cleanup.
    }
  }

  private func normalizedCID(_ value: String?) -> String? {
    let cid = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return cid.isEmpty ? nil : cid
  }

  private func storedRegistration() -> QFGetuiRegistration? {
    UserDefaults.standard.data(forKey: Self.registrationKey)
      .flatMap { try? JSONDecoder().decode(QFGetuiRegistration.self, from: $0) }
  }

  private func storeRegistration(_ value: QFGetuiRegistration) {
    if let data = try? JSONEncoder().encode(value) {
      UserDefaults.standard.set(data, forKey: Self.registrationKey)
    }
  }

  private func isLocallyDisabled(scope: String) -> Bool {
    UserDefaults.standard.bool(forKey: Self.localDisabledPrefix + scope)
  }

  private func storeLocalDisabled(_ disabled: Bool, scope: String) {
    UserDefaults.standard.set(disabled, forKey: Self.localDisabledPrefix + scope)
  }

  // MARK: - GeTuiSdkDelegate

  func geTuiSdkDidRegisterClient(_ clientId: String) {
    cid = normalizedCID(clientId)
    scheduleReconcile()
  }

  func getuiSdkGrantAuthorization(_ granted: Bool, error: Error?) {
    if granted { scheduleReconcile() }
    else {
      reconcileTask?.cancel()
      reconcileTask = Task { [weak self] in await self?.unregisterDeviceIfPossible() }
    }
  }

  func geTuiSdkNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    postNotification(notification.request.content.userInfo, response: nil)
    completionHandler([.badge, .sound, .banner, .list])
  }

  func geTuiSdkDidReceiveNotification(
    _ userInfo: [AnyHashable: Any], notificationCenter center: UNUserNotificationCenter?,
    response: UNNotificationResponse?,
    fetchCompletionHandler completionHandler: ((UIBackgroundFetchResult) -> Void)? = nil
  ) {
    postNotification(userInfo, response: response)
    completionHandler?(.noData)
  }

  func geTuiSdkDidReceiveSlience(
    _ userInfo: [AnyHashable: Any], fromGetui: Bool, offLine: Bool, appId: String?,
    taskId: String?, msgId: String?,
    fetchCompletionHandler completionHandler: ((UIBackgroundFetchResult) -> Void)? = nil
  ) {
    postNotification(userInfo, response: nil)
    // Getui replays transmission data after an APNs delivery. That replay must
    // never create a second banner when the user next opens the app.
    if fromGetui && !offLine { showOnlineNotification(userInfo) }
    completionHandler?(.noData)
  }

  private func showOnlineNotification(_ payload: [AnyHashable: Any]) {
    guard privacyConsentAccepted, sdkStarted, let app, app.user != nil,
      remindersEnabled(app: app), let content = QFOnlinePushContent.decode(payload),
      !displayedOnlineNotifications.contains(content.id)
    else { return }
    displayedOnlineNotifications.insert(content.id)
    onlineNotificationOrder.append(content.id)
    if onlineNotificationOrder.count > 128 {
      displayedOnlineNotifications.remove(onlineNotificationOrder.removeFirst())
    }
    let notification = UNMutableNotificationContent()
    notification.title = content.title
    notification.body = content.body
    notification.sound = .default
    notification.userInfo = content.route
    let routeType = content.route["type"] == "ASSISTANT_NUDGE" ? "assistant" : "plan"
    let request = UNNotificationRequest(
      identifier: "qfyp." + routeType + "." + content.id, content: notification, trigger: nil)
    UNUserNotificationCenter.current().add(request) { [weak self] error in
      guard error != nil else { return }
      Task { @MainActor [weak self] in
        self?.displayedOnlineNotifications.remove(content.id)
        self?.onlineNotificationOrder.removeAll { $0 == content.id }
      }
    }
  }

  private func postNotification(
    _ payload: [AnyHashable: Any], response: UNNotificationResponse?
  ) {
    var userInfo: [AnyHashable: Any] = ["payload": payload]
    if let response { userInfo["actionIdentifier"] = response.actionIdentifier }
    NotificationCenter.default.post(
      name: .qfDidReceiveRemoteNotification, object: nil, userInfo: userInfo)
  }
}
