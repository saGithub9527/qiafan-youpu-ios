#!/usr/bin/env python3
"""Bounded host behavior check: real Agent/Knowledge, no model or network.

The first executable tests the real local Agent.answer. The second is built only
after that passes, and requires productHelp's context-bearing API. Normal iOS
compilation verifies all UI call sites pass its required arguments; this check
does not copy or extract UIKit implementation fragments.
"""
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    weekly_reference = "--weekly-reference-only" in sys.argv
    # Compile shipping Foundation DTOs as well. Weekly routing is part of the
    # Agent file even when these cases exercise only knowledge/conversation.
    planning = (root / "QiafanYoupu/Core/Networking/QFPlanningAPI.swift").read_text()
    weekly_models = planning[planning.index("struct QFWeeklyPlanProposalDraft:"):
                             planning.index("private struct QFWeeklyPlanAcceptDraft:")]
    streaming = (root / "QiafanYoupu/Core/Networking/QFAssistantStream.swift").read_text()
    stream_models = streaming[streaming.index("struct QFAssistantStreamResult:"):
                              streaming.index("/// Only transport-confirmed")]
    sources = [
        "QiafanYoupu/Features/Assistant/QFAssistantAgentContract.swift",
        "QiafanYoupu/Features/Assistant/QFAssistantCapabilityPolicy.swift",
        "QiafanYoupu/Features/Assistant/QFAssistantKnowledge.swift",
        "QiafanYoupu/Features/Assistant/QFAssistantReadRenderer.swift",
        "QiafanYoupu/Features/Assistant/QFAssistantAgent.swift",
        "scripts/tests/assistant_weekly_reference_check.swift" if weekly_reference else "scripts/tests/assistant_editorial_context_check.swift",
    ]
    with tempfile.TemporaryDirectory(prefix="editorial-context-", dir=root / ".build") as folder:
        tmp = Path(folder)
        stubs = tmp / "Boundaries.swift"
        stubs.write_text(r'''import Foundation

enum UnexpectedBoundary: Error { case network, business }
struct QFAPIError: Error { let code: Int; let message: String }

@MainActor final class QFAppSession {
  var interfaceLanguage = "zh-Hans"
  var contentScope = "isolated-host-fixture"
  var planningHouseholdID: String? = nil
  var networkCalls = 0
  var networkAllowed = false
  var weeklyFailure: Error = UnexpectedBoundary.network
  var lookupResponse: Data?
  var lookupBodies: [Data] = []
  var proposalCalls = 0
  var scopeAfterLookup: String?
  var scopeAfterStream: String?
  var streamResponse: QFAssistantStreamResult?
  var streamRequests: [(text: String, history: [QFOnDeviceInference.Turn], allowWeb: Bool)] = []
  func text(_ chinese: String, _ english: String) -> String { chinese }
  func format(_ chinese: String, _ english: String, _ arguments: CVarArg...) -> String {
    String(format: chinese, arguments: arguments)
  }
  func contentRequest<T: Decodable>(path: String, method: String, body: Data) async throws -> T {
    networkCalls += 1
    precondition(path == "me/assistant/knowledge/search" && method == "POST")
    lookupBodies.append(body)
    if let scopeAfterLookup { contentScope = scopeAfterLookup }
    if let lookupResponse { return try JSONDecoder().decode(T.self, from: lookupResponse) }
    throw UnexpectedBoundary.network
  }
  func createWeeklyPlanProposal(_ draft: QFWeeklyPlanProposalDraft) async throws -> QFWeeklyPlanProposal {
    networkCalls += 1
    proposalCalls += 1
    throw weeklyFailure
  }
  func assistantStream(text: String, history: [QFOnDeviceInference.Turn], imageData: Data?, mimeType: String,
    allowWebSearch: Bool = true, onEvent: @escaping (QFAssistantStreamEvent) -> Void) async throws -> QFAssistantStreamResult {
    streamRequests.append((text, history, allowWebSearch))
    if let scopeAfterStream { contentScope = scopeAfterStream }
    guard let streamResponse else { throw UnexpectedBoundary.network }
    onEvent(.status("generating"))
    return streamResponse
  }
}

@MainActor enum QFLocalModelViewController {
  static func networkEnabled(_ app: QFAppSession) -> Bool { app.networkAllowed }
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
''' + weekly_models + stream_models)
        fixture = root / "QiafanYoupu/Resources/AI/assistant-knowledge.json"
        phases = [("weekly-reference", [])] if weekly_reference else [
            ("local", []),
            ("helper", ["-D", "QF_EDITORIAL_CONTEXT_API"]),
        ]
        for phase, flags in phases:
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
