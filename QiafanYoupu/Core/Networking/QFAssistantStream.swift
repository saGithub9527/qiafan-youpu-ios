import Foundation
import Alamofire
import QFSSE

/// Capture once per operation so reconnects keep the original family and timezone.
struct QFAssistantChatRequest: Encodable {
  let text: String
  let allowCloud: Bool
  var allowWeb: Bool? = nil
  let history: [QFOnDeviceInference.Turn]
  let householdId: String?
  let timeZone: String

  func encoded(imageData: Data?, mimeType: String) throws -> (body: Data, contentType: String) {
    guard let imageData else { return (try JSONEncoder().encode(self), "application/json") }
    guard imageData.count <= 8 * 1024 * 1024, ["image/jpeg", "image/png"].contains(mimeType) else {
      throw URLError(.dataLengthExceedsMaximum)
    }
    let form = MultipartFormData()
    form.append(Data(text.utf8), withName: "text")
    form.append(Data(String(allowCloud).utf8), withName: "allowCloud")
    if let allowWeb { form.append(Data(String(allowWeb).utf8), withName: "allowWeb") }
    form.append(try JSONEncoder().encode(history), withName: "history")
    if let householdId { form.append(Data(householdId.utf8), withName: "householdId") }
    form.append(Data(timeZone.utf8), withName: "timeZone")
    form.append(imageData, withName: "image", fileName: mimeType == "image/png" ? "image.png" : "image.jpg", mimeType: mimeType)
    return (try form.encode(), form.contentType)
  }
}

struct QFAssistantStreamResult: Decodable {
  let answer: String
  let model: String?
  let sources: [QFAgentSource]?
  let actions: [QFAgentAction]?
  let notice: String?
}

enum QFAssistantStreamEvent {
  case status(String)
  case delta(String)
  case reasoning(String)
}

/// Only transport-confirmed HTTP 401 before any SSE event permits one session refresh.
/// A model/server error payload with code 40100 never grants replay authority by itself.
struct QFAssistantStreamHTTPUnauthorized: Error {
  let failure: QFAPIError
}

/// One producer. Reconnects only to an advertised same-job replay protocol.
@MainActor
final class QFAssistantStreamRun {
  private var continuation: CheckedContinuation<QFAssistantStreamResult, Error>?
  private var request: DataStreamRequest?
  private var timeout: Task<Void, Never>?
  private var decoder = QFSSEDecoder()
  private var transport: Alamofire.Session?
  private var originalRequest: URLRequest?
  private var connectionID = UUID()
  private var resumeSupported = false
  private var resumeAttempts = 0
  private var reconnectTask: Task<Void, Never>?
  private var completed = false
  private var lastID = 0
  private var httpResponse: HTTPURLResponse?
  private var receivedSSEEvent = false
  private var errorBody = Data()
  private let appLanguage: QFInterfaceLanguage
  private let onEvent: (QFAssistantStreamEvent) throws -> Void
  init(language: String, onEvent: @escaping (QFAssistantStreamEvent) throws -> Void) {
    appLanguage = QFInterfaceLanguage.normalized(language); self.onEvent = onEvent
  }
  private func text(_ chinese: String, _ english: String) -> String { appLanguage.text(chinese: chinese, english: english) }
  func start(transport: Alamofire.Session, request: URLRequest) async throws -> QFAssistantStreamResult {
    try await withTaskCancellationHandler(operation: {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        self.transport = transport; originalRequest = request
        connect(request)
        timeout = Task { [weak self] in
          do { try await Task.sleep(nanoseconds: 240_000_000_000) } catch { return }
          self?.finish(.failure(URLError(.timedOut)))
        }
      }
    }, onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } })
  }
  private func connect(_ input: URLRequest) {
    guard !completed, let transport else { return }
    let connection = UUID(); connectionID = connection
    httpResponse = nil; errorBody = Data(); decoder = QFSSEDecoder()
    request = transport.streamRequest(input)
      .onHTTPResponse(on: .main) { [self] response in
        MainActor.assumeIsolated {
          guard connectionID == connection, !completed else { return }
          httpResponse = response
          resumeSupported = resumeSupported || response.value(forHTTPHeaderField: "X-QF-Stream-Resume") == "1"
        }
      }
      .responseStream(on: .main) { [self] stream in
        MainActor.assumeIsolated {
          guard connectionID == connection, !completed else { return }
          switch stream.event {
          case .stream(let result):
            if case .success(let data) = result {
              do {
                if let response = httpResponse, response.mimeType == "text/event-stream" {
                  for event in try decoder.append(data) {
                    receivedSSEEvent = true
                    if (200..<300).contains(response.statusCode) { try receive(event) }
                  }
                } else {
                  guard errorBody.count + data.count <= 65_536 else { throw URLError(.dataLengthExceedsMaximum) }
                  errorBody.append(data)
                }
              } catch { finish(.failure(error)) }
            }
          case .complete(let completion):
            httpResponse = completion.response ?? httpResponse
            let status = httpResponse?.statusCode ?? 0
            struct Failure: Decodable { let code: Int; let message: String }
            if let failure = try? JSONDecoder().decode(Failure.self, from: errorBody) {
              finish(.failure(QFAPIError(code: failure.code, message: failure.message)))
            } else if let delay = QFAssistantStreamRecovery.delay(attempt: resumeAttempts, supported: resumeSupported, status: status) {
              resume(after: delay)
            } else {
              let code = status == 401 ? 40100 : status == 0 || status == 200 ? 50300 : status
              let message = status == 404
                ? text("当前服务器尚未提供流式问答，请更新服务端后重试。", "Streaming chat is not available on this server. Update the server and retry.")
                : text("连接中断，已保留收到的内容。请手动重试。", "The connection ended. Received content was kept. Retry manually.")
              finish(.failure(QFAPIError(code: code, message: message)))
            }
          }
        }
      }
  }

  private func resume(after delay: UInt64) {
    guard var input = originalRequest else { return }
    resumeAttempts += 1
    input.setValue("1", forHTTPHeaderField: "X-QF-Stream-Resume")
    input.setValue(String(lastID), forHTTPHeaderField: "Last-Event-ID")
    connectionID = UUID(); request?.cancel(); request = nil
    reconnectTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: delay) } catch { return }
      guard let self, !self.completed else { return }
      self.connect(input)
    }
  }
  private func receive(_ event: QFSSEEvent) throws {
    guard !completed else { return }
    if !event.id.isEmpty {
      guard let id = Int(event.id), id > 0 else { throw URLError(.cannotParseResponse) }
      if id <= lastID { return } // replay of an already displayed event
      guard id == lastID + 1 else { throw URLError(.cannotParseResponse) }
      lastID = id
    }
    let data = Data(event.data.utf8)
    struct Text: Decodable { let text: String }
    switch event.name {
    case "status":
      struct Status: Decodable { let stage: String }
      try onEvent(.status(JSONDecoder().decode(Status.self, from: data).stage))
    case "delta": try onEvent(.delta(JSONDecoder().decode(Text.self, from: data).text))
    case "reasoning": try onEvent(.reasoning(JSONDecoder().decode(Text.self, from: data).text))
    case "done":
      let result = try JSONDecoder().decode(QFAssistantStreamResult.self, from: data)
      guard !result.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw URLError(.cannotParseResponse) }
      finish(.success(result))
    case "error":
      struct Failure: Decodable { let code: Int; let message: String }
      let value = try JSONDecoder().decode(Failure.self, from: data)
      throw QFAPIError(code: value.code, message: value.message)
    default: break // forward-compatible optional events; never an implicit completion
    }
  }
  private func finish(_ result: Result<QFAssistantStreamResult, Error>) {
    guard !completed else { return }
    let delivered: Result<QFAssistantStreamResult, Error>
    if case .failure(let error) = result, let failure = error as? QFAPIError,
      httpResponse?.statusCode == 401, !receivedSSEEvent, resumeAttempts == 0 {
      delivered = .failure(QFAssistantStreamHTTPUnauthorized(failure: failure))
    } else { delivered = result }
    completed = true; timeout?.cancel(); timeout = nil
    reconnectTask?.cancel(); reconnectTask = nil
    // Explicit stop must reach the original operation even before response headers arrive.
    // Only resubscribing to generation is gated by the server's replay advertisement.
    if case .failure(let error) = result, (error is CancellationError || (error as? URLError)?.code == .timedOut),
      var stop = originalRequest, let operation = stop.value(forHTTPHeaderField: "Idempotency-Key"),
      !operation.isEmpty, let transport {
      stop.httpMethod = "DELETE"; stop.httpBody = nil
      stop.setValue("application/json", forHTTPHeaderField: "Accept")
      stop.setValue(nil, forHTTPHeaderField: "Content-Type")
      transport.request(stop).response { _ in }
    }
    request?.cancel(); request = nil
    let saved = continuation; continuation = nil; saved?.resume(with: delivered)
  }
}
