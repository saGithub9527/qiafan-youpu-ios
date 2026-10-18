#!/usr/bin/env python3
"""Bounded host behavior check: real Agent/Knowledge, no model or network.

The first executable tests the real local Agent.answer. The second is built only
after that passes, and requires productHelp's context-bearing API. Normal iOS
compilation verifies all UI call sites pass its required arguments; this check
does not copy or extract UIKit implementation fragments.
"""
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    sources = [
        "QiafanYoupu/Features/Assistant/QFAssistantAgentContract.swift",
        "QiafanYoupu/Features/Assistant/QFAssistantCapabilityPolicy.swift",
        "QiafanYoupu/Features/Assistant/QFAssistantKnowledge.swift",
        "QiafanYoupu/Features/Assistant/QFAssistantReadRenderer.swift",
        "QiafanYoupu/Features/Assistant/QFAssistantAgent.swift",
        "scripts/tests/assistant_editorial_context_check.swift",
    ]
    with tempfile.TemporaryDirectory(prefix="editorial-context-", dir=root / ".build") as folder:
        tmp = Path(folder)
        stubs = tmp / "Boundaries.swift"
        stubs.write_text(r'''import Foundation

enum UnexpectedBoundary: Error { case network, business }

@MainActor final class QFAppSession {
  var interfaceLanguage = "zh-Hans"
  var contentScope = "isolated-host-fixture"
  var planningHouseholdID: String? = nil
  var networkCalls = 0
  func text(_ chinese: String, _ english: String) -> String { chinese }
  func format(_ chinese: String, _ english: String, _ arguments: CVarArg...) -> String {
    String(format: chinese, arguments: arguments)
  }
  func contentRequest<T: Decodable>(path: String, method: String, body: Data) async throws -> T {
    networkCalls += 1
    throw UnexpectedBoundary.network
  }
}

@MainActor enum QFLocalModelViewController {
  static func networkEnabled(_ app: QFAppSession) -> Bool { false }
}

@MainActor final class QFLocalModelStore {
  static let shared = QFLocalModelStore()
  let modelURL = URL(fileURLWithPath: "/never-opened-host-fixture.gguf")
}

enum QFContentDate {
  static func day(_ date: Date) -> String { "2026-10-18" }
}

@MainActor enum QFAssistantBusinessTools {
  static var calls = 0
  static func execute(_ call: QFAgentToolCall, app: QFAppSession) async throws -> QFAgentToolResult {
    calls += 1
    throw UnexpectedBoundary.business
  }
}

// The costly model boundary alone is replaced. Tests inspect the actual Agent's
// forwarded constraints/evidence, not semantic quality of this sentinel reply.
@MainActor enum QFOnDeviceInference {
  enum Failure: Error { case contextTooLong }
  struct Turn: Codable, Sendable { let role: String; let content: String }
  struct Capture { let turns: [Turn]; let system: String?; let grammar: String? }
  static var calls: [Capture] = []
  static func answer(model: URL, turns: [Turn], language: String,
    systemPrompt: String? = nil, contextTokens: Int32 = 1024, maxOutputTokens: Int32 = 192,
    outputGrammar: String? = nil, sessionScope: String? = nil, microBatchTokens: Int32 = 128,
    opOffload: Bool = true, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> String {
    calls.append(.init(turns: turns, system: systemPrompt, grammar: outputGrammar))
    return "HOST_MODEL_BOUNDARY_REACHED"
  }
}
''')
        fixture = root / "QiafanYoupu/Resources/AI/assistant-knowledge.json"
        for phase, flags in [
            ("local", []),
            ("helper", ["-D", "QF_EDITORIAL_CONTEXT_API"]),
        ]:
            binary = tmp / (phase + "-check")
            subprocess.run(
                ["xcrun", "swiftc", "-j", "1", "-parse-as-library",
                 "-module-cache-path", str(tmp / "modules"), *flags,
                 *[str(root / path) for path in sources], str(stubs), "-o", str(binary)],
                check=True, timeout=60,
            )
            result = subprocess.run([str(binary), str(fixture)], timeout=15)
            if result.returncode:
                raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
