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
  var accessToken: String?
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
  }

  static func makeTransport(configuration source: URLSessionConfiguration) -> Alamofire.Session {
    let configuration = source.copy() as? URLSessionConfiguration ?? .ephemeral
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 30
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
    operationID: UUID? = nil
  ) async throws -> Value {
    let envelope: QFAPIEnvelope<Value> = try await perform(
      path: path, method: method, body: body, operationID: operationID)
    guard let result = envelope.data else {
      throw QFAPIError(code: 50000, message: "服务器返回的数据不完整。", requestId: envelope.requestId)
    }
    return result
  }

  func sendEmpty(path: String, method: String) async throws {
    let _: QFAPIEnvelope<QFEmptyResponse> = try await perform(
      path: path, method: method, body: nil, operationID: nil)
  }

  private func perform<Value: Decodable>(
    path: String, method: String, body: Data?,
    operationID: UUID?
  ) async throws -> QFAPIEnvelope<Value> {
    try Task.checkCancellation()
    let request = try makeRequest(path: path, method: method, body: body, operationID: operationID)
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
      throw QFAPIError(code: 50000, message: "服务器响应格式或大小异常。")
    }
    let envelope: QFAPIEnvelope<Value>
    do { envelope = try JSONDecoder().decode(QFAPIEnvelope<Value>.self, from: data) } catch {
      throw QFAPIError(
        code: http.statusCode, message: "服务器响应无法解析，请稍后重试。",
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

  func makeRequest(path: String, method: String, body: Data?, operationID: UUID?) throws
    -> URLRequest
  {
    guard let baseURL = environment.baseURL, baseURL.scheme == "https",
      baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
      !path.contains(".."), !path.contains(":"), !path.contains("?")
    else { throw QFAPIError(code: 50300, message: "当前环境的 HTTPS 接口地址尚未配置。") }
    let url = baseURL.appendingPathComponent(path)
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
      Locale.preferredLanguages.first ?? "zh-CN", forHTTPHeaderField: "Accept-Language")
    request.setValue(try identity.deviceID(), forHTTPHeaderField: "Device-Id")
    if let operationID {
      request.setValue(operationID.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
    }
    return request
  }
}
