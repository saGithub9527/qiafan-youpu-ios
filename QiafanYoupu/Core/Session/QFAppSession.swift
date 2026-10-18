import Combine
import Foundation
import Alamofire

private struct QFSavedSession: Codable {
  let tokens: QFSessionTokens
  let accessExpiresAt: Date
  let refreshExpiresAt: Date
  let user: QFUserProfile?
  // The existing tokens remain paired with this key until a rotation is confirmed.
  // Optional so sessions saved before this field was introduced remain readable.
  var pendingRefreshOperationID: UUID?
}

struct QFAccountDeletionOutcome {
  let appleAuthorizationRevocation: String
  let localCleanupComplete: Bool
}

private struct QFAccountDeletionResponse: Decodable {
  let appleAuthorizationRevocation: String
}

private struct QFAccountDeletionBody: Encodable {
  let confirmed: Bool
}

enum QFInterfaceLanguage: String, CaseIterable, Sendable {
  case simplifiedChinese = "zh-Hans"
  case traditionalChinese = "zh-Hant"
  case english = "en"
  case japanese = "ja"
  case korean = "ko"
  case russian = "ru"
  case spanish = "es"
  case french = "fr"
  case german = "de"
  case portugueseBrazil = "pt-BR"

  static func normalized(_ value: String?) -> Self {
    guard let code = value?.replacingOccurrences(of: "_", with: "-").lowercased(),
      !code.isEmpty
    else { return .simplifiedChinese }
    let subtags = code.split(separator: "-")
    if subtags.first == "zh" {
      if code == "zh-hant" || code.hasPrefix("zh-hant-")
        || subtags.contains(where: { ["tw", "hk", "mo"].contains($0) })
      {
        return .traditionalChinese
      }
      return .simplifiedChinese
    }
    switch subtags.first {
    case "en": return .english
    case "ja": return .japanese
    case "ko": return .korean
    case "ru": return .russian
    case "es": return .spanish
    case "fr": return .french
    case "de": return .german
    case "pt": return .portugueseBrazil
    default: return .simplifiedChinese
    }
  }

  var localeIdentifier: String {
    switch self {
    case .simplifiedChinese: return "zh-Hans"
    case .traditionalChinese: return "zh-Hant"
    case .english: return "en"
    case .japanese: return "ja"
    case .korean: return "ko"
    case .russian: return "ru"
    case .spanish: return "es"
    case .french: return "fr"
    case .german: return "de"
    case .portugueseBrazil: return "pt-BR"
    }
  }

  var autonym: String {
    switch self {
    case .simplifiedChinese: return "简体中文"
    case .traditionalChinese: return "繁體中文"
    case .english: return "English"
    case .japanese: return "日本語"
    case .korean: return "한국어"
    case .russian: return "Русский"
    case .spanish: return "Español"
    case .french: return "Français"
    case .german: return "Deutsch"
    case .portugueseBrazil: return "Português (Brasil)"
    }
  }

  func text(chinese: String, english: String) -> String {
    switch self {
    case .simplifiedChinese: return chinese
    case .english: return english
    default:
      guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
        let languageBundle = Bundle(path: path)
      else { return english }
      return languageBundle.localizedString(forKey: chinese, value: english, table: nil)
    }
  }
}

struct QFPlanningScope: Codable, Equatable, Sendable {
  let householdId: String?
  let householdName: String?

  static let personal = QFPlanningScope(householdId: nil, householdName: nil)
}

@MainActor
final class QFAppSession: ObservableObject {
  @Published private(set) var configuration: QFServerConfig?
  @Published private(set) var configurationError: String?
  @Published private(set) var loadingConfiguration = false
  @Published private(set) var user: QFUserProfile?
  @Published private(set) var userSettings: QFUserSettings?
  @Published private(set) var isLoggingIn = false
  @Published private(set) var sessionMessage: String?
  @Published private(set) var interfaceLanguage: String
  @Published private(set) var planningScope = QFPlanningScope.personal

  let contentCache = QFContentCache()
  func text(_ chinese: String, _ english: String) -> String {
    QFInterfaceLanguage.normalized(interfaceLanguage).text(chinese: chinese, english: english)
  }
  func format(_ chinese: String, _ english: String, _ arguments: CVarArg...) -> String {
    let language = QFInterfaceLanguage.normalized(interfaceLanguage)
    return String(
      format: language.text(chinese: chinese, english: english),
      locale: Locale(identifier: language.localeIdentifier), arguments: arguments)
  }
  private final class MediaBytes: NSObject {
    let data: Data
    let expires = Date().addingTimeInterval(120)
    init(_ data: Data) { self.data = data }
  }
  private let mediaBytes = NSCache<NSString, MediaBytes>()
  private let mediaByteEntries = NSMapTable<NSString, MediaBytes>.strongToWeakObjects()
  let api: QFAPIClient
  private let identity: QFDeviceIdentity
  private let keychain: QFKeychainStore
  private var saved: QFSavedSession?
  private var refreshTask: Task<QFSessionTokens, Error>?
  private var refreshTaskID: UUID?
  private var isLoggingOut = false
  private var started = false
  private var generation = 0

  var planningHouseholdID: String? { planningScope.householdId }

  func setPlanningScope(householdID: String?, householdName: String?) {
    let normalizedID = householdID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedName = householdName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let next = QFPlanningScope(
      householdId: normalizedID?.isEmpty == false ? normalizedID : nil,
      householdName: normalizedName?.isEmpty == false ? normalizedName : nil)
    guard next != planningScope else { return }
    planningScope = next
    contentCache.invalidatePlanningData(scope: contentScope)
    if let userID = user?.userId ?? saved?.user?.userId,
      let data = try? JSONEncoder().encode(next)
    {
      UserDefaults.standard.set(data, forKey: planningScopeKey(userID: userID))
    }
  }

  func reconcilePlanningScope(availableHouseholds: [(id: String, name: String)]) {
    guard let selectedID = planningScope.householdId else { return }
    guard let current = availableHouseholds.first(where: { $0.id == selectedID }) else {
      setPlanningScope(householdID: nil, householdName: nil)
      return
    }
    if current.name != planningScope.householdName {
      setPlanningScope(householdID: current.id, householdName: current.name)
    }
  }

  init(api: QFAPIClient? = nil, identity: QFDeviceIdentity? = nil, keychain: QFKeychainStore? = nil)
  {
    let device = identity ?? QFDeviceIdentity()
    let client = api ?? QFAPIClient(identity: device)
    let language = QFInterfaceLanguage.normalized(
      QFLocalSettingsStore.current().interfaceLanguage).rawValue
    self.identity = device
    self.api = client
    interfaceLanguage = language
    client.interfaceLanguage = language
    mediaBytes.totalCostLimit = 32 * 1024 * 1024
    mediaBytes.countLimit = 40
    self.keychain =
      keychain
      ?? QFKeychainStore(service: "com.talka.qiafanyoupu.session.\(client.environment.name)")
  }

  @discardableResult
  func setInterfaceLanguage(_ value: String) -> Bool {
    let language = QFInterfaceLanguage.normalized(value).rawValue
    api.interfaceLanguage = language
    guard interfaceLanguage != language else { return false }
    interfaceLanguage = language
    return true
  }

  func start() async {
    guard !started else { return }
    started = true
    do {
      if let data = try keychain.read("current") {
        let stored = try JSONDecoder().decode(QFSavedSession.self, from: data)
        guard stored.tokens.isValid else {
          throw QFAPIError(
            code: 40100,
            message: text("保存的登录信息无效，请重新登录。", "The saved sign-in information is invalid. Sign in again."))
        }
        saved = stored
        api.accessToken = stored.tokens.accessToken
      }
    } catch { sessionMessage = userMessage(for: error) }
    await loadConfiguration()
    guard saved != nil else { return }
    // A lost deletion response can leave a revoked session on disk. Confirm its receipt with
    // the original Bearer/key before restoreUser refreshes or discards that session.
    if let owner = saved?.user,
      let operation = UserDefaults.standard.string(
        forKey: "qf.account.deletion.request.\(api.environment.name).\(owner.userId)"),
      UUID(uuidString: operation) != nil
    {
      do {
        _ = try await deleteAccount()
        return
      } catch let error as QFAPIError where error.code == 40302 {
        // The server definitively rejected this request before starting deletion.
      } catch {
        // Keep the original token and local drafts until the result can be confirmed.
        user = saved?.user
        sessionMessage = text(
          "注销结果尚未确认，请在账号与隐私中重试。",
          "Deletion is not confirmed. Retry in Account & Privacy.")
        return
      }
    }
    do { try await restoreUser() } catch { sessionMessage = userMessage(for: error) }
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
    guard !isLoggingOut else { return text("正在退出登录，请稍候。", "Signing out. Please wait.") }
    guard !loadingConfiguration else { return text("正在获取启动配置，请稍候。", "Loading app configuration. Please wait.") }
    guard let configuration else {
      return configurationError ?? text("请先重试加载启动配置。", "Retry loading the app configuration first.")
    }
    guard configuration.agreements.isAvailable else {
      return text(
        "用户协议与隐私政策尚未配置，暂时无法登录。",
        "The Terms of Service and Privacy Policy are not configured, so sign-in is temporarily unavailable.")
    }
    guard apple ? configuration.loginMethods.apple : configuration.loginMethods.quick else {
      return apple
        ? text("Apple 登录暂未开放。", "Sign in with Apple is not available yet.")
        : text("快速登录暂未开放。", "Quick sign-in is not available yet.")
    }
    return nil
  }

  func login(authorizationCode: String? = nil, agreementAccepted: Bool) async throws {
    guard !isLoggingIn, !isLoggingOut else {
      throw QFAPIError(code: 40900, message: text("登录状态正在更新，请稍候。", "The sign-in state is updating. Please wait."))
    }
    if let reason = loginAvailability(apple: authorizationCode != nil) {
      throw QFAPIError(code: 50300, message: reason)
    }
    guard agreementAccepted else {
      throw QFAPIError(
        code: 40301,
        message: text(
          "请先阅读并同意用户协议和隐私政策。",
          "Read and agree to the Terms of Service and Privacy Policy first."))
    }
    isLoggingIn = true
    defer { isLoggingIn = false }
    let credential: String
    do {
      credential = try identity.credential(environment: api.environment.name)
    } catch QFCredentialError.invalidStoredCredential {
      throw QFAPIError(
        code: 40101,
        message: text(
          "本机登录凭证损坏，请联系支持处理，避免生成重复账号。",
          "The sign-in credential on this device is damaged. Contact support so a duplicate account is not created."))
    } catch is QFKeychainError {
      throw QFAPIError(
        code: 50000,
        message: text(
          "无法访问本机安全凭证，请解锁设备后重试。",
          "The secure credential on this device could not be accessed. Unlock the device and try again."))
    }
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
    restorePlanningScope(userID: result.user.userId)
    user = result.user
    sessionMessage = nil
  }

  private func userMessage(for error: Error) -> String {
    if error is QFKeychainError {
      return text(
        "无法访问本机安全凭证，请解锁设备后重试。",
        "The secure credential on this device could not be accessed. Unlock the device and try again.")
    }
    return error.localizedDescription
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
      try Task.checkCancellation()
      try acceptRestoredProfile(profile)
    } catch let error as QFAPIError where [40100, 40101, 40300].contains(error.code) {
      try checkGeneration(currentGeneration)
      if requestToken == api.accessToken && refreshTask == nil { try clearSession() }
      throw error
    }
  }

  private func acceptRestoredProfile(_ profile: QFUserProfile) throws {
    guard let latest = saved else { throw CancellationError() }
    if latest.user?.countryCode != profile.countryCode
      || latest.user?.regionCode != profile.regionCode
    {
      contentCache.invalidateCatalogRecommendations(scope: contentScope)
    }
    if latest.user != profile {
      let next = QFSavedSession(
        tokens: latest.tokens, accessExpiresAt: latest.accessExpiresAt,
        refreshExpiresAt: latest.refreshExpiresAt, user: profile,
        pendingRefreshOperationID: latest.pendingRefreshOperationID)
      try keychain.write(JSONEncoder().encode(next), account: "current")
      saved = next
    }
    // /me does not contain avatarMediaId. Merge its fields into the existing public
    // snapshot without discarding the separately loaded or just-saved avatar.
    if var cached = contentCache.peek(
      QFPublicProfile.self, scope: contentScope, path: "me/public-profile")
    {
      let previous = cached
      cached.nickname = profile.nickname
      cached.countryCode = profile.countryCode
      cached.regionCode = profile.regionCode
      cached.bio = profile.bio
      if cached != previous {
        contentCache.didWrite(cached, scope: contentScope, path: "me/public-profile")
      }
    } else if let previous = latest.user,
      previous.nickname != profile.nickname || previous.countryCode != profile.countryCode
        || previous.regionCode != profile.regionCode || previous.bio != profile.bio
    {
      contentCache.didWrite((), scope: contentScope, path: "me/public-profile")
    }
    if user?.userId != profile.userId { restorePlanningScope(userID: profile.userId) }
    if user != profile { user = profile }
  }

  @discardableResult
  func loadUserSettings() async throws -> QFUserSettings {
    guard saved != nil else {
      throw QFAPIError(code: 40100, message: text("请先登录后再同步设置。", "Sign in before syncing settings."))
    }
    let value: QFUserSettings = try await contentRequest(path: "me/settings")
    userSettings = value
    return value
  }

  @discardableResult
  func updateUserSettings(_ value: QFUserSettings) async throws -> QFUserSettings {
    guard saved != nil else {
      throw QFAPIError(code: 40100, message: text("请先登录后再同步设置。", "Sign in before syncing settings."))
    }
    let body = QFUserSettingsUpdate(
      planReminders: value.planReminders,
      workAndContributionUpdates: value.workAndContributionUpdates)
    let currentGeneration = generation
    try await refreshIfNeededForContent()
    let token = api.accessToken
    let operationID = UUID()
    let updated: QFUserSettings
    do {
      updated = try await api.send(
        path: "me/settings", method: "PUT", body: JSONEncoder().encode(body),
        operationID: operationID)
    } catch let error as QFAPIError where error.code == 40100 {
      try checkGeneration(currentGeneration)
      if token == api.accessToken { try await refresh() }
      try checkGeneration(currentGeneration)
      updated = try await api.send(
        path: "me/settings", method: "PUT", body: JSONEncoder().encode(body),
        operationID: operationID)
    }
    try checkGeneration(currentGeneration)
    contentCache.didWrite(updated, scope: contentScope, path: "me/settings")
    userSettings = updated
    return updated
  }

  @discardableResult
  func updateProfile(_ value: QFProfileUpdate) async throws -> QFUserProfile {
    guard saved != nil else {
      throw QFAPIError(code: 40100, message: text("请先登录后再修改资料。", "Sign in before editing your profile."))
    }
    let currentGeneration = generation
    let updated: QFUserProfile = try await api.send(
      path: "me", method: "PATCH", body: JSONEncoder().encode(value))
    try checkGeneration(currentGeneration)
    guard let latest = saved else { throw CancellationError() }
    let next = QFSavedSession(
      tokens: latest.tokens,
      accessExpiresAt: latest.accessExpiresAt,
      refreshExpiresAt: latest.refreshExpiresAt,
      user: updated,
      pendingRefreshOperationID: latest.pendingRefreshOperationID)
    try keychain.write(JSONEncoder().encode(next), account: "current")
    saved = next
    user = updated
    return updated
  }

  func submitFeedback(category: QFFeedbackCategory, content: String) async throws {
    guard saved != nil else {
      throw QFAPIError(code: 40100, message: text("请先登录后再提交反馈。", "Sign in before submitting feedback."))
    }
    let currentGeneration = generation
    let body = QFFeedbackRequest(category: category, content: content)
    try await contentMutation(
      path: "me/feedback", method: "POST", body: JSONEncoder().encode(body))
    try checkGeneration(currentGeneration)
  }

  func bindAccount(_ account: String, operationID: UUID) async throws {
    let body = try JSONSerialization.data(withJSONObject: ["boundAccount": account])
    let profile: QFUserProfile = try await contentRequest(path: "me/bound-account", method: "PUT", body: body, operationID: operationID)
    try cacheAccountProfile(profile)
  }

  func bindApple(_ authorizationCode: String, operationID: UUID) async throws {
    let body = try JSONSerialization.data(withJSONObject: ["authorizationCode": authorizationCode])
    let profile: QFUserProfile = try await contentRequest(
      path: "me/apple", method: "PUT", body: body, operationID: operationID)
    try cacheAccountProfile(profile)
  }

  func setPassword(_ newPassword: String, oldPassword: String?, operationID: UUID) async throws {
    var values = ["newPassword": newPassword]
    if let oldPassword { values["oldPassword"] = oldPassword }
    try await contentMutation(path: "me/password", method: "PUT", body: JSONSerialization.data(withJSONObject: values), operationID: operationID)
    guard let previous = user else { throw CancellationError() }
    let profile = QFUserProfile(userId: previous.userId, systemAccount: previous.systemAccount,
      boundAccount: previous.boundAccount, accountNameBound: previous.accountNameBound,
      passwordConfigured: true, nickname: previous.nickname, avatarUrl: previous.avatarUrl,
      countryCode: previous.countryCode, regionCode: previous.regionCode, bio: previous.bio, appleBound: previous.appleBound)
    try cacheAccountProfile(profile)
  }

  private func cacheAccountProfile(_ profile: QFUserProfile) throws {
    guard let previous = saved, previous.user?.userId == profile.userId else { throw CancellationError() }
    let next = QFSavedSession(tokens: previous.tokens, accessExpiresAt: previous.accessExpiresAt,
      refreshExpiresAt: previous.refreshExpiresAt, user: profile, pendingRefreshOperationID: previous.pendingRefreshOperationID)
    try keychain.write(JSONEncoder().encode(next), account: "current")
    saved = next
    user = profile
  }

  func refresh() async throws {
    try await refresh(allowDuringLogout: false)
  }

  /// Shared authenticated business request: join token rotation and reject results after account changes.
  var contentScope: String {
    api.environment.name + "." + (api.environment.baseURL?.absoluteString ?? "") + "."
      + (user?.userId ?? saved?.user?.userId ?? "signed-out")
  }
  func cachedContent<Value>(_ type: Value.Type, path: String) -> Value? {
    guard user != nil else { return nil }
    return contentCache.peek(type, scope: contentScope, path: path)
  }

  /// Cached localized read for content that is intentionally available before login.
  /// When a session exists it still joins token rotation, so personalized fields such as
  /// `isFavorite` and `myRating` are returned without maintaining a second request path.
  func publicContentRequest<Value: Decodable>(
    path: String, query: [String: String] = [:]
  ) async throws -> Value {
    let scope = contentScope
    let language = interfaceLanguage
    api.interfaceLanguage = language
    var cacheQuery = query
    cacheQuery["__language"] = language
    let value: Value = try await contentCache.read(
      scope: scope, path: path, query: cacheQuery
    ) { [self] in
      try await QFContentLoadingContext.$language.withValue(language) {
        if saved != nil {
          return try await performContentRequest(
            path: path, method: "GET", body: nil, query: query)
        }
        return try await api.send(path: path, query: query)
      }
    }
    try Task.checkCancellation()
    guard contentScope == scope, interfaceLanguage == language else { throw CancellationError() }
    return value
  }

  func contentRequest<Value: Decodable>(
    path: String, method: String = "GET", body: Data? = nil,
    query: [String: String] = [:], operationID: UUID? = nil
  ) async throws -> Value {
    let scope = contentScope
    let language = interfaceLanguage
    api.interfaceLanguage = language
    guard saved != nil else { throw QFAPIError(code: 40100, message: text("请先登录。", "Sign in first.")) }
    if method == "GET" {
      let localized = isLocalizedContentPath(path)
      var cacheQuery = query
      if localized { cacheQuery["__language"] = language }
      let value: Value = try await contentCache.read(scope: scope, path: path, query: cacheQuery) {
        [self] in
        try await QFContentLoadingContext.$language.withValue(language) {
          try await performContentRequest(path: path, method: method, body: body, query: query)
        }
      }
      try Task.checkCancellation()
      guard contentScope == scope, !localized || interfaceLanguage == language else {
        throw CancellationError()
      }
      return value
    }
    let value: Value = try await performContentRequest(
      path: path, method: method, body: body, query: query, operationID: operationID)
    // This POST is an explicitly read-only quote for a local draft, not a domain mutation.
    if path != "me/cooking-cost-previews" { contentCache.didWrite(value, scope: scope, path: path) }
    return value
  }

  func assistantVisionPreview(imageData: Data, mimeType: String, text: String) async throws -> QFAssistantPreview {
    let currentGeneration = generation
    let language = interfaceLanguage
    api.interfaceLanguage = language
    guard saved != nil else { throw QFAPIError(code: 40100, message: self.text("请先登录。", "Sign in first.")) }
    try checkGeneration(currentGeneration)
    if let stored = saved,
      stored.accessExpiresAt <= Date() || stored.pendingRefreshOperationID != nil || refreshTask != nil
    {
      try await refresh()
    }
    try checkGeneration(currentGeneration)
    let fields = ["text": text, "allowCloud": "true"]
    let token = api.accessToken
    let result: QFAssistantPreview
    do {
      result = try await api.sendMultipart(path: "me/assistant/vision", fileData: imageData,
        mimeType: mimeType, filename: "assistant-image.jpg", fields: fields)
    } catch let error as QFAPIError where error.code == 40100 {
      try checkGeneration(currentGeneration)
      if token == api.accessToken { try await refresh() }
      try checkGeneration(currentGeneration)
      result = try await api.sendMultipart(path: "me/assistant/vision", fileData: imageData,
        mimeType: mimeType, filename: "assistant-image.jpg", fields: fields)
    }
    try checkGeneration(currentGeneration)
    guard interfaceLanguage == language else { throw CancellationError() }
    return result
  }

  func assistantStream(text: String, history: [QFOnDeviceInference.Turn], imageData: Data?, mimeType: String,
    allowWebSearch: Bool = true,
    onEvent: @escaping (QFAssistantStreamEvent) -> Void) async throws -> QFAssistantStreamResult {
    let currentGeneration = generation, binding = QFAssistantAgent.scope(self)
    let networkEnabled = QFLocalModelViewController.networkEnabled(self)
    // A caller may further restrict a single request; it can never enable a disabled preference.
    let allowWeb = networkEnabled && allowWebSearch
    guard saved != nil else { throw QFAPIError(code: 40100, message: self.text("请先登录。", "Sign in first.")) }
    try checkGeneration(currentGeneration)
    if let stored = saved, stored.accessExpiresAt <= Date() || stored.pendingRefreshOperationID != nil || refreshTask != nil { try await refresh() }
    let turns = Array(history.suffix(8))
    let payload = QFAssistantChatRequest(text: text, allowCloud: true,
      allowWeb: configuration?.assistantCapabilities?.chatWebConsent == true ? allowWeb : nil, history: turns,
      householdId: binding.household, timeZone: TimeZone.current.identifier)
    let (body, type) = try payload.encoded(imageData: imageData, mimeType: mimeType)
    let operationID = UUID(), token = api.accessToken
    func check() throws {
      try Task.checkCancellation(); try checkGeneration(currentGeneration)
      guard QFAssistantAgent.scope(self) == binding,
        QFLocalModelViewController.networkEnabled(self) == networkEnabled else { throw CancellationError() }
    }
    let handler: (QFAssistantStreamEvent) throws -> Void = { event in
      try check(); onEvent(event)
    }
    try check(); api.interfaceLanguage = binding.language
    let result: QFAssistantStreamResult
    do { result = try await api.assistantStream(body: body, contentType: type, operationID: operationID, onEvent: handler) }
    catch is QFAssistantStreamHTTPUnauthorized {
      try check(); if token == api.accessToken { try await refresh() }; try check()
      do { result = try await api.assistantStream(body: body, contentType: type, operationID: operationID, onEvent: handler) }
      catch let rejection as QFAssistantStreamHTTPUnauthorized { throw rejection.failure }
    }
    try check(); return result
  }

  private func performContentRequest<Value: Decodable>(
    path: String, method: String, body: Data?,
    query: [String: String], operationID: UUID? = nil
  ) async throws -> Value {
    let currentGeneration = generation
    guard saved != nil else { throw QFAPIError(code: 40100, message: text("请先登录。", "Sign in first.")) }
    try checkGeneration(currentGeneration)
    if let stored = saved,
      stored.accessExpiresAt <= Date() || stored.pendingRefreshOperationID != nil
        || refreshTask != nil
    {
      try await refresh()
    }
    try checkGeneration(currentGeneration)
    let token = api.accessToken
    let result: Value
    do {
      result = try await api.send(path: path, method: method, body: body, operationID: operationID, query: query)
    } catch let error as QFAPIError where error.code == 40100 {
      try checkGeneration(currentGeneration)
      if token == api.accessToken { try await refresh() }
      try checkGeneration(currentGeneration)
      result = try await api.send(path: path, method: method, body: body, operationID: operationID, query: query)
    }
    try checkGeneration(currentGeneration)
    return result
  }

  func contentMutation(
    path: String, method: String, body: Data? = nil, query: [String: String] = [:],
    operationID: UUID? = nil
  ) async throws {
    let currentGeneration = generation
    guard saved != nil else { throw QFAPIError(code: 40100, message: text("请先登录。", "Sign in first.")) }
    try checkGeneration(currentGeneration)
    if let stored = saved,
      stored.accessExpiresAt <= Date() || stored.pendingRefreshOperationID != nil
        || refreshTask != nil
    {
      try await refresh()
    }
    try checkGeneration(currentGeneration)
    let token = api.accessToken
    do {
      try await api.sendEmpty(
        path: path, method: method, body: body, operationID: operationID, query: query)
    } catch let error
      as QFAPIError where error.code == 40100
    {
      try checkGeneration(currentGeneration)
      if token == api.accessToken { try await refresh() }
      try checkGeneration(currentGeneration)
      try await api.sendEmpty(
        path: path, method: method, body: body, operationID: operationID, query: query)
    }
    try checkGeneration(currentGeneration)
    contentCache.didWrite((), scope: contentScope, path: path)
  }

  private func isLocalizedContentPath(_ path: String) -> Bool {
    path == "profile/options" || path == "me/favorites" || path == "catalog"
      || path.hasPrefix("catalog/") || path == "measurement-units"
      || path == "me/planned-meals" || path.hasPrefix("me/planned-meals/")
      || path.hasPrefix("me/planned-meal-slots/") || path == "me/inventory"
      || path.hasPrefix("me/shopping-lists") || path.hasPrefix("me/weekly-plan-proposals")
      || path.hasPrefix("me/cooking-statistics") || path.hasPrefix("me/ingredient-combinations") || path.hasPrefix("me/cooking-costs") || path.hasPrefix("me/purchase-receipts")
      || path.hasPrefix("me/preparation-expenses") || path.hasPrefix("me/cooking-records")
  }

  func refreshIfNeededForContent() async throws {
    let currentGeneration = generation
    guard let stored = saved else { throw QFAPIError(code: 40100, message: text("请先登录。", "Sign in first.")) }
    try checkGeneration(currentGeneration)
    if stored.accessExpiresAt <= Date() || stored.pendingRefreshOperationID != nil
      || refreshTask != nil
    {
      try await refresh()
    }
    try checkGeneration(currentGeneration)
  }

  func uploadContentMedia(_ data: Data, mimeType: String, filename: String) async throws
    -> QFContentMedia
  {
    let currentGeneration = generation
    try await refreshIfNeededForContent()
    try checkGeneration(currentGeneration)
    let token = api.accessToken
    let media: QFContentMedia
    do { media = try await api.uploadMedia(data, mimeType: mimeType, filename: filename) } catch let
      error as QFAPIError where [401, 40100].contains(error.code)
    {
      try checkGeneration(currentGeneration)
      if token == api.accessToken { try await refresh() }
      try checkGeneration(currentGeneration)
      media = try await api.uploadMedia(data, mimeType: mimeType, filename: filename)
    }
    try checkGeneration(currentGeneration)
    if media.kind == "IMAGE", data.count <= 8 * 1024 * 1024 {
      cacheMediaBytes(data, key: (contentScope + "|" + media.id) as NSString)
    }
    return media
  }

  private func cacheMediaBytes(_ data: Data, key: NSString) {
    if mediaByteEntries.count > 128 {
      for storedKey in mediaByteEntries.keyEnumerator().allObjects {
        guard let storedKey = storedKey as? NSString else { continue }
        if mediaByteEntries.object(forKey: storedKey) == nil { mediaByteEntries.removeObject(forKey: storedKey) }
      }
    }
    let entry = MediaBytes(data)
    mediaBytes.setObject(entry, forKey: key, cost: data.count)
    mediaByteEntries.setObject(entry, forKey: key)
  }
  var contentMediaCacheSize: Int {
    (mediaByteEntries.objectEnumerator()?.allObjects as? [MediaBytes] ?? []).reduce(0) { $0 + $1.data.count }
  }
  func clearContentMediaCache() { mediaBytes.removeAllObjects(); mediaByteEntries.removeAllObjects() }

  func loadContentMedia(_ id: String) async throws -> Data {
    if QFLocalMediaStore.isLocal(id) {
      let scope = contentScope
      let url = try QFLocalMediaStore.url(id, scope: scope)
      let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
      try Task.checkCancellation()
      guard contentScope == scope else { throw CancellationError() }
      return data
    }
    let key = (contentScope + "|" + id) as NSString
    if let bytes = mediaBytes.object(forKey: key), bytes.expires > Date() {
      return bytes.data
    }
    if saved == nil {
      let scope = contentScope
      let data = try await api.loadMedia(id)
      try Task.checkCancellation()
      guard contentScope == scope else { throw CancellationError() }
      if data.count <= 8 * 1024 * 1024 { cacheMediaBytes(data, key: key) }
      return data
    }
    let currentGeneration = generation
    try await refreshIfNeededForContent()
    try checkGeneration(currentGeneration)
    let token = api.accessToken
    let data: Data
    do { data = try await api.loadMedia(id) } catch let error as QFAPIError
      where [401, 40100].contains(error.code)
    {
      try checkGeneration(currentGeneration)
      if token == api.accessToken { try await refresh() }
      try checkGeneration(currentGeneration)
      data = try await api.loadMedia(id)
    }
    try checkGeneration(currentGeneration)
    if data.count <= 8 * 1024 * 1024 {
      cacheMediaBytes(data, key: key)
    }
    return data
  }

  func savePublicProfile(_ value: QFPublicProfile) async throws {
    let currentGeneration = generation
    let updated: QFPublicProfile = try await contentRequest(
      path: "me/public-profile", method: "PUT", body: JSONEncoder().encode(value))
    try checkGeneration(currentGeneration)
    guard let previous = user, let stored = saved else { throw CancellationError() }
    if previous.countryCode != updated.countryCode || previous.regionCode != updated.regionCode {
      contentCache.invalidateCatalogRecommendations(scope: contentScope)
    }
    let profile = QFUserProfile(
      userId: previous.userId, systemAccount: previous.systemAccount,
      boundAccount: previous.boundAccount, accountNameBound: previous.accountNameBound,
      passwordConfigured: previous.passwordConfigured, nickname: updated.nickname, avatarUrl: nil,
      countryCode: updated.countryCode, regionCode: updated.regionCode, bio: updated.bio,
      appleBound: previous.appleBound)
    let next = QFSavedSession(
      tokens: stored.tokens, accessExpiresAt: stored.accessExpiresAt,
      refreshExpiresAt: stored.refreshExpiresAt, user: profile,
      pendingRefreshOperationID: stored.pendingRefreshOperationID)
    try keychain.write(JSONEncoder().encode(next), account: "current")
    saved = next
    user = profile
  }

  private func refresh(allowDuringLogout: Bool) async throws {
    guard !isLoggingOut || allowDuringLogout else {
      throw QFAPIError(code: 40900, message: text("正在退出登录，请稍候。", "Signing out. Please wait."))
    }
    if let refreshTask {
      _ = try await refreshTask.value
      return
    }
    guard var stored = saved,
      stored.refreshExpiresAt > Date() || stored.pendingRefreshOperationID != nil
    else {
      try clearSession()
      throw QFAPIError(code: 40100, message: text("登录已过期，请重新登录。", "Your sign-in expired. Sign in again."))
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
      throw QFAPIError(code: 40900, message: text("登录状态正在更新，请稍候。", "The sign-in state is updating. Please wait."))
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

  /// The server is the source of truth. Never erase local drafts on a failed or ambiguous request.
  func deleteAccount() async throws -> QFAccountDeletionOutcome {
    guard !isLoggingOut, !isLoggingIn, let owner = user ?? saved?.user else {
      throw QFAPIError(code: 40900, message: text("登录状态正在更新，请稍候。", "The sign-in state is updating. Please wait."))
    }
    isLoggingOut = true
    defer { isLoggingOut = false }
    let currentGeneration = generation
    if let refreshTask { _ = try await refreshTask.value }
    try checkGeneration(currentGeneration, allowDuringLogout: true)
    let environment = api.environment.name
    let defaults = UserDefaults.standard
    let requestKey = "qf.account.deletion.request.\(environment).\(owner.userId)"
    let pendingID = defaults.string(forKey: requestKey).flatMap(UUID.init(uuidString:))
    if pendingID == nil, let stored = saved,
      stored.pendingRefreshOperationID != nil || stored.accessExpiresAt <= Date()
    {
      try await refresh(allowDuringLogout: true)
    }
    try checkGeneration(currentGeneration, allowDuringLogout: true)
    let operationID = pendingID ?? UUID()
    if pendingID == nil { defaults.set(operationID.uuidString.lowercased(), forKey: requestKey) }
    let result: QFAccountDeletionResponse
    do {
      result = try await api.send(
        path: "me/account", method: "DELETE",
        body: JSONEncoder().encode(QFAccountDeletionBody(confirmed: true)),
        operationID: operationID)
    } catch let error as QFAPIError where error.code == 40302 {
      // A definitive recent-login rejection did not begin the deletion transaction.
      defaults.removeObject(forKey: requestKey)
      throw error
    }
    try checkGeneration(currentGeneration, allowDuringLogout: true)
    let scope = contentScope
    var cleanupComplete = true
    defaults.removeObject(forKey: requestKey)
    contentCache.clearAccount(scope: scope)
    defaults.removeObject(forKey: "qf.settings.pending." + scope)
    defaults.removeObject(forKey: "qfyp.user.settings.v1." + scope)
    defaults.removeObject(forKey: "qf.assistant.cloud-consent." + scope)
    defaults.removeObject(forKey: "qf.assistant.local-network." + scope)
    defaults.removeObject(forKey: "qf.planning.scope.v1.\(environment).\(owner.userId)")
    defaults.removeObject(forKey: "qfyp.getui.local-disabled." + scope)
    QFGetuiPushService.shared.forgetDeletedAccount(
      environment: environment, userID: owner.userId)
    QFContentDraftStore.removeAll(environment: environment, userID: owner.userId)
    do { try QFLocalMediaStore.removeAll(scope: scope) } catch { cleanupComplete = false }
    await withCheckedContinuation { continuation in
      QFContentImageCache.shared.clearDiskCache { continuation.resume() }
    }
    await withCheckedContinuation { continuation in
      QFRemoteImagePipeline.cache.clearDiskCache { continuation.resume() }
    }
    do { try identity.forgetDeletedAccount(environment: environment) } catch { cleanupComplete = false }
    do { try keychain.remove("current") } catch { cleanupComplete = false }
    finishSessionClear()
    return QFAccountDeletionOutcome(
      appleAuthorizationRevocation: result.appleAuthorizationRevocation,
      localCleanupComplete: cleanupComplete)
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
    guard tokens.isValid else {
      throw QFAPIError(
        code: 50000,
        message: text("服务器返回的登录凭证格式异常。", "The server returned invalid sign-in credentials."))
    }
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
    finishSessionClear()
  }

  private func finishSessionClear() {
    contentCache.clearMemory()
    clearContentMediaCache()
    QFContentImageCache.shared.clearMemoryCache()
    generation += 1
    cancelRefreshTask()
    saved = nil
    api.accessToken = nil
    user = nil
    userSettings = nil
    planningScope = .personal
    // device-id and deviceCredential deliberately remain for quick-login account reuse.
  }

  private func restorePlanningScope(userID: String) {
    let stored = UserDefaults.standard.data(forKey: planningScopeKey(userID: userID))
      .flatMap { try? JSONDecoder().decode(QFPlanningScope.self, from: $0) }
      ?? .personal
    if planningScope != stored { planningScope = stored }
  }

  private func planningScopeKey(userID: String) -> String {
    "qf.planning.scope.v1.\(api.environment.name).\(userID)"
  }
}
