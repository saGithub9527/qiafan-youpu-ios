import Foundation
import Darwin

/// Exercises actual Agent decisions with public synthetic context only.
/// No UI source extraction, real model, network, preferences or chat persistence.
@main @MainActor
enum EditorialContextCheck {
  private static var checks = 0
  private static var failures: [String] = []

  private static func expect(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { failures.append(name); print("FAIL \(name)") }
  }

  static func main() async throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    try await QFAssistantKnowledge.shared.load(data: data, language: "zh-Hans")
    // The bundled corpus is the reference input, independently of index output.
    let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let documents = root["documents"] as! [[String: Any]]
    let document = documents.first { $0["id"] as? String == "food-leftovers" }!
    let body = (document["languages"] as! [String: [String: String]])["zh-Hans"]!["body"]!
    let sourceID = "knowledge:food-leftovers"
    let question = "剩菜怎么保存？"
    let earlier: [QFOnDeviceInference.Turn] = [
      .init(role: "user", content: "这是公开合成测试：我对花生过敏，本段对话不要丢掉这个限制。"),
      .init(role: "assistant", content: "本段对话会保留这个限制。"),
    ]
    let reference = QFAgentSource(id: "recipe:00000000-0000-4000-8000-000000000001",
      title: "Synthetic earlier recipe", url: nil, revision: nil)
    let app = QFAppSession()

    @MainActor func reset() {
      QFOnDeviceInference.calls = []
      QFAssistantBusinessTools.calls = 0
      app.networkCalls = 0
    }

#if QF_EDITORIAL_CONTEXT_API
    // This phase intentionally requires every context argument. The production
    // iOS build must also update local/cloud/UI/debug callers; defaults could
    // otherwise turn an omitted context into an apparently standalone FAQ.
    let helperCases: [(String, [QFOnDeviceInference.Turn], [QFAgentSource], Bool)] = [
      ("history", earlier, [QFAgentSource](), false),
      ("reference", [QFOnDeviceInference.Turn](), [reference], false),
      ("image", [QFOnDeviceInference.Turn](), [QFAgentSource](), true),
      ("combined", earlier, [reference], true),
    ]
    for (name, history, known, hasImage) in helperCases {
      reset()
      let help = try await QFAssistantAgent.productHelp(text: question, history: history,
        knownSources: known, hasImage: hasImage, app: app)
      expect(help == nil, "helper-\(name)-must-not-return-reviewed-FAQ")
      expect(QFOnDeviceInference.calls.isEmpty && app.networkCalls == 0
        && QFAssistantBusinessTools.calls == 0, "helper-\(name)-has-no-side-effects")
    }
    reset()
    let direct = try await QFAssistantAgent.productHelp(text: question, history: [],
      knownSources: [], hasImage: false, app: app)
    expect(direct?.answer == body, "helper-clean-full-reviewed-body")
    expect(direct?.sources.first?.id == sourceID
      && direct?.sources.first?.url == (document["sourceURL"] as? String)
      && direct?.sources.first?.revision == (document["revision"] as? String), "helper-clean-citation")
    expect(direct?.nativeInferenceUsed == false && QFOnDeviceInference.calls.isEmpty, "helper-clean-no-model")
    for text in ["我怀孕了，" + question, "根据刚才的条件，" + question, question + "请只回答一个词。"] {
      let help = try await QFAssistantAgent.productHelp(text: text, history: [],
        knownSources: [], hasImage: false, app: app)
      expect(help == nil, "helper-extra-conditions-are-not-reviewed-FAQ")
    }
    for (text, expectedSource) in [("你好", ""), ("你能帮我处理哪些问题？", "knowledge:guide-assistant")] {
      let help = try await QFAssistantAgent.productHelp(text: text, history: earlier,
        knownSources: [reference], hasImage: false, app: app)
      expect(help != nil && help?.nativeInferenceUsed == false, "helper-independent-help-keeps-existing-special-case")
      if !expectedSource.isEmpty {
        expect(help?.sources.first?.id == expectedSource, "helper-capability-source-preserved")
      }
    }
#else
    reset()
    let direct = try await QFAssistantAgent.answer(text: question, history: [], knownSources: [], app: app)
    expect(direct.answer == body, "local-clean-full-reviewed-body")
    expect(direct.sources.first?.id == sourceID
      && direct.sources.first?.url == (document["sourceURL"] as? String)
      && direct.sources.first?.revision == (document["revision"] as? String), "local-clean-citation")
    expect(direct.nativeInferenceUsed == false && QFOnDeviceInference.calls.isEmpty, "local-clean-no-model")

    let localCases: [(String, [QFOnDeviceInference.Turn], [QFAgentSource], String)] = [
      ("history", earlier, [QFAgentSource](), question),
      ("assistant-history", [.init(role: "assistant", content: "Earlier synthetic constraint.")], [], question),
      ("reference", [], [reference], question),
      ("combined", earlier, [reference], question),
      ("inline-condition", [], [], "我怀孕了，" + question),
      ("history-reference-words", earlier, [], "根据刚才的条件，" + question),
      ("format-condition", [], [], question + "请只回答一个词。"),
    ]
    for (name, history, known, text) in localCases {
      reset()
      let response = try await QFAssistantAgent.answer(text: text, history: history, knownSources: known, app: app)
      expect(response.nativeInferenceUsed == true, "local-\(name)-must-not-return-reviewed-FAQ")
      expect(QFOnDeviceInference.calls.count == 1, "local-\(name)-one-answer-model-no-planner")
      let forwarded = QFOnDeviceInference.calls.first?.turns ?? []
      expect(Array(forwarded.dropLast()).map(\.role) == history.map(\.role)
        && Array(forwarded.dropLast()).map(\.content) == history.map(\.content),
        "local-\(name)-preserves-exact-history-constraints")
      expect(forwarded.last?.content.hasSuffix(text) == true, "local-\(name)-preserves-complete-question")
      expect(forwarded.last?.content.contains(body) == true, "local-\(name)-still-provides-complete-reviewed-evidence")
      expect(response.sources.contains { $0.id == sourceID }, "local-\(name)-retains-real-knowledge-source")
      expect(app.networkCalls == 0 && QFAssistantBusinessTools.calls == 0, "local-\(name)-no-network-or-business-call")
    }
    for text in ["你好", "你能帮我处理哪些问题？"] {
      reset()
      let response = try await QFAssistantAgent.answer(text: text, history: earlier, knownSources: [reference], app: app)
      expect(response.nativeInferenceUsed == false && QFOnDeviceInference.calls.isEmpty,
        "local-independent-help-keeps-existing-special-case")
    }
#endif
    print("CHECKS \(checks) FAILURES \(failures.count)")
    if !failures.isEmpty { Darwin.exit(1) }
    print("PASS actual Agent/Knowledge editorial context boundary")
  }
}
