import Alamofire
import Foundation

struct QFAPIEnvironment {
  let name: String
  let baseURL: URL?

  static var current: QFAPIEnvironment {
    let raw = Bundle.main.object(forInfoDictionaryKey: "QFAPIBaseURL") as? String ?? ""
    let name =
      Bundle.main.object(forInfoDictionaryKey: "QFAPIEnvironment") as? String ?? "production"
    return QFAPIEnvironment(name: name, baseURL: URL(string: raw))
  }
}

@MainActor
final class QFAPIClient {
  let environment: QFAPIEnvironment
  private let identity: QFDeviceIdentity
  private let transport: Alamofire.Session
  private let mediaTransport: Alamofire.Session
  private lazy var assistantTransport = Self.makeTransport(configuration: .ephemeral, requestTimeout: 45, resourceTimeout: 240, waitsForConnectivity: true)
  var accessToken: String?
  var interfaceLanguage = "zh-Hans"
  #if DEBUG
    var recordsRequests = true
    var requestLogStore: QFRequestLogStore?
  #endif

  init(
    environment: QFAPIEnvironment = .current, identity: QFDeviceIdentity? = nil,
    transportConfiguration: URLSessionConfiguration? = nil
  ) {
    self.environment = environment
    self.identity = identity ?? QFDeviceIdentity()
    self.transport = Self.makeTransport(configuration: transportConfiguration ?? .ephemeral)
    self.mediaTransport = Self.makeTransport(
      configuration: transportConfiguration ?? .ephemeral, requestTimeout: 60, resourceTimeout: 180)
  }

  private func text(_ chinese: String, _ english: String) -> String {
    QFInterfaceLanguage.normalized(interfaceLanguage).text(chinese: chinese, english: english)
  }

  static func makeTransport(configuration source: URLSessionConfiguration,
    requestTimeout: TimeInterval = 20, resourceTimeout: TimeInterval = 30,
    waitsForConnectivity: Bool? = nil) -> Alamofire.Session {
    let configuration = source.copy() as? URLSessionConfiguration ?? .ephemeral
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = resourceTimeout
    if let waitsForConnectivity { configuration.waitsForConnectivity = waitsForConnectivity }
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    return Alamofire.Session(
      configuration: configuration,
      interceptor: nil,
      redirectHandler: Redirector(behavior: .doNotFollow),
      cachedResponseHandler: ResponseCacher(behavior: .doNotCache),
      eventMonitors: [])
  }

  func send<Value: Decodable>(
    path: String, method: String = "GET", body: Data? = nil,
    operationID: UUID? = nil, query: [String: String] = [:]
  ) async throws -> Value {
    let envelope: QFAPIEnvelope<Value> = try await perform(
      path: path, method: method, body: body, operationID: operationID, query: query)
    guard let result = envelope.data else {
      throw QFAPIError(
        code: 50000, message: text("服务器返回的数据不完整。", "The server response is incomplete."),
        requestId: envelope.requestId)
    }
    return result
  }

  func sendEmpty(
    path: String, method: String, body: Data? = nil, operationID: UUID? = nil,
    query: [String: String] = [:]
  ) async throws {
    let _: QFAPIEnvelope<QFEmptyResponse> = try await perform(
      path: path, method: method, body: body, operationID: operationID, query: query)
  }

  func assistantStream(body: Data, contentType: String, operationID: UUID,
    onEvent: @escaping (QFAssistantStreamEvent) throws -> Void) async throws -> QFAssistantStreamResult {
    var request = try makeRequest(path: "me/assistant/chat/stream", method: "POST", body: body, operationID: operationID)
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    return try await QFAssistantStreamRun(language: interfaceLanguage, onEvent: onEvent).start(transport: assistantTransport, request: request)
  }

  /// Uploads a bounded assistant attachment without putting binary data into the
  /// JSON request logger. The server decides whether the provider can process it.
  func sendMultipart<Value: Decodable>(
    path: String, fileData: Data, mimeType: String, filename: String,
    fields: [String: String] = [:]
  ) async throws -> Value {
    try Task.checkCancellation()
    guard fileData.count <= 8 * 1024 * 1024 else {
      throw QFAPIError(code: 41300, message: text("图片过大，请选择 8 MB 以内的图片。", "Choose an image smaller than 8 MB."))
    }
    let request = try makeRequest(path: path, method: "POST", body: nil, operationID: UUID())
    let response = await mediaTransport.upload(multipartFormData: { form in
      for (key, value) in fields { form.append(Data(value.utf8), withName: key) }
      form.append(fileData, withName: "image", fileName: filename, mimeType: mimeType)
    }, with: request).serializingData(automaticallyCancelling: true, emptyResponseCodes: Set(100...599)).response
    try Task.checkCancellation()
    if let error = response.error { throw Self.transportError(error) }
    guard let http = response.response else { throw URLError(.badServerResponse) }
    let data = response.data ?? Data()
    guard data.count <= 2 * 1024 * 1024,
      let envelope = try? JSONDecoder().decode(QFAPIEnvelope<Value>.self, from: data) else {
      throw QFAPIError(code: http.statusCode, message: text("助手响应无法解析，请稍后重试。", "The assistant response could not be read. Try again."), requestId: http.value(forHTTPHeaderField: "Request-Id"))
    }
    guard (200..<300).contains(http.statusCode), envelope.code == 0 else {
      throw QFAPIError(code: envelope.code, message: envelope.message, requestId: envelope.requestId)
    }
    guard let value = envelope.data else {
      throw QFAPIError(code: 50000, message: text("服务器返回的数据不完整。", "The server response is incomplete."), requestId: envelope.requestId)
    }
    return value
  }

  private func perform<Value: Decodable>(
    path: String, method: String, body: Data?,
    operationID: UUID?, query: [String: String] = [:]
  ) async throws -> QFAPIEnvelope<Value> {
    try Task.checkCancellation()
    let request = try makeRequest(path: path, method: method, body: body, operationID: operationID, query: query)
    #if DEBUG
      let logger = recordsRequests ? (requestLogStore ?? QFRequestLogStore.shared) : nil
      let logID = logger?.begin(request: request)
    #endif
    // No validation or retry interceptor: HTTP failures must retain the server's envelope.
    // Accept empty bodies here so the existing envelope decoder reports their HTTP status.
    let response = await transport.request(request)
      .serializingData(
        automaticallyCancelling: true, emptyResponseCodes: Set(100...599)
      )
      .response
    let failure: Error? =
      Task.isCancelled ? CancellationError() : response.error.map(Self.transportError)
    let http = response.response
    let data = response.data ?? Data()
    #if DEBUG
      if let logID {
        logger?.finish(id: logID, response: http, data: response.data, error: failure)
      }
    #endif
    if let failure { throw failure }
    guard let http, data.count <= 2 * 1024 * 1024 else {
      throw QFAPIError(
        code: 50000,
        message: text("服务器响应格式或大小异常。", "The server response has an invalid format or size."))
    }
    let envelope: QFAPIEnvelope<Value>
    do { envelope = try JSONDecoder().decode(QFAPIEnvelope<Value>.self, from: data) } catch {
      throw QFAPIError(
        code: http.statusCode,
        message: text("服务器响应无法解析，请稍后重试。", "The server response could not be read. Try again later."),
        requestId: http.value(forHTTPHeaderField: "Request-Id"))
    }
    guard (200..<300).contains(http.statusCode), envelope.code == 0 else {
      throw QFAPIError(
        code: envelope.code, message: envelope.message, requestId: envelope.requestId)
    }
    return envelope
  }

  private static func transportError(_ error: AFError) -> Error {
    switch error {
    case .explicitlyCancelled:
      return CancellationError()
    case .sessionTaskFailed(let underlying):
      if let urlError = underlying as? URLError, urlError.code == .cancelled {
        return CancellationError()
      }
      return underlying
    default:
      return error
    }
  }

  func makeRequest(path: String, method: String, body: Data?, operationID: UUID?, query: [String: String] = [:]) throws
    -> URLRequest
  {
    guard let baseURL = environment.baseURL, baseURL.scheme == "https",
      baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
      !path.contains(".."), !path.contains(":"), !path.contains("?")
    else {
      throw QFAPIError(
        code: 50300,
        message: text("当前环境的 HTTPS 接口地址尚未配置。", "The HTTPS API address is not configured for this environment."))
    }
    var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
    if !query.isEmpty { components?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
    guard let url = components?.url else {
      throw QFAPIError(code: 40000, message: text("请求地址无效。", "The request address is invalid."))
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    request.setValue(accessToken.map { "Bearer \($0)" } ?? "", forHTTPHeaderField: "Authorization")
    request.setValue("IOS", forHTTPHeaderField: "App-Platform")
    request.setValue(
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
      forHTTPHeaderField: "App-Version")
    request.setValue(
      QFContentLoadingContext.language ?? interfaceLanguage, forHTTPHeaderField: "Accept-Language")
    do {
      request.setValue(try identity.deviceID(), forHTTPHeaderField: "Device-Id")
    } catch is QFKeychainError {
      throw QFAPIError(
        code: 50000,
        message: text(
          "无法访问本机安全凭证，请解锁设备后重试。",
          "The secure credential on this device could not be accessed. Unlock the device and try again."))
    }
    if let operationID {
      request.setValue(operationID.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
    }
    return request
  }

  // Binary media is deliberately excluded from the Debug JSON request-body logger.
  func uploadMedia(_ data: Data, mimeType: String, filename: String) async throws -> QFContentMedia {
    try Task.checkCancellation()
    let request = try makeRequest(path: "media", method: "POST", body: nil, operationID: nil)
    let response = await mediaTransport.upload(multipartFormData: { form in
      form.append(data, withName: "file", fileName: filename, mimeType: mimeType)
    }, with: request).serializingData(automaticallyCancelling: true, emptyResponseCodes: Set(100...599)).response
    try Task.checkCancellation()
    if let error = response.error { throw Self.transportError(error) }
    guard let http = response.response else { throw URLError(.badServerResponse) }
    let bytes = response.data ?? Data()
    guard (200..<300).contains(http.statusCode) else { throw mediaError(http, data: bytes) }
    guard bytes.count <= 2 * 1024 * 1024,
      let value = try? JSONDecoder().decode(QFAPIEnvelope<QFContentMedia>.self, from: bytes) else {
      throw QFAPIError(
        code: 50000,
        message: text("上传结果无法解析，请重新选择图片或视频。", "The upload result could not be read. Choose the photo or video again."),
        requestId: http.value(forHTTPHeaderField: "Request-Id"))
    }
    guard value.code == 0, let media = value.data else {
      throw QFAPIError(code: value.code, message: value.message, requestId: value.requestId)
    }
    return media
  }

  func loadMedia(_ id: String) async throws -> Data {
    try Task.checkCancellation()
    guard UUID(uuidString: id) != nil else {
      throw QFAPIError(code: 40000, message: text("媒体标识无效。", "The media identifier is invalid."))
    }
    var request = try makeRequest(path: "media/\(id)", method: "GET", body: nil, operationID: nil)
    // Media endpoints return binary images or videos rather than the JSON API envelope.
    request.setValue("*/*", forHTTPHeaderField: "Accept")
    let response = await mediaTransport.request(request)
      .serializingData(automaticallyCancelling: true, emptyResponseCodes: Set(100...599)).response
    try Task.checkCancellation()
    if let error = response.error { throw Self.transportError(error) }
    guard let http = response.response else { throw URLError(.badServerResponse) }
    let data = response.data ?? Data()
    guard http.statusCode == 200 else { throw mediaError(http, data: data) }
    let mime = http.mimeType?.lowercased() ?? ""
    guard !data.isEmpty, data.count <= 20 * 1024 * 1024,
      mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime == "application/octet-stream" else {
      throw QFAPIError(
        code: 50000, message: text("图片或视频内容无效，请重试。", "The photo or video data is invalid. Try again."))
    }
    return data
  }

  private func mediaError(_ http: HTTPURLResponse, data: Data) -> QFAPIError {
    if data.count <= 2 * 1024 * 1024,
      let envelope = try? JSONDecoder().decode(QFAPIEnvelope<QFEmptyResponse>.self, from: data), envelope.code != 0 {
      return QFAPIError(code: envelope.code, message: envelope.message, requestId: envelope.requestId)
    }
    let message: String
    switch http.statusCode {
    case 401: message = text("登录状态已失效，请重新登录。", "Your session expired. Sign in again.")
    case 403, 404: message = text(
      "图片或视频已移除，或你没有查看权限。", "This photo or video was removed, or you do not have permission to view it.")
    case 413: message = text(
      "文件过大，图片最多8MB，视频最多20MB。", "The file is too large. Photos can be up to 8 MB and videos up to 20 MB.")
    case 406: message = text(
      "图片或视频格式暂不支持，请重试。", "This photo or video format is not supported. Try another file.")
    default: message = text(
      "图片或视频服务暂时不可用，请重试。", "The photo and video service is temporarily unavailable. Try again.")
    }
    return QFAPIError(code: http.statusCode, message: message,
      requestId: http.value(forHTTPHeaderField: "Request-Id"))
  }
}
