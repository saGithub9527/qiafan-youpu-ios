import Foundation
import Darwin

/// Shipping Agent and knowledge index; only provider, HTTP and business boundaries are substituted.
@main @MainActor enum WeeklyReferenceCheck {
  static var checks = 0
  static var failures: [String] = []
  static func expect(_ value: Bool, _ name: String) {
    checks += 1
    if !value { failures.append(name); print("FAIL \(name)") }
  }
  static func main() async throws {
    try await QFAssistantKnowledge.shared.load(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), language: "zh-Hans")
    let question = "帮我制定一周的饮食计划,可以采购食材,我想减肥,"
    let source = QFAgentSource(id: "web:" + String(repeating: "a", count: 64), title: "Public synthetic guidance",
      url: "https://example.org/guidance", revision: nil)
    let publicQuery = "联网搜索均衡饮食与体重管理的一般建议和餐食示例"
    let hit = try JSONSerialization.data(withJSONObject: ["status": "WEB_HIT", "language": "zh-Hans", "webAttempted": true,
      "items": [["id": source.id, "title": source.title, "text": "Synthetic public reference, not a personal prescription.",
        "url": source.url!, "contentTrust": "UNTRUSTED_WEB_SNIPPET", "instructionAuthority": false]]])
    func app() -> QFAppSession {
      let value = QFAppSession(); value.networkAllowed = true
      value.weeklyFailure = QFAPIError(code: 42203, message: "No catalog candidates")
      value.lookupResponse = hit
      value.streamResponse = .init(answer: "HOST_CLOUD_REFERENCE", model: "fixture", sources: [source], actions: [], notice: nil)
      QFOnDeviceInference.calls = []; QFAssistantBusinessTools.calls = 0
      return value
    }
    for cloud in [false, true] {
      let value = app()
      do {
        let reply = try await QFAssistantAgent.weeklyPlan(text: question, cloud: cloud, requestID: UUID(), app: value, progress: { _ in })
        expect(reply != nil, "\(cloud)-returns-reference-reply")
        expect(reply?.sources == [source], "\(cloud)-preserves-actual-source")
        expect(reply?.actions.isEmpty == true, "\(cloud)-has-no-fabricated-plan-action")
        expect(reply?.answer.hasPrefix("以下是饮食安排建议，本轮尚未加入日历计划。\n\n") == true, "\(cloud)-states-not-added-to-calendar")
        expect(value.proposalCalls == 1, "\(cloud)-does-not-retry-creation")
        expect(QFAssistantBusinessTools.calls == 0, "\(cloud)-does-not-write-business-data")
        if cloud {
          expect(value.lookupBodies.isEmpty && value.streamRequests.count == 1, "cloud-reuses-one-shared-stream")
          expect(value.streamRequests.first?.text == publicQuery && value.streamRequests.first?.history.isEmpty == true,
            "cloud-only-sends-public-goal-without-history")
          expect(QFOnDeviceInference.calls.isEmpty, "cloud-does-not-force-native-inference")
        } else {
          let body = try JSONSerialization.jsonObject(with: value.lookupBodies.first ?? Data("{}".utf8)) as? [String: String]
          expect(value.lookupBodies.count == 1 && body == ["query": "均衡饮食与体重管理的一般建议和餐食示例"], "local-one-public-query-only")
          expect(QFOnDeviceInference.calls.count == 1 && reply?.answer.contains("HOST_MODEL_BOUNDARY_REACHED") == true,
            "local-reuses-shared-agent-generation-once")
          expect(value.streamRequests.isEmpty, "local-never-promotes-to-paid-cloud")
        }
      } catch { expect(false, "\(cloud)-catalog-shortage-must-not-end-answer: \(type(of: error))") }
    }
    try await QFAssistantKnowledge.shared.load(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), language: "en")
    let englishQuestion = "Plan my meals for the next seven days, I can buy ingredients and want to lose weight"
    let englishQuery = "Search online for general balanced eating and weight management guidance with meal examples"
    for cloud in [false, true] {
      let value = app(); value.interfaceLanguage = "en"
      var englishHit = try JSONSerialization.jsonObject(with: hit) as! [String: Any]
      englishHit["language"] = "en"; value.lookupResponse = try JSONSerialization.data(withJSONObject: englishHit)
      do {
        let reply = try await QFAssistantAgent.weeklyPlan(text: englishQuestion, cloud: cloud, requestID: UUID(), app: value, progress: { _ in })
        expect(reply?.sources == [source] && reply?.actions.isEmpty == true, "english-\(cloud)-real-sources-without-plan-actions")
        expect(value.proposalCalls == 1 && QFAssistantBusinessTools.calls == 0, "english-\(cloud)-no-extra-creation-or-business-write")
        if cloud {
          expect(value.streamRequests.count == 1 && value.streamRequests.first?.text == englishQuery
            && value.streamRequests.first?.history.isEmpty == true, "english-cloud-only-fixed-public-query")
          expect(QFOnDeviceInference.calls.isEmpty, "english-cloud-no-native-promotion")
        } else {
          let body = try JSONSerialization.jsonObject(with: value.lookupBodies.first ?? Data("{}".utf8)) as? [String: String]
          expect(value.lookupBodies.count == 1 && body == ["query": "general balanced eating and weight management guidance with meal examples"], "english-local-only-fixed-public-query")
          expect(QFOnDeviceInference.calls.count == 1 && value.streamRequests.isEmpty, "english-local-one-native-no-cloud")
        }
      } catch { expect(false, "english-\(cloud)-general-request-not-private: \(type(of: error))") }
    }
    for extra in [", my account is USER-42", ", household HH-42", ", my address is 12 Example Street",
      ", I have diabetes", ", I had heart surgery", ", based on my previous plan", ", use my fridge", ", phone 13800138000"] {
      for cloud in [false, true] {
        let value = app(); value.interfaceLanguage = "en"
        _ = try? await QFAssistantAgent.weeklyPlan(text: englishQuestion + extra, cloud: cloud, requestID: UUID(), app: value, progress: { _ in })
        expect(value.lookupBodies.isEmpty && value.streamRequests.isEmpty, "english-private-\(cloud)-never-exported")
      }
    }
    try await QFAssistantKnowledge.shared.load(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), language: "zh-Hans")
    for problem in [QFAPIError(code: 40300, message: "Forbidden"), QFAPIError(code: 40900, message: "Conflict")] {
      let value = app(); value.weeklyFailure = problem
      do {
        _ = try await QFAssistantAgent.weeklyPlan(text: question, cloud: false, requestID: UUID(), app: value, progress: { _ in })
        expect(false, "other-errors-remain-real-failures")
      } catch { expect((error as? QFAPIError)?.code == problem.code, "other-error-code-preserved") }
      expect(value.lookupBodies.isEmpty && value.streamRequests.isEmpty, "other-errors-never-trigger-search")
    }
    for privateQuestion in [
      "帮我制定一周饮食计划，根据我刚才的聊天内容", "帮我制定一周饮食计划，我的手机号13800138000",
      "帮我制定一周饮食计划，我家库存有鸡蛋", "帮我制定一周饮食计划，我住上海某街道",
      "帮我制定一周饮食计划，我对花生过敏", "帮我制定一周饮食计划，预算100元"
    ] {
      let value = app()
      _ = try? await QFAssistantAgent.weeklyPlan(text: privateQuestion, cloud: false, requestID: UUID(), app: value, progress: { _ in })
      expect(value.lookupBodies.isEmpty && value.streamRequests.isEmpty, "private-or-extra-constraint-never-exported")
    }
    for cloud in [false, true] {
      let value = app()
      if cloud { value.scopeAfterStream = "another-account" } else { value.scopeAfterLookup = "another-account" }
      do {
        _ = try await QFAssistantAgent.weeklyPlan(text: question, cloud: cloud, requestID: UUID(), app: value, progress: { _ in })
        expect(false, "changed-scope-cannot-publish-reference")
      } catch { expect(error is CancellationError, "changed-scope-is-cancelled") }
    }
    let noMatch = app()
    noMatch.lookupResponse = try JSONSerialization.data(withJSONObject: ["status": "NO_MATCH", "language": "zh-Hans", "webAttempted": true, "items": []])
    do {
      let reply = try await QFAssistantAgent.weeklyPlan(text: question, cloud: false, requestID: UUID(), app: noMatch, progress: { _ in })
      expect(reply?.sources.isEmpty == true && reply?.actions.isEmpty == true, "no-match-does-not-fabricate-sources-or-plan")
      expect(QFOnDeviceInference.calls.isEmpty, "no-match-does-not-call-model-to-repair-evidence")
    } catch { expect(false, "no-match-has-honest-reference-failure") }
    let cancelled = app(); cancelled.weeklyFailure = CancellationError()
    do {
      _ = try await QFAssistantAgent.weeklyPlan(text: question, cloud: false, requestID: UUID(), app: cancelled, progress: { _ in })
      expect(false, "cancelled-create-must-propagate")
    } catch { expect(error is CancellationError, "cancelled-create-is-cancellation") }
    expect(cancelled.lookupBodies.isEmpty && cancelled.streamRequests.isEmpty, "cancelled-create-never-searches")
    print("\(failures.isEmpty ? "PASS" : "FAIL") \(checks) weekly-reference behavior checks")
    if !failures.isEmpty { exit(1) }
  }
}
