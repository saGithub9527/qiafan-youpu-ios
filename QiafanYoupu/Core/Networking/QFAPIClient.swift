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
  private let transport: URLSession
  var accessToken: String?
  #if DEBUG
    var recordsRequests = true
  #endif

  init(
    environment: QFAPIEnvironment = .current, identity: QFDeviceIdentity? = nil,
    transport: URLSession? = nil
  ) {
    self.environment = environment
    self.identity = identity ?? QFDeviceIdentity()
    if let transport {
      self.transport = transport
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 20
      configuration.timeoutIntervalForResource = 30
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.urlCache = nil
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      self.transport = URLSession(
        configuration: configuration, delegate: QFNoRedirectDelegate(), delegateQueue: nil)
    }
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
    let request = try makeRequest(path: path, method: method, body: body, operationID: operationID)
    #if DEBUG
      let logID = recordsRequests ? QFRequestLogStore.shared.begin(request: request) : nil
    #endif
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport.data(for: request)
    } catch {
      #if DEBUG
        if let logID {
          QFRequestLogStore.shared.finish(id: logID, response: nil, data: nil, error: error)
        }
      #endif
      throw error
    }
    let http = response as? HTTPURLResponse
    #if DEBUG
      if let logID {
        QFRequestLogStore.shared.finish(id: logID, response: http, data: data, error: nil)
      }
    #endif
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

private final class QFNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // Never forward device credentials, authorization codes or tokens to a redirected endpoint.
    completionHandler(nil)
  }
}
