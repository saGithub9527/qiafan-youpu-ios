#!/usr/bin/env python3
"""Compile the production stream finish gate in a tiny Foundation-only host.

No HTTP, app, model, service, simulator or package resolution is used. The test
replaces only surrounding continuation/cancellation handles and unrelated DTOs.
The gate function and its HTTP-only marker are extracted from production Swift.
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
  func request(_ request: URLRequest) -> TransportHandle { self }
  func response(_ callback: (Bool) -> Void) { callback(true) }
}
final class ContinuationHandle {
  var calls = 0
  var result: Result<QFAssistantStreamResult, Error>?
  func resume(with value: Result<QFAssistantStreamResult, Error>) { calls += 1; result = value }
}
''' + marker + r'''

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
''' + finish + r'''
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
    let capture = ContinuationHandle(), request = CancelHandle(), timer = CancelHandle()
    let success = Host(status: 200, event: true, continuation: capture, request: request, timeout: timer)
    success.deliver(.success(.init(answer: "complete")))
    success.deliver(.failure(QFAPIError(code: 40100, message: "late error")))
    guard case .success(let answer)? = capture.result else { fatalError("Successful done was replaced") }
    precondition(answer.answer == "complete" && capture.calls == 1 && request.calls == 1 && timer.calls == 1)
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
