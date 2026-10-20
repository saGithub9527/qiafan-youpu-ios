#!/usr/bin/env python3
"""Compile the production stream finish gate in a tiny Foundation-only host.

No HTTP, app, model, service, simulator or package resolution is used. The test
replaces only surrounding continuation/cancellation handles and unrelated DTOs.
The terminal classifier, finish gate and error markers come from production Swift.
Run this check only after the project-wide heavy-work slot is available.
"""
from pathlib import Path
import subprocess
import tempfile


PROJECT = Path(__file__).resolve().parents[2]
STREAM = PROJECT / "QiafanYoupu/Core/Networking/QFAssistantStream.swift"
SESSION = PROJECT / "QiafanYoupu/Core/Session/QFAppSession.swift"


def balanced_block(source: str, declaration: str) -> str:
    start = source.index(declaration)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(f"Unbalanced production block: {declaration}")


def main() -> None:
    stream = STREAM.read_text()
    session = SESSION.read_text()
    marker = balanced_block(stream, "struct QFAssistantStreamHTTPUnauthorized: Error")
    exhausted_marker = balanced_block(stream, "struct QFAssistantStreamTransportExhausted: Error")
    transport_failure = balanced_block(stream, "private func terminalTransportFailure(_ failure: QFAPIError, status: Int) -> Error")
    finish = balanced_block(stream, "private func finish(_ result: Result<QFAssistantStreamResult, Error>)")

    # Ensure the tested gate is wired before interpretation of every SSE event,
    # and only its marker can enter the one-refresh branch in the real session.
    loop = balanced_block(stream, "for event in try decoder.append(data)")
    assert loop.index("receivedSSEEvent = true") < loop.index("try receive(event)")
    assert loop.index("receivedSSEEvent = true") < loop.index("if (200..<300).contains(response.statusCode)")
    method = balanced_block(session, "func assistantStream(text:")
    assert method.count("catch is QFAssistantStreamHTTPUnauthorized") == 1
    assert method.count("catch let rejection as QFAssistantStreamHTTPUnauthorized") == 1
    assert "throw rejection.failure" in method
    assert "catch let error as QFAPIError" not in method
    assert "while " not in method and "repeat {" not in method

    host = r'''
import Foundation

struct QFAPIError: Error { let code: Int; let message: String }
struct QFAssistantStreamResult { let answer: String }
final class CancelHandle { var calls = 0; func cancel() { calls += 1 } }
final class TransportHandle {
  var requests: [URLRequest] = []
  func request(_ request: URLRequest) -> TransportHandle { requests.append(request); return self }
  func response(_ callback: (Bool) -> Void) { callback(true) }
}
final class ContinuationHandle {
  var calls = 0
  var result: Result<QFAssistantStreamResult, Error>?
  func resume(with value: Result<QFAssistantStreamResult, Error>) { calls += 1; result = value }
}
''' + marker + "\n" + exhausted_marker + r'''

final class Host {
  var completed = false
  var receivedSSEEvent: Bool
  var httpResponse: HTTPURLResponse?
  var continuation: ContinuationHandle?
  var request: CancelHandle?
  var timeout: CancelHandle?
  var reconnectTask: CancelHandle?
  var resumeAttempts = 0
  var resumeSupported = false
  var originalRequest: URLRequest?
  var transport: TransportHandle?
  init(status: Int?, event: Bool, continuation: ContinuationHandle, request: CancelHandle, timeout: CancelHandle) {
    if let status {
      httpResponse = HTTPURLResponse(url: URL(string: "https://fixture.invalid/")!, statusCode: status,
        httpVersion: "HTTP/1.1", headerFields: nil)
    }
    receivedSSEEvent = event; self.continuation = continuation
    self.request = request; self.timeout = timeout
  }
  func deliver(_ value: Result<QFAssistantStreamResult, Error>) { finish(value) }
  func endTransport(_ failure: QFAPIError, status: Int) { finish(.failure(terminalTransportFailure(failure, status: status))) }
''' + transport_failure + "\n" + finish + r'''
}

@main enum ReplayCheck {
  static func main() {
    var count = 0
    func verify(_ label: String, status: Int?, event: Bool, refresh: Bool,
      failure: Error = QFAPIError(code: 40100, message: "fixture"), resumes: Int = 0) {
      let capture = ContinuationHandle(), request = CancelHandle(), timer = CancelHandle()
      let host = Host(status: status, event: event, continuation: capture, request: request, timeout: timer)
      host.resumeAttempts = resumes
      host.deliver(.failure(failure))
      guard case .failure(let delivered)? = capture.result else { fatalError("Missing failure: \(label)") }
      precondition((delivered is QFAssistantStreamHTTPUnauthorized) == refresh, label)
      precondition(capture.calls == 1 && host.completed && host.continuation == nil, "One terminal receipt: \(label)")
      precondition(request.calls == 1 && timer.calls == 1, "Owned handles cancelled: \(label)")
      host.deliver(.failure(QFAPIError(code: 40100, message: "late completion")))
      precondition(capture.calls == 1 && request.calls == 1 && timer.calls == 1, "No repeated terminal receipt: \(label)")
      count += 1
    }
    verify("pre-stream HTTP401", status: 401, event: false, refresh: true)
    verify("resume401 cannot restart a producer", status: 401, event: false, refresh: false, resumes: 1)
    verify("HTTP status governs, not body code", status: 401, event: false, refresh: true,
      failure: QFAPIError(code: 50300, message: "body cannot select the authentication gate"))
    for status in [200, 201, 302, 403, 429, 503] {
      verify("JSON401 on HTTP\(status)", status: status, event: false, refresh: false)
    }
    verify("no trusted HTTP response", status: nil, event: false, refresh: false)
    for event in ["status", "delta", "reasoning", "error", "done", "future-event"] {
      verify("HTTP401 after SSE \(event)", status: 401, event: true, refresh: false)
    }
    verify("HTTP200 SSEerror401", status: 200, event: true, refresh: false)
    verify("timeout is not an authentication rejection", status: 401, event: false, refresh: false,
      failure: URLError(.timedOut))
    verify("cancellation cannot trigger refresh", status: 401, event: false, refresh: false,
      failure: CancellationError())
    verify("local exhaustion never grants authentication replay", status: 401, event: false, refresh: false,
      failure: QFAssistantStreamTransportExhausted(failure: QFAPIError(code: 40100, message: "local boundary fixture")))
    let capture = ContinuationHandle(), request = CancelHandle(), timer = CancelHandle()
    let success = Host(status: 200, event: true, continuation: capture, request: request, timeout: timer)
    success.deliver(.success(.init(answer: "complete")))
    success.deliver(.failure(QFAPIError(code: 40100, message: "late error")))
    guard case .success(let answer)? = capture.result else { fatalError("Successful done was replaced") }
    precondition(answer.answer == "complete" && capture.calls == 1 && request.calls == 1 && timer.calls == 1)
    // Invalid framing or JSON is a client abandonment of an accepted task.
    func verifyProducerStop(_ label: String, status: Int?, error: Error, expected: Bool,
      resumes: Int = 0, event: Bool? = nil, forwardedFailure: QFAPIError? = nil,
      terminalTransportStatus: Int? = nil, supported: Bool = false, expectedRefresh: Bool? = nil) {
      let capture = ContinuationHandle(), request = CancelHandle(), timer = CancelHandle()
      let host = Host(status: status, event: event ?? (status == 200), continuation: capture, request: request, timeout: timer)
      host.resumeAttempts = resumes
      host.resumeSupported = supported
      let transport = TransportHandle()
      var initial = URLRequest(url: URL(string: "https://fixture.invalid/chat/stream")!)
      initial.httpMethod = "POST"; initial.httpBody = Data("frozen-request".utf8)
      initial.setValue("00000000-0000-4000-8000-000000000007", forHTTPHeaderField: "Idempotency-Key")
      initial.setValue("application/json", forHTTPHeaderField: "Content-Type")
      host.originalRequest = initial; host.transport = transport
      if let status = terminalTransportStatus, let failure = error as? QFAPIError {
        host.endTransport(failure, status: status)
      } else { host.deliver(.failure(error)) }
      host.deliver(.failure(error))
      precondition(transport.requests.count == (expected ? 1 : 0), label)
      if let stop = transport.requests.first {
        precondition(stop.httpMethod == "DELETE" && stop.httpBody == nil, "No second POST: " + label)
        precondition(stop.url == initial.url && stop.value(forHTTPHeaderField: "Idempotency-Key") == initial.value(forHTTPHeaderField: "Idempotency-Key"), "Same operation: " + label)
      }
      if let expectedFailure = forwardedFailure {
        guard case .failure(let delivered)? = capture.result, let failure = delivered as? QFAPIError else {
          fatalError("Preserve the public transport failure without granting an auth replay: " + label)
        }
        precondition(failure.code == expectedFailure.code && failure.message == expectedFailure.message,
          "Preserve the original public failure: " + label)
      }
      if let expectedRefresh {
        guard case .failure(let delivered)? = capture.result else { fatalError("Missing failure: " + label) }
        precondition((delivered is QFAssistantStreamHTTPUnauthorized) == expectedRefresh, "Authentication boundary: " + label)
      }
      precondition(capture.calls == 1 && request.calls == 1, "One terminal receipt: " + label)
      count += 1
    }
    for code in [URLError.Code.cannotParseResponse, .dataLengthExceedsMaximum] {
      verifyProducerStop("accepted invalid stream: \(code)", status: 200, error: URLError(code), expected: true)
      verifyProducerStop("pre-acceptance denial: \(code)", status: 400, error: URLError(code), expected: false)
    }
    verifyProducerStop("accepted invalid JSON", status: 200,
      error: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "public synthetic malformed event")), expected: true)
    verifyProducerStop("authoritative server terminal error", status: 200,
      error: QFAPIError(code: 50300, message: "terminal server event"), expected: false)
    verifyProducerStop("explicit stop before headers", status: nil, error: CancellationError(), expected: true)
    verifyProducerStop("deadline before headers", status: nil, error: URLError(.timedOut), expected: true)
    for (status, code) in [(400, 40000), (403, 40300), (429, 42900)] {
      let failure = QFAPIError(code: code, message: "authoritative HTTP rejection")
      verifyProducerStop("HTTP\(status) remains authoritative after attempted recovery", status: status,
        error: failure, expected: false, resumes: 2, forwardedFailure: failure)
    }
    // An earlier accepted producer can survive a later 503 or a lost response.
    // Exhaustion is explicitly local; a bare server error above is never recast.
    let exhaustedStatuses: [Int?] = [200, 503, nil]
    for status in exhaustedStatuses {
      let failure = QFAPIError(code: 50300, message: "recovery exhausted; received content kept")
      verifyProducerStop("local recovery exhausted after accepted events; last HTTP \(String(describing: status))",
        status: status, error: QFAssistantStreamTransportExhausted(failure: failure), expected: true,
        resumes: 2, event: true, forwardedFailure: failure)
    }
    for status in [0, 200, 502, 503, 504] {
      let failure = QFAPIError(code: 50300, message: "local transport permanently abandoned")
      verifyProducerStop("unsupported recovery must stop, status \(status)", status: status == 0 ? nil : status,
        error: failure, expected: true, resumes: 0, event: status == 200, forwardedFailure: failure,
        terminalTransportStatus: status, supported: false)
      verifyProducerStop("exhausted recovery must stop, status \(status)", status: status == 0 ? nil : status,
        error: failure, expected: true, resumes: 2, event: true, forwardedFailure: failure,
        terminalTransportStatus: status, supported: true)
    }
    for (status, code) in [(400, 40000), (403, 40300), (429, 42900)] {
      let failure = QFAPIError(code: code, message: "authoritative HTTP rejection")
      verifyProducerStop("terminal classifier preserves HTTP\(status)", status: status,
        error: failure, expected: false, forwardedFailure: failure, terminalTransportStatus: status)
    }
    verifyProducerStop("terminal classifier preserves initial HTTP401 refresh", status: 401,
      error: QFAPIError(code: 40100, message: "authoritative HTTP401"), expected: false,
      terminalTransportStatus: 401, expectedRefresh: true)
    print("PASS production finish gate: \(count) failure cases + success; exactly-once cancellation/receipt; production SSE/session bindings")
  }
}
'''
    build = PROJECT / ".build"
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="assistant-stream-replay-", dir=build) as temporary:
        work = Path(temporary)
        source = work / "ReplayCheck.swift"
        binary = work / "replay-check"
        source.write_text(host)
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(work / "modules"),
                        str(source), "-o", str(binary)], check=True, timeout=45)
        subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == "__main__":
    main()
