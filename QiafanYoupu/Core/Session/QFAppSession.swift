import Foundation
import Combine

private struct QFSavedSession: Codable {
  let tokens: QFSessionTokens
  let accessExpiresAt: Date
  let refreshExpiresAt: Date
  let user: QFUserProfile?
  // The existing tokens remain paired with this key until a rotation is confirmed.
  // Optional so sessions saved before this field was introduced remain readable.
  var pendingRefreshOperationID: UUID?
}

@MainActor
final class QFAppSession: ObservableObject {
  @Published private(set) var configuration: QFServerConfig?
  @Published private(set) var configurationError: String?
  @Published private(set) var loadingConfiguration = false
  @Published private(set) var user: QFUserProfile?
  @Published private(set) var isLoggingIn = false
  @Published private(set) var sessionMessage: String?

  let api: QFAPIClient
  private let identity: QFDeviceIdentity
  private let keychain: QFKeychainStore
  private var saved: QFSavedSession?
  private var refreshTask: Task<QFSessionTokens, Error>?
  private var refreshTaskID: UUID?
  private var isLoggingOut = false
  private var started = false
  private var generation = 0

  init(api: QFAPIClient? = nil, identity: QFDeviceIdentity? = nil, keychain: QFKeychainStore? = nil)
  {
    let device = identity ?? QFDeviceIdentity()
    let client = api ?? QFAPIClient(identity: device)
    self.identity = device
    self.api = client
    self.keychain =
      keychain
      ?? QFKeychainStore(service: "com.talka.qiafanyoupu.session.\(client.environment.name)")
  }

  func start() async {
    guard !started else { return }
    started = true
    do {
      if let data = try keychain.read("current") {
        let stored = try JSONDecoder().decode(QFSavedSession.self, from: data)
        guard stored.tokens.isValid else {
          throw QFAPIError(code: 40100, message: "保存的登录信息无效，请重新登录。")
        }
        saved = stored
        api.accessToken = stored.tokens.accessToken
      }
    } catch { sessionMessage = error.localizedDescription }
    await loadConfiguration()
    guard saved != nil else { return }
    do { try await restoreUser() } catch { sessionMessage = error.localizedDescription }
  }

  func loadConfiguration() async {
    guard !loadingConfiguration else { return }
    loadingConfiguration = true
    configurationError = nil
    defer { loadingConfiguration = false }
    do { configuration = try await api.send(path: "app/config") } catch {
      configuration = nil
      configurationError = error.localizedDescription
    }
  }

  func loginAvailability(apple: Bool) -> String? {
    guard !isLoggingOut else { return "正在退出登录，请稍候。" }
    guard !loadingConfiguration else { return "正在获取启动配置，请稍候。" }
    guard let configuration else { return configurationError ?? "请先重试加载启动配置。" }
    guard configuration.agreements.isAvailable else { return "用户协议与隐私政策尚未配置，暂时无法登录。" }
    guard apple ? configuration.loginMethods.apple : configuration.loginMethods.quick else {
      return apple ? "Apple 登录暂未开放。" : "快速登录暂未开放。"
    }
    return nil
  }

  func login(authorizationCode: String? = nil, agreementAccepted: Bool) async throws {
    guard !isLoggingIn, !isLoggingOut else {
      throw QFAPIError(code: 40900, message: "登录状态正在更新，请稍候。")
    }
    if let reason = loginAvailability(apple: authorizationCode != nil) {
      throw QFAPIError(code: 50300, message: reason)
    }
    guard agreementAccepted else { throw QFAPIError(code: 40301, message: "请先阅读并同意用户协议和隐私政策。") }
    isLoggingIn = true
    defer { isLoggingIn = false }
    let credential = try identity.credential(environment: api.environment.name)
    let operationID = UUID()
    let body: Data
    let path: String
    if let authorizationCode {
      path = "auth/apple/sessions"
      body = try JSONEncoder().encode(
        QFAppleLoginBody(
          authorizationCode: authorizationCode, deviceCredential: credential,
          agreementAccepted: true))
    } else {
      path = "auth/quick/sessions"
      body = try JSONEncoder().encode(
        QFQuickLoginBody(deviceCredential: credential, agreementAccepted: true))
    }
    // One tap, one login request. There is no challenge call or automatic POST retry.
    let result: QFLoginResult = try await api.send(
      path: path, method: "POST", body: body, operationID: operationID)
    guard !Task.isCancelled else { throw CancellationError() }
    try persist(result.session, user: result.user)
    generation += 1
    cancelRefreshTask()
    user = result.user
    sessionMessage = nil
  }

  func restoreUser() async throws {
    guard saved != nil else { return }
    let currentGeneration = generation
    try checkGeneration(currentGeneration)
    if let stored = saved,
      stored.pendingRefreshOperationID != nil || stored.accessExpiresAt <= Date()
        || refreshTask != nil
    {
      try await refresh()
    }
    try checkGeneration(currentGeneration)
    // QFAPIClient shares MainActor and constructs its request before its first suspension.
    var requestToken = api.accessToken
    do {
      let profile: QFUserProfile
      do { profile = try await api.send(path: "me") } catch let error as QFAPIError
        where error.code == 40100
      {
        try checkGeneration(currentGeneration)
        // A late rejection for the previous access token must not rotate the new token again.
        if requestToken == api.accessToken { try await refresh() }
        try checkGeneration(currentGeneration)
        requestToken = api.accessToken
        profile = try await api.send(path: "me")
      }
      try checkGeneration(currentGeneration)
      user = profile
    } catch let error as QFAPIError where [40100, 40101, 40300].contains(error.code) {
      try checkGeneration(currentGeneration)
      if requestToken == api.accessToken && refreshTask == nil { try clearSession() }
      throw error
    }
  }

  func refresh() async throws {
    try await refresh(allowDuringLogout: false)
  }

  private func refresh(allowDuringLogout: Bool) async throws {
    guard !isLoggingOut || allowDuringLogout else {
      throw QFAPIError(code: 40900, message: "正在退出登录，请稍候。")
    }
    if let refreshTask {
      _ = try await refreshTask.value
      return
    }
    guard var stored = saved,
      stored.refreshExpiresAt > Date() || stored.pendingRefreshOperationID != nil
    else {
      try clearSession()
      throw QFAPIError(code: 40100, message: "登录已过期，请重新登录。")
    }
    let currentGeneration = generation
    let operationID = stored.pendingRefreshOperationID ?? UUID()
    if stored.pendingRefreshOperationID == nil {
      stored.pendingRefreshOperationID = operationID
      // Write before dispatch. Transport failure (or process termination) must not lose the key.
      try keychain.write(JSONEncoder().encode(stored), account: "current")
      saved = stored
    }
    let taskID = UUID()
    let task = Task<QFSessionTokens, Error> {
      defer {
        if refreshTaskID == taskID {
          refreshTask = nil
          refreshTaskID = nil
        }
      }
      do {
        let tokens: QFSessionTokens = try await api.send(
          path: "auth/sessions/refresh", method: "POST",
          body: JSONEncoder().encode(QFRefreshBody(refreshToken: stored.tokens.refreshToken)),
          operationID: operationID)
        try checkGeneration(currentGeneration, allowDuringLogout: true)
        try persist(tokens, user: user ?? stored.user)
        return tokens
      } catch let error as QFAPIError where [40100, 40101, 40300].contains(error.code) {
        try checkGeneration(currentGeneration, allowDuringLogout: true)
        try clearSession()
        throw error
      }
    }
    refreshTaskID = taskID
    refreshTask = task
    _ = try await task.value
  }

  func logout() async throws {
    guard !isLoggingOut, !isLoggingIn else {
      throw QFAPIError(code: 40900, message: "登录状态正在更新，请稍候。")
    }
    guard saved != nil else { return }
    isLoggingOut = true
    defer { isLoggingOut = false }
    let currentGeneration = generation
    // Join any rotation, even when our old access token has not locally expired yet.
    if let refreshTask { _ = try await refreshTask.value }
    try checkGeneration(currentGeneration, allowDuringLogout: true)
    if let stored = saved,
      stored.pendingRefreshOperationID != nil || stored.accessExpiresAt <= Date()
    {
      try await refresh(allowDuringLogout: true)
    }
    try checkGeneration(currentGeneration, allowDuringLogout: true)
    do {
      try await api.sendEmpty(path: "auth/sessions/current", method: "DELETE")
    } catch let error as QFAPIError where error.code == 40100 {
      // A lost DELETE response can leave a revoked session locally. Verify once with refresh;
      // a still-live session must be revoked using the newly confirmed access token.
      try checkGeneration(currentGeneration, allowDuringLogout: true)
      do {
        try await refresh(allowDuringLogout: true)
      } catch let confirmation as QFAPIError
        where [40100, 40101, 40300].contains(confirmation.code)
      {
        // refresh clears only after a matching-generation, definitive authentication failure.
        guard saved == nil else { throw confirmation }
        return
      }
      try checkGeneration(currentGeneration, allowDuringLogout: true)
      try await api.sendEmpty(path: "auth/sessions/current", method: "DELETE")
    }
    try checkGeneration(currentGeneration, allowDuringLogout: true)
    try clearSession()
  }

  private func checkGeneration(_ expected: Int, allowDuringLogout: Bool = false) throws {
    guard expected == generation, saved != nil, !isLoggingOut || allowDuringLogout else {
      throw CancellationError()
    }
  }

  private func cancelRefreshTask() {
    refreshTask?.cancel()
    refreshTask = nil
    refreshTaskID = nil
  }

  private func persist(_ tokens: QFSessionTokens, user: QFUserProfile?) throws {
    guard tokens.isValid else { throw QFAPIError(code: 50000, message: "服务器返回的登录凭证格式异常。") }
    let value = QFSavedSession(
      tokens: tokens,
      accessExpiresAt: Date().addingTimeInterval(
        TimeInterval(tokens.accessTokenExpiresIn - min(15, tokens.accessTokenExpiresIn))),
      refreshExpiresAt: Date().addingTimeInterval(TimeInterval(tokens.refreshTokenExpiresIn)),
      user: user, pendingRefreshOperationID: nil)
    try keychain.write(JSONEncoder().encode(value), account: "current")
    saved = value
    api.accessToken = tokens.accessToken
  }

  private func clearSession() throws {
    try keychain.remove("current")
    generation += 1
    cancelRefreshTask()
    saved = nil
    api.accessToken = nil
    user = nil
    // device-id and deviceCredential deliberately remain for quick-login account reuse.
  }
}
