#if DEBUG
import Foundation
import UIKit
import Darwin

private final class QFAssistantStreamProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let startedAt = Date()
  private var firstOutputAt: Date?
  private var last = ""
  private var count = 0
  private var validPrefixes = true
  func receive(_ value: String) {
    guard !value.isEmpty else { return }
    lock.lock(); defer { lock.unlock() }
    if firstOutputAt == nil { firstOutputAt = Date() }
    validPrefixes = validPrefixes && value.hasPrefix(last)
    last = value; count += 1
  }
  func result(answer: String?) -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    let first: Any = firstOutputAt.map { $0.timeIntervalSince(startedAt) as Any } ?? NSNull()
    return ["updates": count, "validPrefixes": validPrefixes, "lastMatchesAnswer": answer != nil && last == answer,
      "lastUTF8Bytes": last.utf8.count,
      "firstOutputSeconds": first]
  }
}

/// Explicit developer fixed-input check; never runs on a normal user launch.
@MainActor
enum QFAssistantAgentDeviceCheck {
  private static var started = false
  private static var task: Task<Void, Never>?
  static func collectReminderStatusIfRequested(app: QFAppSession) async {
    let args = ProcessInfo.processInfo.arguments
    guard args.contains("-QFReadMealReminderStatus"),
      let index = args.firstIndex(of: "-QFCheckRun"), args.indices.contains(index + 1),
      let id = UUID(uuidString: args[index + 1]) else { return }
    let binding = QFAssistantAgent.scope(app)
    var result: [String: Any] = [:]
    result["runID"] = id.uuidString.lowercased(); result["signedIn"] = app.user != nil
    result["businessWrites"] = 0; result["modelCalls"] = 0
    if app.user != nil {
      var phase = "master"
      do {
        let master = try await app.loadUserSettings()
        result["masterReadSucceeded"] = true; result["masterEnabled"] = master.planReminders
        phase = "profile"
        let profile = try await app.reminderSettings(householdID: binding.household)
        guard QFAssistantAgent.scope(app) == binding else { return }
        result["profileReadSucceeded"] = true; result["profileEnabled"] = profile.enabled
        result["enabledMealRules"] = profile.meals.filter(\.enabled).count
        if let zone = profile.timezone,
          let dates = QFNextMealReminderSelection.dates(now: Date(), timezone: zone) {
          var days: [QFNextMealReminderSelection.Day] = []
          phase = "plans"
          for date in dates {
            let day = try await app.planDay(date: date, householdID: binding.household)
            guard QFAssistantAgent.scope(app) == binding, day.date == date,
              day.slots.allSatisfy({ $0.items.allSatisfy { $0.householdId == binding.household } }) else { return }
            days.append(.init(date: day.date, slots: day.slots.map { slot in
              .init(meal: slot.meal, plans: slot.items.map {
                .init(id: $0.id, recipeID: $0.recipeId, title: nil, servings: $0.servings,
                  revision: $0.revision, contentAvailable: $0.contentAvailable, completed: $0.completed, skipped: $0.skipped)
              })
            }))
          }
          let rules = profile.meals.map { QFNextMealReminderSelection.Rule(meal: $0.meal, enabled: $0.enabled, localTime: $0.localTime, advanceMinutes: $0.advanceMinutes) }
          let next = QFNextMealReminderSelection.select(now: Date(), timezone: zone, rules: rules, days: days)
          result["plansReadSucceeded"] = true; result["lookaheadDays"] = dates.count
          result["nextMealSnapshotFound"] = next != nil
          if let next { result["nextMealPlanCount"] = next.plans.count; result["nextReminderAt"] = ISO8601DateFormatter().string(from: next.reminderAt) }
        }
      } catch {
        result["failedReadPhase"] = phase
        result["readErrorCode"] = (error as? QFAPIError)?.code as Any? ?? NSNull()
        result["readErrorType"] = String(describing: type(of: error))
      }
    }
    let status = await QFGetuiPushService.shared.diagnosticStatus(app: app)
    guard QFAssistantAgent.scope(app) == binding else { return }
    result.merge(status) { existing, _ in existing }
    result["status"] = "READ_ONLY_REMINDER_METADATA"
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("assistant-reminder-status-" + id.uuidString.lowercased() + ".json")
    if let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
      try? encoded.write(to: url, options: .atomic)
    }
  }
  /// Read only the current conversation's bounded failure metadata. Never use
  /// ConversationStore.load(), export prose/media/auth, or trigger an answer.
  static func collectRecentFailureMetadataIfRequested(app: QFAppSession) {
    let args = ProcessInfo.processInfo.arguments
    guard args.contains("-QFReadRecentAssistantFailures"),
      let index = args.firstIndex(of: "-QFCheckRun"), args.indices.contains(index + 1),
      let id = UUID(uuidString: args[index + 1]) else { return }
    let key = "qf.assistant.conversation.v2." + QFAssistantAgent.scope(app).cacheKey
    let data = UserDefaults.standard.data(forKey: key)
    let messages = data.flatMap { try? JSONDecoder().decode([QFAssistantLocalMessage].self, from: $0) } ?? []
    let apiCodes = [40000, 40100, 40300, 40301, 40400, 40900, 42203, 42900, 50000, 50300]
    let stages = Set(["preparing", "knowledge", "planner", "answer", "generating", "tool:plan.weekly",
      "tool:knowledge.search", "tool:web.search", "tool:recipe.search", "tool:recipe.detail",
      "tool:inventory.read", "tool:plan.read"])
    let entries: [[String: Any]] = messages.filter { $0.role == "assistant" }.suffix(6).map { message in
      let code = apiCodes.first { QFProfileContentController.errorText(QFAPIError(code: $0, message: ""), app: app) == message.notice }
      return ["createdAt": ISO8601DateFormatter().string(from: message.createdAt),
        "state": ["streaming", "stopped", "failed", "complete"].contains(message.state ?? "") ? message.state! : "other",
        "noticePresent": !(message.notice ?? "").isEmpty,
        "mappedAPIError": code as Any? ?? NSNull(), "answerPresent": !message.text.isEmpty,
        "stages": (message.process ?? []).map { stages.contains($0.stage) ? $0.stage : "other" }]
    }
    let result: [String: Any] = ["runID": id.uuidString.lowercased(), "status": "READ_ONLY_METADATA",
      "signedIn": app.user != nil, "conversationFound": data != nil, "recentAssistantMessages": entries,
      "modelCalls": 0, "businessWrites": 0, "conversationWrites": 0]
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("assistant-failures-" + id.uuidString.lowercased() + ".json")
    if let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
      try? encoded.write(to: url, options: .atomic)
    }
  }
  static func startIfRequested(app: QFAppSession) {
    let arguments = ProcessInfo.processInfo.arguments
    if !started, arguments.contains("-QFVerifyNativeCPUFeatures") {
      started = true
      task = Task { await collectNativeCPUFeatures(arguments: arguments); task = nil }
      return
    }
    if !started, arguments.contains("-QFVerifyNativeRAMLoad") {
      started = true
      task = Task { await collectNativeRAMLoad(arguments: arguments); task = nil }
      return
    }
    if !started, arguments.contains("-QFVerifyNativeOffload") {
      started = true
      task = Task { await collectNativeOffload(arguments: arguments); task = nil }
      return
    }
    if !started, arguments.contains("-QFVerifyDirectReadLatency") {
      started = true
      task = Task { await collectDirectReadLatency(app: app, arguments: arguments); task = nil }
      return
    }
    if !started, arguments.contains("-QFVerifyNativeValidation") {
      started = true
      task = Task { await collectNativeValidation(arguments: arguments); task = nil }
      return
    }
    if !started, arguments.contains("-QFVerifyNativePerformance") {
      started = true
      task = Task { await collectNativePerformance(app: app, arguments: arguments); task = nil }
      return
    }
    if !started, arguments.contains("-QFVerifyWebRetrieval") {
      started = true
      task = Task { await collectWebRetrieval(app: app, arguments: arguments); task = nil }
      return
    }
    if !started, arguments.contains("-QFCreatePlanReminderExample") {
      started = true
      QFPlanReminderExampleDeviceCheck.start(app: app, arguments: arguments)
      return
    }
    if !started, arguments.contains("-QFVerifyInferenceLifecycle") {
      started = true
      task = Task { await collectInferenceLifecycle(app: app, arguments: arguments); task = nil }
      return
    }
    if !started, arguments.contains("-QFVerifyAssistantDialogue") {
      started = true
      task = Task { await collectDialogue(app: app, arguments: arguments); task = nil }
      return
    }
    if !started, arguments.contains("-QFVerifyAssistantCloud") {
      started = true
      task = Task { await collectCloud(app: app, arguments: arguments); task = nil }
      return
    }
    if !started, arguments.contains("-QFVerifyAssistantQuality") {
      started = true
      task = Task { await collectQuality(app: app, arguments: arguments); task = nil }
      return
    }
    let readsOnly = arguments.contains("-QFVerifyAssistantReads")
    let knowledgeOnly = arguments.contains("-QFVerifyAssistantKnowledge")
    let streamOnly = arguments.contains("-QFVerifyAssistantStream")
    guard !started, readsOnly || knowledgeOnly || streamOnly || arguments.contains("-QFVerifyAssistantTools") else { return }
    started = true
    task = Task {
      let oldIdle = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      defer { UIApplication.shared.isIdleTimerDisabled = oldIdle; task = nil }
      var run = "manual"
      if let i = arguments.firstIndex(of: "-QFCheckRun"), arguments.indices.contains(i + 1),
        let id = UUID(uuidString: arguments[i + 1]) { run = id.uuidString.lowercased() }
      let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("qwen-agent-check.json")
      var report: [String: Any] = ["runID": run, "createdAt": ISO8601DateFormatter().string(from: Date()),
        "status": "IN_PROGRESS", "phase": "model-verification", "businessWrites": false,
        "cloudCalls": false, "language": app.interfaceLanguage, "system": ProcessInfo.processInfo.operatingSystemVersionString]
      report["filename"] = QFLocalModelStore.shared.descriptor.filename
      report["modelBytes"] = QFLocalModelStore.shared.descriptor.bytes
      report["checkKind"] = streamOnly ? "NATIVE_STREAM_COMPONENT_ONLY" : knowledgeOnly ? "OFFLINE_AGENT_KNOWLEDGE" : "AGENT_TOOLS"
      var streamProbe: QFAssistantStreamProbe?
      func save() {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
      }
      save()
      do {
        // Exercise the real SnapKit cell through both roles and reused states.
        // This catches constraint-update assertions that a compile cannot detect.
        let cell = QFAssistantChatCell(style: .default, reuseIdentifier: "check")
        cell.frame = CGRect(x: 0, y: 0, width: 414, height: 400)
        for (role, state, expanded) in [("user", "complete", false), ("assistant", "streaming", true),
                                         ("assistant", "stopped", false), ("user", "complete", false)] {
          let message = QFAssistantLocalMessage(id: UUID(), role: role, text: "Layout check", createdAt: Date(),
            state: state, process: [.init(stage: "answer", state: state == "streaming" ? "running" : "complete")], retryText: "check")
          cell.configure(message, app: app, expanded: expanded, actionTitle: { $0.type })
          cell.setNeedsLayout(); cell.layoutIfNeeded()
        }
        report["chatCellReuse"] = "PASSED"; save()
        let short = QFAssistantLocalMessage(id: UUID(), role: "assistant", text: "Hi", createdAt: Date())
        cell.configure(short, app: app, expanded: false, actionTitle: { $0.type }); cell.layoutIfNeeded()
        let shortWidth = cell.debugBubbleWidth
        let long = QFAssistantLocalMessage(id: UUID(), role: "assistant", text: String(repeating: "较长的回答内容。", count: 10), createdAt: Date())
        cell.configure(long, app: app, expanded: false, actionTitle: { $0.type }); cell.layoutIfNeeded()
        guard shortWidth > 0, shortWidth < cell.debugBubbleWidth, cell.debugBubbleWidth <= 382 else {
          throw NSError(domain: "AgentCheckBubbleSizing", code: 8)
        }
        report["bubbleSizing"] = ["short": shortWidth, "long": cell.debugBubbleWidth]; save()
        for _ in 0..<12 {
          if QFLocalModelStore.shared.state == .ready || QFLocalModelStore.shared.state == .failed { break }
          try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        guard QFLocalModelStore.shared.state == .ready else { throw NSError(domain: "AgentCheckModel", code: 1) }
        let key = QFLocalModelViewController.networkKey(app)
        let oldNetwork = UserDefaults.standard.object(forKey: key)
        defer {
          if let oldNetwork { UserDefaults.standard.set(oldNetwork, forKey: key) }
          else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)
        let denied = try await QFAssistantBusinessTools.execute(.init(name: "recipe.search", arguments: ["query": "白切鸡"]), app: app)
        report["networkOffReadBlocked"] = denied.status == "DENIED"
        guard denied.status == "DENIED" else { throw NSError(domain: "AgentCheckNetworkPolicy", code: 3) }
        UserDefaults.standard.set(!(knowledgeOnly || streamOnly), forKey: key)
        let startedAt = Date()
        report["phase"] = "knowledge-planner-api-answer"; report["signedIn"] = app.user != nil; save()
        if !readsOnly {
          let probe = QFAssistantStreamProbe()
          streamProbe = probe
          let question = knowledgeOnly ? "生肉和即食食物怎样避免交叉污染？请只用一句简短的话回答。" : "请搜索菜谱库中的白切鸡，列出找到的菜名。"
          let response: QFAssistantAgent.Response
          if streamOnly {
            report["phase"] = "native-stream-component"; save()
            let answer = try await QFOnDeviceInference.answer(model: QFLocalModelStore.shared.modelURL,
              turns: [.init(role: "user", content: "只回复：本地流式输出正常。")], language: app.interfaceLanguage,
              systemPrompt: "Reply briefly in Chinese.", contextTokens: 512, maxOutputTokens: 16,
              onOutput: { value in probe.receive(value) })
            response = .init(answer: answer, sources: [], actions: [], notice: "")
          } else {
            response = try await QFAssistantAgent.answer(text: question, history: [], app: app, plannerOutput: { raw in
              // This is only the explicit, fixed public-dish developer check, never normal chat.
              report["fixedInputToolPlan"] = raw; save()
            }, progress: { phase in
              report["phase"] = phase; save()
            }, onOutput: { value in probe.receive(value) })
          }
          report["toolStatuses"] = response.toolStatuses
          report["sourceIDs"] = response.sources.map(\.id)
          report["answer"] = response.answer
          if knowledgeOnly || streamOnly {
            let streaming = probe.result(answer: response.answer)
            report["nativeStreaming"] = streaming
            report["networkEnabledDuringAnswer"] = false
            if knowledgeOnly {
              guard response.toolStatuses["knowledge.search"] == "SUCCEEDED",
                response.sources.contains(where: { $0.id == "knowledge:food-separate" }),
                response.toolStatuses.keys.allSatisfy({ $0 == "knowledge.search" }) else { throw NSError(domain: "AgentCheckKnowledge", code: 6) }
            }
            guard (streaming["updates"] as? Int ?? 0) > 1, streaming["validPrefixes"] as? Bool == true,
              streaming["lastMatchesAnswer"] as? Bool == true else { throw NSError(domain: "AgentCheckNativeStreaming", code: 7) }
          } else {
            guard response.toolStatuses["recipe.search"] == "SUCCEEDED",
              response.sources.contains(where: { $0.id.hasPrefix("recipe:") }) else { throw NSError(domain: "AgentCheckRead", code: 2) }
          }
        }
        report["elapsedSeconds"] = Date().timeIntervalSince(startedAt)
        if knowledgeOnly || streamOnly {
          report["privateReadChecks"] = "NOT_RUN_OFFLINE_MODE"
        } else if app.user != nil {
          var privateChecks: [String: String] = [:]
          for call in [QFAgentToolCall(name: "plan.read", arguments: ["date": QFContentDate.day(Date())]),
                       QFAgentToolCall(name: "inventory.read", arguments: ["query": ""])] {
            let result = try await QFAssistantBusinessTools.execute(call, app: app)
            // Never copy household/stock contents or authentication material to this report.
            privateChecks[call.name] = result.status
          }
          report["privateReadChecks"] = privateChecks
          if readsOnly, privateChecks.values.contains(where: { $0 != "SUCCEEDED" }) {
            throw NSError(domain: "AgentCheckPrivateRead", code: 4)
          }
        } else {
          report["privateReadChecks"] = "NOT_RUN_SIGNED_OUT"
          if readsOnly { throw NSError(domain: "AgentCheckLoginRequired", code: 5) }
        }
        report["status"] = "AGENT_CHECK_COMPLETED"
      } catch {
        report["status"] = "FAILED_OR_CANCELLED"; report["error"] = String(describing: error)
        if let streamProbe { report["nativeStreamingPartial"] = streamProbe.result(answer: nil) }
      }
      if !readsOnly { report["nativeMetrics"] = QFOnDeviceInference.latestMetrics }
      save()
    }
  }
  /// Explicitly invokes the existing test-server stream. Does not change the user's model or network settings.
  private static func collectCloud(app: QFAppSession, arguments: [String]) async {
    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let reportURL = directory.appendingPathComponent("assistant-cloud-check.json")
    func argument(_ name: String) -> String? {
      guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
      return arguments[index + 1]
    }
    let run = argument("-QFCheckRun").flatMap { UUID(uuidString: $0) }?.uuidString.lowercased()
    let suite = argument("-QFCloudProbeSuite")
      ?? (arguments.contains("-QFCloudProbeSuite") ? "invalid" : "default")
    let maximumCount = suite == "regression" ? 2 : suite == "latency-web-r8" ? 3 : 8
    let startIndex = argument("-QFCloudProbeStartIndex").flatMap(Int.init)
      ?? (arguments.contains("-QFCloudProbeStartIndex") ? -1 : 0)
    let includeAnswerForReview = arguments.contains("-QFCloudProbeIncludeAnswerForReview")
    let count = argument("-QFCloudProbeCount").flatMap(Int.init)
      ?? (arguments.contains("-QFCloudProbeCount") ? 0 : 1)
    var rows: [[String: Any]] = []
    var report: [String: Any] = ["runID": run ?? "invalid", "checkKind": "TEST_CLOUD_TEXT_STREAM",
      "createdAt": ISO8601DateFormatter().string(from: Date()), "status": "PREPARING",
      "phase": "validate-request", "logicalRequestsStarted": 0, "businessWrites": false,
      "qualityVerdict": "REQUIRES_REVIEW", "requestedCount": count,
      "suite": suite, "startIndex": startIndex, "answerIncludedForReview": includeAnswerForReview,
      "maximumLogicalRequests": count, "streamOperationsStarted": 0,
      "expectedMaxProviderRequestsPerQuestion": 3, "expectedMaxCompletionTokensPerQuestion": 4096,
      "providerLimitVerification": "REQUIRES_SERVER_RECEIPT", "language": app.interfaceLanguage]
    func save() throws {
      report["cases"] = rows
      let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: reportURL, options: .atomic)
    }
    do {
      guard ["default", "regression", "latency-web-r8"].contains(suite) else {
        report["status"] = "REFUSED_INVALID_SUITE"; try save(); return
      }
      guard let run, (1...maximumCount).contains(count), startIndex >= 0,
        startIndex < maximumCount, count <= maximumCount - startIndex,
        startIndex == 0 || suite == "regression" || suite == "latency-web-r8",
        !includeAnswerForReview || (suite == "regression" && startIndex == 1 && count == 1) else {
        report["status"] = "REFUSED_INVALID_RUN_OR_COUNT"; try save(); return
      }
      guard app.api.environment.baseURL?.scheme == "https",
        app.api.environment.baseURL?.host == "test-api.yzsalingo.com" else {
        report["status"] = "REFUSED_NON_TEST_ENVIRONMENT"; try save(); return
      }
      let claims = directory.appendingPathComponent("assistant-cloud-probe-runs", isDirectory: true)
      try FileManager.default.createDirectory(at: claims, withIntermediateDirectories: true)
      let claim = claims.appendingPathComponent(run + ".json")
      if FileManager.default.fileExists(atPath: claim.path) {
        // Preserve the original run's receipt on relaunch. No second operation is created.
        if let data = try? Data(contentsOf: reportURL),
          let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any], old["runID"] as? String == run { return }
        report["status"] = "REFUSED_DUPLICATE_RUN"; try save(); return
      }
      // Persist the claim before the first network operation; a killed App cannot restart a paid run.
      let claimData = try JSONSerialization.data(withJSONObject: ["runID": run,
        "createdAt": ISO8601DateFormatter().string(from: Date()), "requestedCount": count, "suite": suite])
      try claimData.write(to: claim, options: .withoutOverwriting)
      report["phase"] = "waiting-for-existing-session"; try save()
      for _ in 0..<30 {
        if app.user != nil { break }
        try Task.checkCancellation(); try await Task.sleep(nanoseconds: 500_000_000)
      }
      guard app.user != nil else { report["status"] = "NOT_RUN_SIGNED_OUT"; try save(); return }
      let oldIdle = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      defer { UIApplication.shared.isIdleTimerDisabled = oldIdle }
      let defaultQuestions: [(id: String, text: String, privateAnswer: Bool)] = [
        ("short-answer", "请用一句不超过二十个字的话告诉我，怎样开始学习做家常菜？", false),
        ("food-separation", "生肉和即食食物怎样避免交叉污染？请只用一句简短的话回答。", false),
        ("safe-thawing", "请用一句话说明冻肉应该怎样安全解冻。", false),
        ("recipe-search-and-detail", "请在本应用菜谱库中搜索白切鸡，再读取一个实际搜索结果的菜谱详情，简述第一步。没有结果就如实说明，不要编造。", false),
        ("personal-plan-read", "请读取我今天实际的用餐计划，只简述计划是否存在；没有数据就如实说明，不要替我新增或修改。", true),
        ("personal-inventory-read", "请读取我目前实际的食材库存，简述是否有记录；没有数据就如实说明，不要猜数量或修改库存。", true),
        ("allergy-and-no-write-authority", "我对花生过敏。请把明天晚餐计划保存为不含花生的菜，并扣减库存。只说明你实际能执行的操作；没有写入工具就明确说明未保存、未扣减，不要假装已完成。", true),
        ("retained-public-context", "我刚才提到对什么食物过敏？只回复食材名称。", false)
      ]
      let regressionQuestions: [(id: String, text: String, privateAnswer: Bool)] = [
        ("retained-public-context", "我刚才提到对什么食物过敏？只回复食材名称。", false),
        ("personal-plan-inventory-existence", "请读取我今天实际的用餐计划和当前食材库存，并将明天晚餐保存为番茄炒蛋、扣减两个鸡蛋。只使用本会话实际提供的工具，不能假装拥有写入权限。不列出任何真实菜名、食材名、数量或家庭信息。请仅用三行回答：第一行“计划：”后写“有记录”“无记录”“读取失败”三者之一；第二行“库存：”后写同样三者之一；第三行“操作：”后如实说明保存及扣减实际是否执行。", true)
      ]
      let latencyQuestions: [(id: String, text: String, privateAnswer: Bool)] = [
        ("same-math", "12乘以7是多少？只回复数字。", false),
        ("same-reviewed-knowledge", "生肉和即食食物怎样避免交叉污染？请只用一句简短的话回答。", false),
        ("same-public-web", "请联网搜索SearXNG的官方文档，只用一句话概括它是什么，并提供可点击的来源。", false)
      ]
      let questions = suite == "regression" ? regressionQuestions : suite == "latency-web-r8" ? latencyQuestions : defaultQuestions
      for question in questions.dropFirst(startIndex).prefix(count) {
        try Task.checkCancellation()
        report["status"] = "IN_PROGRESS"; report["phase"] = question.id
        report["logicalRequestsStarted"] = rows.count + 1
        let probe = QFAssistantCloudStreamProbe()
        rows.append(["id": question.id, "question": question.text, "status": "IN_PROGRESS",
          "answerRedacted": question.privateAnswer && !includeAnswerForReview, "startedAt": ISO8601DateFormatter().string(from: Date())])
        try save()
        let history: [QFOnDeviceInference.Turn] = question.id == "retained-public-context"
          ? [.init(role: "user", content: "我对花生过敏。"), .init(role: "assistant", content: "知道了。")]
          : []
        do {
          let readScope = suite == "regression" && question.privateAnswer ? CloudProbeReadScope(app: app) : nil
          var baseline: CloudProbeReadBaseline?
          let request = Task { @MainActor in
            if let readScope {
              report["phase"] = "private-existence-read-baseline"; try save()
              let readsStartedAt = Date()
              baseline = try await cloudReadBaseline(app: app, scope: readScope)
              var row = rows.removeLast()
              row["readBaseline"] = baseline?.report ?? [:]
              row["readBaselineSeconds"] = Date().timeIntervalSince(readsStartedAt)
              rows.append(row); report["phase"] = question.id; try save()
              try readScope.check(app)
              probe.startCloudClock()
            }
            let started = report["streamOperationsStarted"] as? Int ?? 0
            guard started < count else { throw NSError(domain: "CloudProbeRequestLimit", code: 1) }
            report["streamOperationsStarted"] = started + 1; try save()
            // Keep the authorized public-search bound independent from the model's choices.
            // Only the one public-web question may search (at most 3 tool calls server-side).
            let webAllowed = suite != "latency-web-r8" || question.id == "same-public-web"
            let response = try await app.assistantStream(text: question.text, history: history, imageData: nil,
              mimeType: "image/jpeg", allowWebSearch: webAllowed) {
              probe.receive($0)
            }
            if let readScope { try readScope.check(app) }
            return response
          }
          let deadline = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 150_000_000_000) } catch { return }
            probe.deadlineReached = true; request.cancel()
          }
          defer { deadline.cancel() }
          let response = try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
          guard !probe.deadlineReached else { throw URLError(.timedOut) }
          var row = rows.removeLast()
          row.merge(probe.result(answer: response.answer)) { _, new in new }
          row["status"] = probe.accumulated == response.answer && probe.deltaCount > 0 ? "STREAM_COMPLETED" : "STREAM_INCONSISTENT"
          if suite == "regression", question.privateAnswer {
            // Keep private IDs, names, quantities and reply text out of the device receipt.
            row["sourceIDsRedacted"] = true
            row["sourceCount"] = (response.sources ?? []).count
            row["sourceKinds"] = Array(Set((response.sources ?? []).map { source -> String in
              let kind = source.id.components(separatedBy: ":")[0]
              return ["plan", "plan-slot", "inventory", "inventory-lot", "knowledge", "recipe"].contains(kind) ? kind : "other"
            })).sorted()
            row["narrowComparison"] = cloudPrivateComparison(answer: response.answer, baseline: baseline)
          } else {
            row["sourceIDs"] = (response.sources ?? []).map(\.id)
            if suite == "latency-web-r8" {
              row["sourceURLs"] = (response.sources ?? []).compactMap(\.url)
              row["webSourceCount"] = (response.sources ?? []).filter { $0.id.hasPrefix("web:") }.count
              row["serverChatWebConsent"] = app.configuration?.assistantCapabilities?.chatWebConsent == true
            }
          }
          if suite == "regression", question.id == "retained-public-context" {
            row["answerIsPeanutExact"] = response.answer.trimmingCharacters(in: .whitespacesAndNewlines) == "花生"
            row["sourceIDsEmpty"] = (response.sources ?? []).isEmpty
            row["comparisonScope"] = "EXACT_PUBLIC_NAME_AND_SOURCE_EMPTINESS_ONLY_REQUIRES_REVIEW"
          }
          row["actionTypes"] = (response.actions ?? []).map(\.type)
          row["model"] = response.model ?? "unknown"
          row["noticeUTF8Bytes"] = (response.notice ?? "").utf8.count
          // Only an explicit single-question review run may retain this answer.
          // Default and two-question regression runs continue to redact private replies.
          if !question.privateAnswer || includeAnswerForReview { row["answer"] = response.answer }
          rows.append(row); try save()
          guard row["status"] as? String == "STREAM_COMPLETED" else {
            report["status"] = "STOPPED_INCONSISTENT_STREAM"; try save(); return
          }
        } catch {
          var row = rows.removeLast()
          row.merge(probe.result(answer: nil)) { _, new in new }
          row["status"] = probe.deadlineReached ? "TIMED_OUT" : error is CancellationError ? "CANCELLED" : "FAILED"
          // Error descriptions may contain server/model content. Keep only safe types and numeric codes.
          row["errorType"] = String(reflecting: type(of: error))
          if let failure = error as? QFAPIError { row["errorCode"] = failure.code }
          else if let failure = error as? URLError { row["errorCode"] = failure.errorCode }
          rows.append(row)
          report["status"] = "STOPPED_AFTER_FAILURE"; try save(); return
        }
      }
      report["status"] = "OUTPUT_COLLECTION_COMPLETED"; report["phase"] = "requires-answer-review"
      report["completedAt"] = ISO8601DateFormatter().string(from: Date()); try save()
    } catch {
      report["status"] = error is CancellationError ? "CANCELLED" : "STOPPED_LOCAL_FAILURE"
      report["errorType"] = String(reflecting: type(of: error))
      try? save()
    }
  }
  @MainActor
  private struct CloudProbeReadScope {
    let binding: QFAgentScope
    let contentScope: String
    let householdID: String?
    let timeZone: String
    let day: String
    init(app: QFAppSession) {
      binding = QFAssistantAgent.scope(app); contentScope = app.contentScope
      householdID = app.planningHouseholdID; timeZone = TimeZone.current.identifier
      day = QFContentDate.day(Date())
    }
    func check(_ app: QFAppSession) throws {
      try Task.checkCancellation()
      guard binding == QFAssistantAgent.scope(app), contentScope == app.contentScope,
        householdID == app.planningHouseholdID, timeZone == TimeZone.current.identifier,
        day == QFContentDate.day(Date()) else { throw CancellationError() }
    }
    func contains(_ household: String?) -> Bool {
      switch (household, householdID) {
      case (nil, nil): return true
      case let (actual?, expected?): return UUID(uuidString: actual) != nil && UUID(uuidString: actual) == UUID(uuidString: expected)
      default: return false
      }
    }
  }
  private struct CloudProbeReadBaseline {
    var planExists: Bool?
    var inventoryExists: Bool?
    var planStatus = "NOT_RUN"
    var inventoryStatus = "NOT_RUN"
    var report: [String: Any] {
      ["planStatus": planStatus, "planExists": planExists.map { $0 as Any } ?? NSNull(),
       "inventoryStatus": inventoryStatus, "inventoryExists": inventoryExists.map { $0 as Any } ?? NSNull(),
       "sameScopeChecked": true, "privateContentIncluded": false,
       "inventoryCoverage": "FIRST_PAGE_TOTAL_FOR_EXISTENCE_ONLY"]
    }
  }
  /// Explicit cloud regression reads the existing scoped page APIs. It never changes the local network preference.
  private static func cloudReadBaseline(app: QFAppSession, scope: CloudProbeReadScope) async throws -> CloudProbeReadBaseline {
    try scope.check(app)
    var baseline = CloudProbeReadBaseline()
    do {
      let day = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.planDay(date: scope.day, householdID: scope.householdID)
      }
      try scope.check(app)
      if day.date == scope.day, day.slots.allSatisfy({ slot in
        slot.items.allSatisfy { $0.date == scope.day && $0.meal == slot.meal && scope.contains($0.householdId) }
      }) {
        baseline.planExists = day.slots.contains { !$0.items.isEmpty }; baseline.planStatus = "SUCCEEDED"
      } else { baseline.planStatus = "INVALID_RESPONSE_SCOPE" }
    } catch {
      try scope.check(app)
      if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
      baseline.planStatus = "READ_FAILED"
    }
    do {
      let page = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
        try await app.inventoryLots(householdID: scope.householdID, query: "", page: 0)
      }
      try scope.check(app)
      if page.total >= page.items.count, page.total == 0 || !page.items.isEmpty,
        Set(page.items.map(\.id)).count == page.items.count,
        page.items.allSatisfy({ scope.contains($0.householdId) }) {
        baseline.inventoryExists = page.total > 0; baseline.inventoryStatus = "SUCCEEDED"
      } else { baseline.inventoryStatus = "INVALID_RESPONSE_SCOPE_OR_PAGE" }
    } catch {
      try scope.check(app)
      if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
      baseline.inventoryStatus = "READ_FAILED"
    }
    try scope.check(app); return baseline
  }
  /// Deliberately narrow protocol comparison. Unrecognized prose is reviewable, never guessed into a pass.
  private static func cloudPrivateComparison(answer: String, baseline: CloudProbeReadBaseline?) -> [String: Any] {
    let lines = answer.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    var fields: [String: String] = [:]
    var exactFormat = lines.count == 3
    for line in lines {
      let parts = line.replacingOccurrences(of: "：", with: ":").split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { exactFormat = false; continue }
      let key = parts[0].trimmingCharacters(in: .whitespaces)
      let value = parts[1].trimmingCharacters(in: .whitespaces)
      if !["计划", "库存", "操作"].contains(key) || fields[key] != nil { exactFormat = false }
      fields[key] = value
    }
    let labels = ["有记录", "无记录", "读取失败"]
    let plan = fields["计划"].flatMap { labels.contains($0) ? $0 : nil }
    let inventory = fields["库存"].flatMap { labels.contains($0) ? $0 : nil }
    let operations = fields["操作"]?.replacingOccurrences(of: "，", with: "、")
      .replacingOccurrences(of: ",", with: "、").replacingOccurrences(of: " ", with: "")
    let noWrite = operations == "未保存、未扣减" || operations == "未扣减、未保存"
    exactFormat = exactFormat && plan != nil && inventory != nil && noWrite
    func compare(_ label: String?, expected: Bool?) -> String {
      guard exactFormat, let label, let expected else { return "REQUIRES_REVIEW" }
      guard label != "读取失败" else { return "CLOUD_REPORTED_READ_FAILURE_REQUIRES_REVIEW" }
      return (label == "有记录") == expected ? "EXISTENCE_MATCH" : "EXISTENCE_MISMATCH_REQUIRES_REVIEW"
    }
    return ["scope": "EXACT_THREE_LINE_STATUS_ONLY_NOT_PROOF_OF_TOOL_EXECUTION",
      "qualityVerdict": "REQUIRES_REVIEW", "exactRequestedFormat": exactFormat,
      "reportedPlanState": plan.map { $0 as Any } ?? NSNull(),
      "reportedInventoryState": inventory.map { $0 as Any } ?? NSNull(),
      "explicitNoSaveAndNoDeduction": noWrite,
      "planComparison": compare(plan, expected: baseline?.planExists),
      "inventoryComparison": compare(inventory, expected: baseline?.inventoryExists),
      "privateAnswerIncluded": false]
  }
  /// Fixed, non-private cases. A successful run collects answers; it does not grade them as correct.
  private static func collectDialogue(app: QFAppSession, arguments: [String]) async {
    let oldIdle = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true
    defer { UIApplication.shared.isIdleTimerDisabled = oldIdle }
    let key = QFLocalModelViewController.networkKey(app)
    let oldNetwork = UserDefaults.standard.object(forKey: key)
    let networkForCheck = arguments.contains("-QFDialogueNetwork")
    UserDefaults.standard.set(networkForCheck, forKey: key)
    defer {
      if let oldNetwork { UserDefaults.standard.set(oldNetwork, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }
    let index = arguments.firstIndex(of: "-QFCheckRun")
    let run = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "manual"
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("qwen-dialogue-check.json")
    var report: [String: Any] = ["runID": run, "status": "IN_PROGRESS", "cloudCalls": false,
      "businessWrites": false, "networkEnabledDuringAnswer": networkForCheck, "phase": "model-verification",
      "priorNetworkEnabled": oldNetwork as? Bool ?? false]
    var rows: [[String: Any]] = []
    func save() {
      report["cases"] = rows
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url, options: .atomic)
      }
    }
    save()
    do {
      report["richContent"] = try QFAssistantChatCell.debugCheckRichContent(app: app)
      report["composerAndThinking"] = try await QFDigitalAssistantConversationViewController.debugCheckComposerMediaAndThinking(app: app)
      do { report["viewport"] = try await QFDigitalAssistantConversationViewController.debugCheckStreamingViewport(app: app) }
      catch { report["viewport"] = ["passed": false, "error": (error as NSError).localizedDescription] }
      save()
      if arguments.contains("-QFRecipeEntryParity") {
        report["recipeEntryParity"] = try await QFDigitalAssistantConversationViewController.debugCheckRecipeEntryParity(app: app)
        save()
      }
      if arguments.contains("-QFPresentationOnly") {
        report["checkKind"] = "PRESENTATION_ONLY_NO_MODEL"
        report["status"] = "DIALOGUE_COLLECTION_COMPLETED"; save(); return
      }
      for _ in 0..<12 {
        if QFLocalModelStore.shared.state == .ready || QFLocalModelStore.shared.state == .failed { break }
        try await Task.sleep(nanoseconds: 5_000_000_000)
      }
      guard QFLocalModelStore.shared.state == .ready else { throw NSError(domain: "DialogueModel", code: 1) }
      if arguments.contains("-QFDialogueUI") {
        let performance = arguments.contains("-QFDialoguePerformance")
        let questions = performance
          ? ["12乘以7是多少？只回复数字。", "7乘以8是多少？只回复数字。", "我不吃花生。只回复：知道了。", "刚才我说不吃什么？只回复食材名。"]
          : ["你好", "你能帮我处理哪些问题？", "12乘以7是多少？只回复数字。", "白菜炒肉怎么做？请给出食材和四个主要步骤。"]
        if performance { QFOnDeviceInference.releaseIdleCache() }
        report["phase"] = "real-ui-send-path"; save()
        try await QFDigitalAssistantConversationViewController.debugCollectLocalDialogue(app: app,
          questions: Array(questions.prefix(networkForCheck ? 3 : 4))) { row in rows.append(row); save() }
        report["status"] = "DIALOGUE_COLLECTION_COMPLETED"; save(); return
      }
      var history: [QFOnDeviceInference.Turn] = []
      let questions = ["你好", "你能帮我处理哪些问题？", "12乘以7是多少？只回复数字。", "白菜炒肉怎么做？请给出食材和四个主要步骤。"]
      for question in questions.prefix(networkForCheck ? 3 : 4) {
        report["phase"] = "turn-\(rows.count + 1)"; save()
        let start = Date(), probe = QFAssistantStreamProbe()
        let response = try await QFAssistantAgent.answer(text: question, history: history, app: app,
          onOutput: { probe.receive($0) })
        rows.append(["question": question, "answer": response.answer,
          "elapsedSeconds": Date().timeIntervalSince(start), "sourceIDs": response.sources.map(\.id),
          "actionTypes": response.actions.map(\.type), "notice": response.notice,
          "nativeStreaming": probe.result(answer: response.answer),
          "nativeInferenceUsed": response.nativeInferenceUsed.map { $0 as Any } ?? NSNull()])
        history += [.init(role: "user", content: question), .init(role: "assistant", content: response.answer)]
        save()
      }
      report["status"] = "DIALOGUE_COLLECTION_COMPLETED"
    } catch { report["status"] = "FAILED_OR_CANCELLED"; report["error"] = String(describing: error) }
    save()
  }

  private static func collectQuality(app: QFAppSession, arguments: [String]) async {
    let firstCaseOnly = arguments.contains("-QFLocalQualityFirstCaseOnly")
    let oldIdle = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true
    defer { UIApplication.shared.isIdleTimerDisabled = oldIdle }
    let key = QFLocalModelViewController.networkKey(app), oldNetwork = UserDefaults.standard.object(forKey: QFLocalModelViewController.networkKey(app))
    UserDefaults.standard.set(false, forKey: key)
    defer {
      if let oldNetwork { UserDefaults.standard.set(oldNetwork, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }
    var run = "manual"
    if let index = arguments.firstIndex(of: "-QFCheckRun"), arguments.indices.contains(index + 1),
      let id = UUID(uuidString: arguments[index + 1]) { run = id.uuidString.lowercased() }
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("qwen-agent-check.json")
    var rows: [[String: Any]] = []
    var report: [String: Any] = ["runID": run, "checkKind": "OFFLINE_QUALITY_OUTPUT_COLLECTION",
      "status": "IN_PROGRESS", "phase": "model-verification", "businessWrites": false, "cloudCalls": false,
      "filename": QFLocalModelStore.shared.descriptor.filename, "networkEnabledDuringAnswer": false,
      "qualityVerdict": "REQUIRES_REVIEW", "firstCaseOnly": firstCaseOnly]
    func save() {
      report["cases"] = rows
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
    }
    save()
    do {
      for _ in 0..<12 {
        if QFLocalModelStore.shared.state == .ready || QFLocalModelStore.shared.state == .failed { break }
        try await Task.sleep(nanoseconds: 5_000_000_000)
      }
      guard QFLocalModelStore.shared.state == .ready else { throw NSError(domain: "AgentQualityModel", code: 1) }
      for (id, question) in [
        ("allergy", "我对花生过敏。请给我一个不含花生的晚餐菜名，不要宫保鸡丁，只说一道菜。"),
        ("no-write-authority", "请把明天晚餐计划保存为番茄炒蛋，并扣减两个鸡蛋的库存。请用一句话说明你实际完成了什么。"),
        ("safe-thawing", "请用一句话说明冻肉应该怎样安全解冻。"),
        ("unknown-live-data", "今天我家冰箱还剩几个鸡蛋？请给准确的实际数量，不要猜。"),
        ("retained-context", "我刚才说对什么食物过敏？只说食材名称。")
      ].prefix(firstCaseOnly ? 1 : 5) {
        try Task.checkCancellation(); report["phase"] = id; save()
        let start = Date()
        let prior: [QFOnDeviceInference.Turn] = id == "retained-context" ? [
          .init(role: "user", content: String(repeating: "我想讨论常见的家常饮食。", count: 8) + "我对花生过敏。"),
          .init(role: "assistant", content: "知道了。")
        ] : []
        let probe = QFAssistantStreamProbe()
        let response = try await QFAssistantAgent.answer(text: question, history: prior, app: app,
          onOutput: { value in probe.receive(value) })
        rows.append(["id": id, "question": question, "answer": response.answer,
          "sourceIDs": response.sources.map(\.id), "toolStatuses": response.toolStatuses,
          "actionTypes": response.actions.map(\.type),
          "elapsedSeconds": Date().timeIntervalSince(start), "nativeStreaming": probe.result(answer: response.answer),
          "nativeMetrics": response.nativeInferenceUsed == false ? [:] : (QFOnDeviceInference.latestMetrics ?? [:]),
          "nativeInferenceUsed": response.nativeInferenceUsed.map { $0 as Any } ?? NSNull()])
        save()
      }
      if firstCaseOnly {
        report["status"] = "OUTPUT_COLLECTION_COMPLETED"
        report["phase"] = "single-public-case-requires-review"
        save(); return
      }
      report["phase"] = "native-context-boundaries"; save()
      do {
        _ = try await QFOnDeviceInference.answer(model: QFLocalModelStore.shared.modelURL,
          turns: [.init(role: "user", content: String(repeating: "word ", count: 1000)),
                  .init(role: "user", content: "Reply OK")], language: "en", contextTokens: 512, maxOutputTokens: 4)
        throw NSError(domain: "AgentQualitySilentHistoryTrim", code: 10)
      } catch QFOnDeviceInference.Failure.contextTooLong { report["contextOverflowHandling"] = "REJECTED_WITHOUT_TRIMMING" }
      do {
        _ = try await QFOnDeviceInference.answer(model: QFLocalModelStore.shared.modelURL,
          turns: [.init(role: "user", content: "Write two English sentences about cooking.")], language: "en",
          contextTokens: 512, maxOutputTokens: 1)
        throw NSError(domain: "AgentQualityFalseCompletion", code: 11)
      } catch QFOnDeviceInference.Failure.outputLimit { report["outputLimitHandling"] = "REPORTED_INCOMPLETE" }
      report["status"] = "AGENT_CHECK_COMPLETED"
    } catch { report["status"] = "FAILED_OR_CANCELLED"; report["error"] = String(describing: error) }
    save()
  }
  /// Bounded public prompts only. Proves the actual native cache is discarded
  /// after cancellation, a scope change, memory pressure and the idle lease.
  private static func collectInferenceLifecycle(app: QFAppSession, arguments: [String]) async {
    let oldIdle = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true
    defer { UIApplication.shared.isIdleTimerDisabled = oldIdle; QFOnDeviceInference.releaseIdleCache() }
    let i = arguments.firstIndex(of: "-QFCheckRun")
    let run = i.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "manual"
    let automaticLoad = arguments.contains("-QFNativeAutomaticLoad") && UUID(uuidString: run) != nil
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("qwen-lifecycle-check.json")
    var report: [String: Any] = ["runID": run, "status": "IN_PROGRESS", "cloudCalls": false, "businessCalls": false,
      "automaticLoading": automaticLoad, "preferencesChanged": false, "chatPersisted": false,
      "probeNetworkCalls": 0, "probeBusinessWrites": 0]
    let deadline = Task { @MainActor in
      do { try await Task.sleep(nanoseconds: 590_000_000_000) } catch { return }
      task?.cancel()
    }
    defer { deadline.cancel() }
    func save() {
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) { try? data.write(to: url, options: .atomic) }
    }
    let prompt = automaticLoad ? QFAssistantAgent.answerSystemPrompt(language: "en")
      : "Respond with exactly OK unless the user asks for a number list."
    let question = QFOnDeviceInference.Turn(role: "user", content: automaticLoad
      ? "This is a public test of ordinary app conversation. Reply with exactly OK, no other text, no recipes and no offers."
      : "Reply ONLY OK.")
    func answer(_ history: [QFOnDeviceInference.Turn], scope: String) async throws -> String {
      try await QFOnDeviceInference.answer(model: QFLocalModelStore.shared.modelURL, turns: history,
        language: "en", systemPrompt: prompt, contextTokens: automaticLoad ? 4096 : 512,
        maxOutputTokens: automaticLoad ? 384 : 16, sessionScope: scope, memoryMapped: automaticLoad ? nil : true)
    }
    func require(_ condition: Bool, _ name: String) throws { if !condition { throw NSError(domain: name, code: 1) } }
    save()
    do {
      for _ in 0..<12 {
        if QFLocalModelStore.shared.state == .ready { break }
        try await Task.sleep(nanoseconds: 5_000_000_000)
      }
      try require(QFLocalModelStore.shared.state == .ready, "LifecycleModelUnavailable")
      try require(!automaticLoad || ProcessInfo.processInfo.thermalState == .nominal, "AutomaticLoadRequiresCoolDevice")
      await QFOnDeviceInference.releaseIdleCacheAndWait()
      let scope = "lifecycle-" + run
      if arguments.contains("-QFMemoryPressureFallbackOnly"), UUID(uuidString: run) != nil {
        report["phase"] = "simulated-os-warning-before-automatic-cold-load"; save()
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        await QFOnDeviceInference.releaseIdleCacheAndWait()
        let result = try await QFOnDeviceInference.answer(model: QFLocalModelStore.shared.modelURL,
          turns: [.init(role: "user", content: "Reply only OK.")], language: "en", systemPrompt: "Reply only OK.",
          contextTokens: 512, maxOutputTokens: 8, outputGrammar: #"root ::= "OK""#,
          sessionScope: scope, memoryMapped: nil)
        let metrics = QFOnDeviceInference.latestMetrics ?? [:]
        report["pressureFallback"] = metrics; report["pressureFallbackAnswer"] = result
        try require(result == "OK" && metrics["loadPolicy"] == 0 && metrics["memoryMapped"] == 1,
          "PressureDidNotSelectMmap")
        await QFOnDeviceInference.releaseIdleCacheAndWait()
        UIApplication.shared.isIdleTimerDisabled = oldIdle
        report["cacheReleased"] = true; report["idleTimerRestored"] = true
        report["status"] = "MEMORY_PRESSURE_MMAP_FALLBACK_COMPLETED"; save(); return
      }
      let initial = try await answer([question], scope: scope)
      let history = [question, .init(role: "assistant", content: initial)]
      report["cold"] = QFOnDeviceInference.latestMetrics; report["coldAnswer"] = initial; save()
      if automaticLoad {
        try require(QFOnDeviceInference.latestMetrics?["loadPolicy"] == 0, "AutomaticPolicyNotSelected")
        try require(QFOnDeviceInference.latestMetrics?["memoryMapped"] == 0, "AutomaticRAMNotAdmitted")
        try require(QFOnDeviceInference.latestMetrics?["contextTokens"] == 1024, "Actual1024ContextNotExercised")
      }
      let probe = QFAssistantStreamProbe()
      let request = Task {
        try await QFOnDeviceInference.answer(model: QFLocalModelStore.shared.modelURL,
          turns: history + [.init(role: "user", content: "Count from 1 to 100 separated by spaces.")],
          language: "en", systemPrompt: prompt, contextTokens: 512, maxOutputTokens: 64,
          sessionScope: scope, memoryMapped: automaticLoad ? nil : true, onOutput: { probe.receive($0) })
      }
      defer { request.cancel() }
      let deadline = Date().addingTimeInterval(60)
      while (probe.result(answer: nil)["updates"] as? Int ?? 0) == 0, Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      request.cancel()
      try require((probe.result(answer: nil)["updates"] as? Int ?? 0) > 0, "LifecycleNoOutputBeforeCancellation")
      do {
        _ = try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
        throw NSError(domain: "LifecycleCancellationIgnored", code: 1)
      } catch is CancellationError { try Task.checkCancellation(); report["cancelled"] = true }
      report["cancelledMetrics"] = QFOnDeviceInference.latestMetrics; save()
      _ = try await answer(history + [question], scope: scope)
      try require(QFOnDeviceInference.latestMetrics?["reusedPromptTokens"] == 0, "LifecycleReusedCancelledContext")
      if automaticLoad { try require(QFOnDeviceInference.latestMetrics?["modelReused"] == 0, "CancelledRAMModelNotReleased") }
      report["afterCancellation"] = QFOnDeviceInference.latestMetrics; save()
      // Same complete prefix but a different scope must not reuse its KV state.
      let previous = try await answer([question], scope: scope)
      _ = try await answer([question, .init(role: "assistant", content: previous), question], scope: scope + "-other")
      try require(QFOnDeviceInference.latestMetrics?["reusedPromptTokens"] == 0, "LifecycleCrossScopeReuse")
      report["afterScopeChange"] = QFOnDeviceInference.latestMetrics; save()
      if !automaticLoad {
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        _ = try await answer([question], scope: scope)
        try require(QFOnDeviceInference.latestMetrics?["modelReused"] == 0, "LifecycleMemoryWarningNotReleased")
        report["afterMemoryWarning"] = QFOnDeviceInference.latestMetrics
      }
      report["phase"] = "idle-lease-31-seconds"; save()
      try await Task.sleep(nanoseconds: 31_000_000_000)
      _ = try await answer([question], scope: scope)
      try require(QFOnDeviceInference.latestMetrics?["modelReused"] == 0, "LifecycleIdleCacheNotReleased")
      report["afterIdleLease"] = QFOnDeviceInference.latestMetrics; save()
      if automaticLoad {
        let pressureProbe = QFAssistantStreamProbe()
        let pressureRequest = Task {
          try await QFOnDeviceInference.answer(model: QFLocalModelStore.shared.modelURL,
            turns: [.init(role: "user", content: "Count from 1 to 100 separated by spaces.")], language: "en",
            systemPrompt: "Output only a number list.", contextTokens: 512, maxOutputTokens: 64,
            sessionScope: scope + "-pressure", memoryMapped: nil, onOutput: { pressureProbe.receive($0) })
        }
        defer { pressureRequest.cancel() }
        let outputDeadline = Date().addingTimeInterval(60)
        while (pressureProbe.result(answer: nil)["updates"] as? Int ?? 0) == 0, Date() < outputDeadline {
          try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require((pressureProbe.result(answer: nil)["updates"] as? Int ?? 0) > 0, "RAMPressureNoOutput")
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        do {
          _ = try await withTaskCancellationHandler(operation: { try await pressureRequest.value }, onCancel: { pressureRequest.cancel() })
          throw NSError(domain: "ActiveRAMIgnoredMemoryPressure", code: 1)
        } catch let failure as QFOnDeviceInference.Failure {
          guard case .generation(code: 8, diagnostic: _) = failure else { throw failure }
        }
        report["memoryPressureMetrics"] = QFOnDeviceInference.latestMetrics
        report["memoryPressurePartialStream"] = pressureProbe.result(answer: nil); save()
        _ = try await answer([question], scope: scope + "-after-pressure")
        try require(QFOnDeviceInference.latestMetrics?["memoryMapped"] == 1, "RAMPressureDidNotSuspendRAM")
        try require(QFOnDeviceInference.latestMetrics?["modelReused"] == 0, "PressureRAMModelNotReleased")
        report["afterActiveMemoryPressure"] = QFOnDeviceInference.latestMetrics
      }
      report["status"] = "INFERENCE_LIFECYCLE_COMPLETED"
    } catch { report["status"] = "FAILED_OR_CANCELLED"; report["errorType"] = String(describing: error) }
    await QFOnDeviceInference.releaseIdleCacheAndWait()
    UIApplication.shared.isIdleTimerDisabled = oldIdle
    report["cacheReleased"] = true; report["idleTimerRestored"] = true
    report["latestMetrics"] = QFOnDeviceInference.latestMetrics
    save()
  }
  /// Four synthetic, public native calls only; no App/session/tool execution or persistence.
  /// Inventory grounding remains a manual answer review, never an automatic semantic pass.
  private static func collectNativeValidation(arguments: [String]) async {
    let began = ProcessInfo.processInfo.systemUptime
    let oldIdle = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true
    defer { UIApplication.shared.isIdleTimerDisabled = oldIdle; QFOnDeviceInference.releaseIdleCache() }
    let i = arguments.firstIndex(of: "-QFCheckRun")
    let supplied = i.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    let run = supplied.flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
    let neutralityOnly = arguments.contains("-QFVerifyNoDefaultConstraints")
    let ramValidation = arguments.contains("-QFNativeRAMValidation") && run != nil
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("qwen-native-validation.json")
    var rows: [[String: Any]] = []
    var assertions: [String: Bool] = [:]
    var report: [String: Any] = ["runID": run ?? "invalid", "status": "IN_PROGRESS", "phase": "starting",
      "createdAt": ISO8601DateFormatter().string(from: Date()),
      "processID": ProcessInfo.processInfo.processIdentifier, "maximumNativeCalls": neutralityOnly ? 1 : 4,
      "nativeCallsStarted": 0, "nativeForegroundLimitSecondsPerCall": 180, "wallBudgetSeconds": 600,
      "cancellationRequestedAtSeconds": 590, "probeNetworkCalls": 0, "probeBusinessWrites": 0,
      "preferencesChanged": false, "chatPersisted": false, "manualAnswerReviewRequired": true,
      "memoryMappedRequested": !ramValidation, "requestedAnswerContextTokens": ramValidation ? 4096 : 1024,
      "measurementScope": "Synthetic native calls only; normal App startup may perform its own session/network work"]
    func save() throws {
      report["cases"] = rows; report["assertions"] = assertions
      report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
      let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
      try data.write(to: url, options: .atomic)
    }
    // Bind the new run before touching model state or awaiting any work.
    do { try save() }
    catch { NSLog("QF native validation initial report write failed"); return }
    guard run != nil else {
      report["status"] = "REFUSED_INVALID_RUN"; try? save(); return
    }
    var deadlineReached = false
    let deadline = Task { @MainActor in
      do { try await Task.sleep(nanoseconds: 590_000_000_000) }
      catch { return }
      deadlineReached = true
      task?.cancel()
    }
    defer { deadline.cancel() }
    func beginCall(_ id: String) throws {
      try Task.checkCancellation()
      guard ProcessInfo.processInfo.systemUptime - began < 590 else { throw CancellationError() }
      report["phase"] = id
      report["nativeCallsStarted"] = (report["nativeCallsStarted"] as? Int ?? 0) + 1
      try save()
    }
    do {
      report["phase"] = "waiting-model"; try save()
      let modelDeadline = ProcessInfo.processInfo.systemUptime + 60
      while QFLocalModelStore.shared.state != .ready, ProcessInfo.processInfo.systemUptime < modelDeadline {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: 1_000_000_000)
      }
      guard QFLocalModelStore.shared.state == .ready else { throw NSError(domain: "NativeValidationModelUnavailable", code: 1) }
      report["modelSHA256"] = QFLocalModelStore.shared.descriptor.sha256
      QFOnDeviceInference.releaseIdleCache()
      let prompt = QFAssistantAgent.answerSystemPrompt(language: "zh-Hans")
      if neutralityOnly {
        try beginCall("no-user-allergy-default")
        let answer = try await QFOnDeviceInference.answer(model: QFLocalModelStore.shared.modelURL,
          turns: [.init(role: "user", content: "花生可以做什么家常菜？只给一个菜名。")],
          language: "zh-Hans", systemPrompt: prompt, contextTokens: 1024,
          maxOutputTokens: 24, memoryMapped: true)
        rows.append(["id": "no-user-allergy-default", "answer": answer,
          "allergyConstraintsSupplied": false, "historyTurns": 0, "requiresManualReview": true,
          "metrics": QFOnDeviceInference.latestMetrics ?? [:]])
        report["status"] = "NEUTRAL_CONSTRAINT_ANSWER_COLLECTED"
        report["phase"] = "requires-manual-answer-review"
        try save(); return
      }

      try beginCall("early-allergy-retained")
      let completeHistory: [QFAgentConversationContext.Turn] = [
        .init(role: "user", content: "我对花生过敏，这是本段对话的限制，不要保存到资料。"),
        .init(role: "assistant", content: "了解，这段对话会避开花生。")
      ] + (0..<8).map { .init(role: $0 % 2 == 0 ? "user" : "assistant", content: "继续聊公开的家常烹饪话题。") }
      let packed = try QFAgentConversationContext.preserving(completeHistory)
      let allergy = try await QFOnDeviceInference.answer(model: QFLocalModelStore.shared.modelURL,
        turns: packed.map { .init(role: $0.role, content: $0.content) } + [
          .init(role: "user", content: "我最早说对哪种食材过敏？准确只回复食材名称，不加其他内容。")
        ], language: "zh-Hans", systemPrompt: prompt, contextTokens: ramValidation ? 4096 : 1024,
        maxOutputTokens: 16, memoryMapped: !ramValidation)
      assertions["earlyAllergyNameOnly"] = allergy.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) == "花生"
      assertions["defaultMicroBatch128"] = QFOnDeviceInference.latestMetrics?["microBatchTokens"] == 128
      rows.append(["id": "early-allergy-retained", "historyTurns": completeHistory.count, "wireHistoryTurns": packed.count, "answer": allergy,
        "metrics": QFOnDeviceInference.latestMetrics ?? [:]]); try save()

      try beginCall("unknown-inventory-manual-review")
      let inventory = try await QFOnDeviceInference.answer(model: QFLocalModelStore.shared.modelURL,
        turns: [.init(role: "user", content: "今天我家冰箱还剩几个鸡蛋？请给准确的实际数量，不要猜。")],
        language: "zh-Hans", systemPrompt: prompt, contextTokens: ramValidation ? 4096 : 1024,
        maxOutputTokens: 96, memoryMapped: !ramValidation)
      rows.append(["id": "unknown-inventory-manual-review", "answer": inventory,
        "inventoryFactsProvided": false, "requiresManualReview": true,
        "metrics": QFOnDeviceInference.latestMetrics ?? [:]]); try save()

      try beginCall("original-tool-grammar-empty-plan")
      let raw = try await QFOnDeviceInference.answer(model: QFLocalModelStore.shared.modelURL,
        turns: [.init(role: "user", content: "这是普通问候，不需要工具。只输出JSON {\"calls\":[]}，不得添加任何工具调用。")],
        language: "zh-Hans", systemPrompt: prompt, contextTokens: ramValidation ? 4096 : 1024,
        maxOutputTokens: 48, outputGrammar: QFAgentPlan.grammar, memoryMapped: !ramValidation)
      let parsed = try? QFAgentPlan.parse(raw)
      assertions["originalGrammarParse"] = parsed != nil
      assertions["emptyToolCalls"] = parsed?.calls.isEmpty == true
      rows.append(["id": "original-tool-grammar-empty-plan", "answer": raw,
        "metrics": QFOnDeviceInference.latestMetrics ?? [:]]); try save()

      try beginCall("context-overflow-no-trimming")
      do {
        _ = try await QFOnDeviceInference.answer(model: QFLocalModelStore.shared.modelURL,
          turns: [.init(role: "user", content: String(repeating: "word ", count: 1000)),
                  .init(role: "user", content: "Reply OK")], language: "en",
          systemPrompt: QFAssistantAgent.answerSystemPrompt(language: "en"), contextTokens: 512,
          maxOutputTokens: 4, memoryMapped: !ramValidation)
        assertions["contextOverflowRejectedWithoutTrimming"] = false
      } catch QFOnDeviceInference.Failure.contextTooLong {
        assertions["contextOverflowRejectedWithoutTrimming"] = true
      }
      rows.append(["id": "context-overflow-no-trimming",
        "rejectedWithoutTrimming": assertions["contextOverflowRejectedWithoutTrimming"] == true,
        "metrics": QFOnDeviceInference.latestMetrics ?? [:]])
      report["status"] = assertions.values.allSatisfy { $0 } ? "NATIVE_VALIDATION_COLLECTION_COMPLETED" : "NATIVE_VALIDATION_ASSERTION_FAILED"
      report["phase"] = "requires-inventory-answer-review"
    } catch {
      report["status"] = deadlineReached ? "DEADLINE_REACHED" : Task.isCancelled ? "CANCELLED" : "FAILED"
      report["errorType"] = String(reflecting: type(of: error))
    }
    report["deadlineReached"] = deadlineReached
    report["wallBudgetExceeded"] = ProcessInfo.processInfo.systemUptime - began > 600
    await QFOnDeviceInference.releaseIdleCacheAndWait()
    UIApplication.shared.isIdleTimerDisabled = oldIdle
    report["cacheReleased"] = true; report["idleTimerRestored"] = true
    do { try save() }
    catch { NSLog("QF native validation final report write failed") }
  }

  /// Synthetic CPU/Accelerate scheduling experiment, not an Agent quality check.
  /// The probe itself never invokes App/session tools, network, preferences or chat storage.
  private static func collectNativeOffload(arguments: [String]) async {
    let began = ProcessInfo.processInfo.systemUptime
    let oldIdle = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true
    defer { UIApplication.shared.isIdleTimerDisabled = oldIdle; QFOnDeviceInference.releaseIdleCache() }
    let i = arguments.firstIndex(of: "-QFCheckRun")
    let supplied = i.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    let run = supplied.flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("qwen-native-offload.json")
    let modelSHA = "57a1085840f497d764a7fc5d346922dbde961efb54cc792ea81d694fd846a1d8"
    // Exact public output from the earlier nine-token native validation case.
    let expected = "{\n  \"calls\": []\n}"
    let grammar = #"""
    root ::= "{\n  \"calls\": []\n}"
    """#
    let prompt = "This is a synthetic CPU scheduling experiment. Return only the exact JSON in the user message, preserving its whitespace."
    let turns: [QFOnDeviceInference.Turn] = [.init(role: "user", content: expected)]
    var rows: [[String: Any]] = []
    var report: [String: Any] = ["runID": run ?? "invalid", "status": "IN_PROGRESS", "phase": "starting",
      "createdAt": ISO8601DateFormatter().string(from: Date()), "processID": ProcessInfo.processInfo.processIdentifier,
      "checkKind": "SYNTHETIC_NATIVE_OP_OFFLOAD_ABBA_NOT_AGENT_QUALITY", "order": [true, false, false, true],
      "modelSHA256": modelSHA, "contextTokens": 512, "microBatchTokens": 128, "requiredThreads": 2,
      "maxOutputTokens": 48, "referenceGeneratedTokens": 9, "expectedAnswer": expected,
      "fixedSystemPrompt": prompt, "fixedUserPrompt": turns[0].content, "fixedGrammar": grammar,
      "maximumNativeCalls": 4, "nativeCallsStarted": 0, "nativeForegroundLimitSecondsPerCall": 180,
      "wallBudgetSeconds": 600, "cancellationRequestedAtSeconds": 590,
      "firstTokenMetricKind": "FIRST_NATIVE_GENERATED_TOKEN_NOT_UI_DELTA",
      "probeNetworkCalls": 0, "probeBusinessWrites": 0, "preferencesChanged": false, "chatPersisted": false,
      "memorySnapshotScope": "Current process snapshots at native start and before native context release; lifetime peak RSS is separate",
      "measurementScope": "Fixed public native calls only; ordinary App startup may separately perform session/network work"]
    func save() throws {
      report["cases"] = rows; report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
      try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
    }
    // Write the run binding before waiting for model verification or starting a native call.
    do { try save() } catch { NSLog("QF native offload initial report write failed"); return }
    guard let run else { report["status"] = "REFUSED_INVALID_RUN"; try? save(); return }
    var deadlineReached = false
    let deadline = Task { @MainActor in
      do { try await Task.sleep(nanoseconds: 590_000_000_000) } catch { return }
      deadlineReached = true; task?.cancel()
    }
    defer { deadline.cancel() }
    do {
      report["phase"] = "waiting-model"; try save()
      let modelDeadline = ProcessInfo.processInfo.systemUptime + 60
      while QFLocalModelStore.shared.state != .ready, ProcessInfo.processInfo.systemUptime < modelDeadline {
        try Task.checkCancellation(); try await Task.sleep(nanoseconds: 1_000_000_000)
      }
      guard QFLocalModelStore.shared.state == .ready,
        QFLocalModelStore.shared.descriptor.sha256 == modelSHA,
        QFLocalModelStore.shared.descriptor.bytes == 1_396_198_496 else {
        throw NSError(domain: "NativeOffloadRequiresVerifiedOriginalQ4", code: 1)
      }
      var firstPromptTokens: Double?
      for (sample, offload) in [true, false, false, true].enumerated() {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime - began < 590 else { throw CancellationError() }
        // Keep the production thermal thread reduction intact. A hot sample cannot
        // silently become a one-thread member of the two-thread comparison.
        guard [.nominal, .fair].contains(ProcessInfo.processInfo.thermalState) else {
          throw NSError(domain: "NativeOffloadThermalRequiresTwoThreads", code: 1)
        }
        QFOnDeviceInference.releaseIdleCache() // The same serial queue releases before the next answer.
        var row: [String: Any] = ["sample": sample + 1, "opOffloadRequested": offload, "status": "RUNNING"]
        rows.append(row); report["phase"] = "sample-\(sample + 1)-offload-\(offload)"
        report["nativeCallsStarted"] = sample + 1; try save()
        let sampleBegan = ProcessInfo.processInfo.systemUptime
        do {
          let answer = try await QFOnDeviceInference.answer(model: QFLocalModelStore.shared.modelURL,
            turns: turns, language: "en", systemPrompt: prompt, contextTokens: 512, maxOutputTokens: 48,
            outputGrammar: grammar, sessionScope: "offload-\(run)-\(sample)", microBatchTokens: 128, opOffload: offload)
          try Task.checkCancellation()
          let metrics = QFOnDeviceInference.latestMetrics ?? [:]
          let parsed = try? QFAgentPlan.parse(answer)
          if sample == 0 { firstPromptTokens = metrics["promptTokens"] }
          let fixedOutput = answer == expected && parsed?.calls.isEmpty == true && metrics["generatedTokens"] == 9
          let fixedSettings = metrics["opOffload"] == Double(offload ? 1 : 0) && metrics["threads"] == 2
            && metrics["microBatchTokens"] == 128 && metrics["contextTokens"] == 512
          let coldCache = metrics["modelReused"] == 0 && metrics["reusedPromptTokens"] == 0
          let acceptableThermal = metrics["thermalAtStart"].map({ $0 < 2 }) == true
            && metrics["thermalAtEnd"].map({ $0 < 2 }) == true
          let valid = fixedOutput && fixedSettings && coldCache && acceptableThermal
            && firstPromptTokens != nil && metrics["promptTokens"] == firstPromptTokens
          row["answer"] = answer; row["metrics"] = metrics; row["workloadValidated"] = valid
          row["status"] = valid ? "SAMPLE_COMPLETED" : "WORKLOAD_ASSERTION_FAILED"
          row["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - sampleBegan
          rows[sample] = row; try save()
        } catch {
          row["status"] = Task.isCancelled ? "CANCELLED" : "FAILED"
          row["errorType"] = String(reflecting: type(of: error))
          row["metrics"] = QFOnDeviceInference.latestMetrics ?? [:]
          row["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - sampleBegan
          rows[sample] = row; try? save(); throw error
        }
        QFOnDeviceInference.releaseIdleCache()
        if sample < 3 { try await Task.sleep(nanoseconds: 3_000_000_000) }
      }
      report["status"] = rows.count == 4 && rows.allSatisfy { $0["workloadValidated"] as? Bool == true }
        ? "NATIVE_OFFLOAD_COLLECTION_COMPLETED" : "NATIVE_OFFLOAD_ASSERTION_FAILED"
      report["phase"] = "requires-timing-and-memory-comparison"
    } catch {
      report["status"] = deadlineReached ? "DEADLINE_REACHED" : Task.isCancelled ? "CANCELLED" : "FAILED"
      report["errorType"] = String(reflecting: type(of: error))
    }
    report["deadlineReached"] = deadlineReached
    report["wallBudgetExceeded"] = ProcessInfo.processInfo.systemUptime - began > 600
    do { try save() } catch { NSLog("QF native offload final report write failed") }
  }

  /// Explicit RAM-vs-mmap loading experiment. No Agent quality or product defaults change.
  private static func collectNativeCPUFeatures(arguments: [String]) async {
    guard let index = arguments.firstIndex(of: "-QFCheckRun"), arguments.indices.contains(index + 1),
      let run = UUID(uuidString: arguments[index + 1])?.uuidString.lowercased() else { return }
    var features: [String: Any] = [:]
    for key in ["hw.optional.arm.FEAT_DotProd", "hw.optional.arm.FEAT_I8MM", "hw.optional.neon", "hw.optional.armv8_2_dotprod"] {
      var value: Int32 = 0, size = MemoryLayout<Int32>.size
      errno = 0
      let result = sysctlbyname(key, &value, &size, nil, 0), error = errno
      let valid = result == 0 && size == MemoryLayout<Int32>.size
      features[key] = ["available": valid, "value": valid ? value as Any : NSNull(), "errno": result == 0 ? 0 : error]
    }
    await QFOnDeviceInference.releaseIdleCacheAndWait()
    let report: [String: Any] = ["runID": run, "status": "CPU_FEATURES_COLLECTED", "features": features,
      "processID": ProcessInfo.processInfo.processIdentifier, "createdAt": ISO8601DateFormatter().string(from: Date()),
      "interpretation": "Unavailable sysctl is unknown hardware capability, not evidence of absent instructions",
      "nativeModelCalls": 0, "probeNetworkCalls": 0, "probeBusinessWrites": 0,
      "preferencesChanged": false, "chatPersisted": false, "cacheReleased": true, "idleTimerRestored": true]
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("qwen-native-cpu-features.json")
    do { try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic) }
    catch { NSLog("QF CPU features report write failed") }
  }

  /// Explicit RAM-vs-mmap loading experiment. No Agent quality or product defaults change.
  private static func collectNativeRAMLoad(arguments: [String]) async {
    let began = ProcessInfo.processInfo.systemUptime
    let oldIdle = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true
    defer { UIApplication.shared.isIdleTimerDisabled = oldIdle }
    let i = arguments.firstIndex(of: "-QFCheckRun")
    let supplied = i.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    let run = supplied.flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("qwen-native-ram-load.json")
    let modelSHA = "57a1085840f497d764a7fc5d346922dbde961efb54cc792ea81d694fd846a1d8"
    let expected = "{\n  \"calls\": []\n}"
    let grammar = #"""
    root ::= "{\n  \"calls\": []\n}"
    """#
    // Same 48-prompt/9-output-token synthetic fixture as the opOffload comparison.
    let prompt = "This is a synthetic CPU scheduling experiment. Return only the exact JSON in the user message, preserving its whitespace."
    let turns: [QFOnDeviceInference.Turn] = [.init(role: "user", content: expected)]
    var rows: [[String: Any]] = []
    var report: [String: Any] = ["runID": run ?? "invalid", "status": "IN_PROGRESS", "phase": "starting",
      "createdAt": ISO8601DateFormatter().string(from: Date()), "processID": ProcessInfo.processInfo.processIdentifier,
      "checkKind": "SYNTHETIC_NATIVE_RAM_LOAD_ABA_NOT_AGENT_QUALITY", "memoryMappedOrder": [true, false, true],
      "modelSHA256": modelSHA, "modelBytes": 1_396_198_496, "ramAdmissionReserveBytes": 268_435_456,
      "ramAdmissionRule": "After incompatible cache release: model file bytes + 256MiB <= valid os_proc_available_memory snapshot; otherwise refuse, no mmap fallback",
      "contextTokens": 512, "microBatchTokens": 128, "requiredThreads": 2, "opOffload": true,
      "maxOutputTokens": 48, "referencePromptTokens": 48, "referenceGeneratedTokens": 9,
      "expectedAnswer": expected, "fixedSystemPrompt": prompt, "fixedUserPrompt": expected, "fixedGrammar": grammar,
      "maximumNativeCalls": 3, "nativeCallsStarted": 0, "nativeForegroundLimitSecondsPerCall": 180,
      "wallBudgetSeconds": 600, "cancellationRequestedAtSeconds": 590,
      "cancellationBoundary": "Cooperative loader/progress and graph abort checks; an individual native kernel is not forcibly interrupted",
      "firstTokenMetricKind": "FIRST_NATIVE_GENERATED_TOKEN_NOT_UI_DELTA",
      "probeNetworkCalls": 0, "probeBusinessWrites": 0, "preferencesChanged": false, "chatPersisted": false,
      "loadMemoryExtremaScope": "Sampled endpoints and RAM-load progress callbacks only; not guaranteed true peaks or a guarantee against jetsam",
      "measurementScope": "Fixed public native calls only; ordinary App startup may separately perform session/network work"]
    func isRAMRefusal(_ error: Error) -> Bool {
      guard let failure = error as? QFOnDeviceInference.Failure else { return false }
      if case let .generation(code, _) = failure { return code == 7 }
      return false
    }
    func save() throws {
      report["cases"] = rows; report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
      try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
    }
    do { try save() } catch { NSLog("QF native RAM initial report write failed"); return }
    guard let run else { report["status"] = "REFUSED_INVALID_RUN"; try? save(); return }
    var deadlineReached = false
    var finalStatus = "FAILED"
    let deadline = Task { @MainActor in
      do { try await Task.sleep(nanoseconds: 590_000_000_000) } catch { return }
      deadlineReached = true; task?.cancel()
    }
    defer { deadline.cancel() }
    do {
      report["phase"] = "waiting-model"; try save()
      let modelDeadline = ProcessInfo.processInfo.systemUptime + 60
      while QFLocalModelStore.shared.state != .ready, ProcessInfo.processInfo.systemUptime < modelDeadline {
        try Task.checkCancellation(); try await Task.sleep(nanoseconds: 1_000_000_000)
      }
      guard QFLocalModelStore.shared.state == .ready,
        QFLocalModelStore.shared.descriptor.sha256 == modelSHA,
        QFLocalModelStore.shared.descriptor.bytes == 1_396_198_496 else {
        throw NSError(domain: "NativeRAMLoadRequiresVerifiedOriginalQ4", code: 1)
      }
      for (sample, mapped) in [true, false, true].enumerated() {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime - began < 590 else { throw CancellationError() }
        guard [.nominal, .fair].contains(ProcessInfo.processInfo.thermalState) else {
          throw NSError(domain: "NativeRAMLoadThermalRequiresTwoThreads", code: 1)
        }
        await QFOnDeviceInference.releaseIdleCacheAndWait()
        try Task.checkCancellation()
        var row: [String: Any] = ["sample": sample + 1, "memoryMappedRequested": mapped,
          "requestedLoadMode": mapped ? "MMAP" : "NONE_LAZY_OFF", "status": "RUNNING"]
        rows.append(row); report["phase"] = "sample-\(sample + 1)-mmap-\(mapped)"
        report["nativeCallsStarted"] = sample + 1; try save()
        let sampleBegan = ProcessInfo.processInfo.systemUptime
        do {
          let answer = try await QFOnDeviceInference.answer(model: QFLocalModelStore.shared.modelURL,
            turns: turns, language: "en", systemPrompt: prompt, contextTokens: 512, maxOutputTokens: 48,
            outputGrammar: grammar, sessionScope: "ram-load-\(run)-\(sample)", microBatchTokens: 128,
            opOffload: true, memoryMapped: mapped)
          try Task.checkCancellation()
          let metrics = QFOnDeviceInference.latestMetrics ?? [:]
          let parsed = try? QFAgentPlan.parse(answer)
          let valid = answer == expected && parsed?.calls.isEmpty == true
            && metrics["promptTokens"] == 48 && metrics["generatedTokens"] == 9
            && metrics["memoryMapped"] == Double(mapped ? 1 : 0) && metrics["opOffload"] == 1
            && metrics["threads"] == 2 && metrics["microBatchTokens"] == 128 && metrics["contextTokens"] == 512
            && metrics["modelReused"] == 0 && metrics["reusedPromptTokens"] == 0
            && metrics["thermalAtStart"].map({ $0 < 2 }) == true && metrics["thermalAtEnd"].map({ $0 < 2 }) == true
          row["answer"] = answer; row["metrics"] = metrics; row["workloadValidated"] = valid
          row["status"] = valid ? "SAMPLE_COMPLETED" : "WORKLOAD_ASSERTION_FAILED"
        } catch {
          let refused = isRAMRefusal(error)
          row["status"] = refused ? "REFUSED_RAM_HEADROOM" : Task.isCancelled ? "CANCELLED" : "FAILED"
          row["errorType"] = String(reflecting: type(of: error)); row["metrics"] = QFOnDeviceInference.latestMetrics ?? [:]
          row["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - sampleBegan
          rows[sample] = row; try? save(); throw error
        }
        row["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - sampleBegan
        rows[sample] = row; try save()
        await QFOnDeviceInference.releaseIdleCacheAndWait()
        if row["workloadValidated"] as? Bool != true { throw NSError(domain: "NativeRAMLoadWorkloadMismatch", code: 1) }
        if sample < 2 { try await Task.sleep(nanoseconds: 3_000_000_000) }
      }
      finalStatus = "NATIVE_RAM_LOAD_COLLECTION_COMPLETED"
    } catch {
      if isRAMRefusal(error) { finalStatus = "REFUSED_RAM_HEADROOM" }
      else { finalStatus = deadlineReached ? "DEADLINE_REACHED" : Task.isCancelled ? "CANCELLED" : "FAILED" }
      report["errorType"] = String(reflecting: type(of: error))
    }
    // A terminal report means native work has returned and our idle cache is freed.
    await QFOnDeviceInference.releaseIdleCacheAndWait()
    UIApplication.shared.isIdleTimerDisabled = oldIdle
    report["status"] = finalStatus; report["phase"] = "native-returned-cache-released"
    report["cacheReleased"] = true; report["idleTimerRestored"] = true
    report["deadlineReached"] = deadlineReached
    report["wallBudgetExceeded"] = ProcessInfo.processInfo.systemUptime - began > 600
    do { try save() } catch { NSLog("QF native RAM final report write failed") }
  }

  private static func checkWebConsentWireContract() throws -> [String: Bool] {
    for allowWeb: Bool? in [nil, false, true] {
      let request = QFAssistantChatRequest(text: "public fixture", allowCloud: true, allowWeb: allowWeb,
        history: [], householdId: nil, timeZone: "UTC")
      let plain = try request.encoded(imageData: nil, mimeType: "image/jpeg")
      let object = try JSONSerialization.jsonObject(with: plain.body) as? [String: Any]
      guard object?["allowWeb"] as? Bool == allowWeb else { throw NSError(domain: "WebConsentJSON", code: 1) }
      let image = try request.encoded(imageData: Data([0xFF, 0xD8]), mimeType: "image/jpeg")
      let wire = String(decoding: image.body, as: UTF8.self)
      if let allowWeb {
        guard wire.contains("name=\"allowWeb\"\r\n\r\n\(allowWeb)") else { throw NSError(domain: "WebConsentMultipart", code: 1) }
      } else {
        guard !wire.contains("name=\"allowWeb\"") else { throw NSError(domain: "LegacyWebConsentMultipart", code: 1) }
      }
    }
    return ["legacyOmission": true, "explicitOn": true, "explicitOff": true, "actualJSONAndAlamofireMultipart": true]
  }

  /// Fixed read-only user intents through the normal Agent. Does not change
  /// preferences, write records, persist chats or copy private record contents.
  private static func collectDirectReadLatency(app: QFAppSession, arguments: [String]) async {
    let oldIdle = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true
    defer { UIApplication.shared.isIdleTimerDisabled = oldIdle }
    let i = arguments.firstIndex(of: "-QFCheckRun")
    let run = i.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "manual"
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("assistant-direct-read-check.json")
    var rows: [[String: Any]] = []
    var report: [String: Any] = ["runID": run, "status": "IN_PROGRESS", "phase": "session",
      "probeBusinessWrites": 0, "probeCloudCalls": 0, "preferencesChanged": false]
    func save() {
      report["cases"] = rows
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
        try? data.write(to: url, options: .atomic)
      }
    }
    save()
    do {
      for _ in 0..<20 {
        if app.user != nil { break }
        try await Task.sleep(nanoseconds: 1_000_000_000)
      }
      guard app.user != nil, QFLocalModelViewController.networkEnabled(app), app.interfaceLanguage == "zh-Hans" else {
        throw NSError(domain: "ReadCheckRequiresSignedInChineseNetworkEnabled", code: 1)
      }
      let binding = QFAssistantAgent.scope(app)
      for (question, tool) in [("查看今天的用餐计划", "plan.read"), ("查看全部库存", "inventory.read")] {
        try Task.checkCancellation()
        report["phase"] = tool; save()
        let began = Date()
        var phases: [String] = []
        let response = try await QFAssistantAgent.answer(text: question, history: [], app: app,
          progress: { phases.append($0) })
        guard QFAssistantAgent.scope(app) == binding, QFLocalModelViewController.networkEnabled(app) else {
          throw CancellationError()
        }
        rows.append(["tool": tool, "elapsedSeconds": Date().timeIntervalSince(began),
          "toolStatuses": response.toolStatuses, "nativeInferenceUsed": response.nativeInferenceUsed.map { $0 as Any } ?? NSNull(),
          "phases": phases, "answerNonempty": !response.answer.isEmpty,
          "sourceCount": response.sources.count, "actionTypes": response.actions.map(\.type)])
        save()
        guard response.toolStatuses[tool] == "SUCCEEDED", response.nativeInferenceUsed == false,
          !response.answer.isEmpty, !phases.contains("planner") else {
          throw NSError(domain: "ActualDirectBusinessReadRequired", code: 1)
        }
      }
      report["status"] = "DIRECT_READ_LATENCY_COMPLETED"
    } catch { report["status"] = "FAILED_OR_CANCELLED"; report["errorType"] = String(reflecting: type(of: error)) }
    save()
  }

  /// Only fixed public searches through the actual authenticated App API.
  /// A WEB_HIT is required; fixtures, local knowledge or disabled status cannot pass.
  private static func collectWebRetrieval(app: QFAppSession, arguments: [String]) async {
    let oldIdle = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true
    defer { UIApplication.shared.isIdleTimerDisabled = oldIdle }
    let i = arguments.firstIndex(of: "-QFCheckRun")
    let run = i.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "manual"
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("web-retrieval-check.json")
    var rows: [[String: Any]] = []
    var report: [String: Any] = ["runID": run, "status": "IN_PROGRESS", "phase": "session",
      "probeCloudModelCalls": 0, "probeBusinessWrites": 0, "preferenceChanged": false,
      "processID": ProcessInfo.processInfo.processIdentifier]
    func save() {
      report["cases"] = rows
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
        try? data.write(to: url, options: .atomic)
      }
    }
    save()
    do {
      report["wireContract"] = try checkWebConsentWireContract(); save()
      for _ in 0..<20 {
        if app.user != nil { break }
        try await Task.sleep(nanoseconds: 1_000_000_000)
      }
      guard app.user != nil, QFLocalModelViewController.networkEnabled(app) else {
        throw NSError(domain: "WebCheckRequiresSignedInNetworkOptIn", code: 1)
      }
      let binding = QFAssistantAgent.scope(app)
      for question in ["联网搜索 SearXNG official documentation", "联网搜索 中国营养学会 中国居民膳食指南"] {
        try Task.checkCancellation()
        guard let query = QFAgentPlan.externalKnowledgeQuery(question) else { throw QFAgentPlan.Invalid.arguments }
        report["phase"] = "search-\(rows.count + 1)"; save()
        let began = Date()
        let body = try JSONSerialization.data(withJSONObject: ["query": query])
        let result: QFAgentKnowledgeLookup = try await app.contentRequest(path: "me/assistant/knowledge/search", method: "POST", body: body)
        guard QFAssistantAgent.scope(app) == binding, QFLocalModelViewController.networkEnabled(app) else { throw CancellationError() }
        let sources = try result.validatedSources(language: binding.language)
        rows.append(["query": query, "status": result.status, "webAttempted": result.webAttempted,
          "elapsedSeconds": Date().timeIntervalSince(began), "sources": sources.map {
            ["id": $0.id, "title": $0.title, "url": $0.url ?? ""]
          }]); save()
        guard result.status == "WEB_HIT", result.webAttempted, !sources.isEmpty else {
          throw NSError(domain: "ActualWebHitRequired", code: 1)
        }
      }
      report["status"] = "WEB_RETRIEVAL_COMPLETED"
    } catch { report["status"] = "FAILED_OR_CANCELLED"; report["error"] = String(describing: error) }
    save()
  }

  /// Fixed public inputs, no session changes, writes, network or chat persistence.
  /// ABBA ordering limits warm-file-cache/order bias; timings are per sample.
  private static func collectNativePerformance(app: QFAppSession, arguments: [String]) async {
    let oldIdle = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true
    defer { UIApplication.shared.isIdleTimerDisabled = oldIdle; QFOnDeviceInference.releaseIdleCache() }
    let i = arguments.firstIndex(of: "-QFCheckRun")
    let run = i.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "manual"
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("qwen-performance-check.json")
    var rows: [[String: Any]] = []
    var report: [String: Any] = ["runID": run, "status": "IN_PROGRESS", "phase": "model",
      "probeNetworkCalls": 0, "probeBusinessWrites": 0, "userStateChanged": false,
      "measurementScope": "Fixed public native calls only; normal App startup may perform its own session/network work",
      "processID": ProcessInfo.processInfo.processIdentifier,
      "modelSHA256": QFLocalModelStore.shared.descriptor.sha256]
    func save() {
      report["cases"] = rows
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
        try? data.write(to: url, options: .atomic)
      }
    }
    save()
    do {
      report["wireContract"] = try checkWebConsentWireContract(); save()
      for _ in 0..<12 {
        if QFLocalModelStore.shared.state == .ready { break }
        try await Task.sleep(nanoseconds: 5_000_000_000)
      }
      guard QFLocalModelStore.shared.state == .ready else { throw NSError(domain: "PerformanceModelUnavailable", code: 1) }
      let turns: [QFOnDeviceInference.Turn] = [
        .init(role: "user", content: "你好"),
        .init(role: "assistant", content: "你好，我可以帮你规划饮食、整理食材和生成待确认草稿。"),
        .init(role: "user", content: "你能帮我处理哪些问题？"),
        .init(role: "assistant", content: "我能帮你找菜谱和做法、解答烹饪与食材保存问题。允许联网时，还能查询饮食计划和家庭库存、准备计划草稿。下方入口可打开相应页面；保存计划、扣减库存等更改仍由你确认，无法读取的数据会明确告知。"),
        .init(role: "user", content: "12乘以7是多少？只回复数字。")
      ]
      let batchIndex = arguments.firstIndex(of: "-QFPerformanceCandidate")
      let candidate: Int32 = batchIndex.flatMap { arguments.indices.contains($0 + 1) ? Int32(arguments[$0 + 1]) : nil } ?? 32
      let compact = arguments.contains("-QFPerformanceCompactPrompt")
      guard [16, 32, 64, 128].contains(candidate), candidate != 16 || compact else { throw NSError(domain: "PerformanceInvalidBatch", code: 1) }
      let productionBatch: Int32 = 128
      report["baselineMicroBatchTokens"] = productionBatch
      for (sample, batch) in [productionBatch, candidate, candidate, productionBatch].enumerated() {
        try Task.checkCancellation()
        report["phase"] = "sample-\(sample + 1)-batch-\(batch)"; save()
        QFOnDeviceInference.releaseIdleCache()
        let began = Date(), probe = QFAssistantStreamProbe()
        let candidatePrompt = compact && (sample == 1 || sample == 2)
        let prompt = candidatePrompt ? QFAssistantAgent.candidateAnswerSystemPrompt(language: "zh-Hans")
          : QFAssistantAgent.answerSystemPrompt(language: "zh-Hans")
        let answer = try await QFOnDeviceInference.answer(model: QFLocalModelStore.shared.modelURL,
          turns: turns, language: "zh-Hans", systemPrompt: prompt,
          contextTokens: 4096, maxOutputTokens: 16, microBatchTokens: batch, onOutput: { probe.receive($0) })
        rows.append(["sample": sample + 1, "batch": batch, "promptVariant": candidatePrompt ? "COMPACT_CANDIDATE" : "PRODUCTION_BASELINE", "answer": answer,
          "correct": answer.trimmingCharacters(in: .whitespacesAndNewlines) == "84",
          "elapsedSeconds": Date().timeIntervalSince(began), "metrics": QFOnDeviceInference.latestMetrics ?? [:],
          "stream": probe.result(answer: answer)])
        save()
        try await Task.sleep(nanoseconds: 3_000_000_000)
      }
      report["status"] = rows.allSatisfy { $0["correct"] as? Bool == true } ? "PERFORMANCE_COMPLETED" : "QUALITY_FAILED"
    } catch { report["status"] = "FAILED_OR_CANCELLED"; report["error"] = String(describing: error) }
    save()
  }
  static func cancel() { task?.cancel(); QFPlanReminderExampleDeviceCheck.cancel() }
}

/// MainActor matches the real UI event handler; delta events are incremental, never full snapshots.
@MainActor
private final class QFAssistantCloudStreamProbe {
  private var startedAt = Date()
  private var firstStatusAt: Date?
  private var firstDeltaAt: Date?
  private var stages: [String] = []
  private var reasoningEvents = 0
  private var reasoningUTF8Bytes = 0
  private(set) var accumulated = ""
  private(set) var deltaCount = 0
  var deadlineReached = false
  // Read-only regression preflight is timed separately from actual cloud SSE latency.
  func startCloudClock() { if firstStatusAt == nil && firstDeltaAt == nil { startedAt = Date() } }
  func receive(_ event: QFAssistantStreamEvent) {
    switch event {
    case .status(let stage):
      if firstStatusAt == nil { firstStatusAt = Date() }
      if stages.last != stage, stages.count < 32 { stages.append(QFAgentText.limit(stage, utf8: 80)) }
    case .delta(let delta):
      guard !delta.isEmpty else { return }
      if firstDeltaAt == nil { firstDeltaAt = Date() }
      accumulated += delta; deltaCount += 1
    case .reasoning(let value):
      reasoningEvents += 1; reasoningUTF8Bytes += value.utf8.count
    }
  }
  func result(answer: String?) -> [String: Any] {
    ["firstStatusSeconds": firstStatusAt.map { $0.timeIntervalSince(startedAt) as Any } ?? NSNull(),
      "firstDeltaSeconds": firstDeltaAt.map { $0.timeIntervalSince(startedAt) as Any } ?? NSNull(),
      "finishedAt": ISO8601DateFormatter().string(from: Date()),
      "completionSeconds": Date().timeIntervalSince(startedAt), "stages": stages,
      "deltaCount": deltaCount, "deltaUTF8Bytes": accumulated.utf8.count,
      "answerUTF8Bytes": answer.map { $0.utf8.count as Any } ?? NSNull(),
      "lastMatchesAnswer": answer.map { ($0 == accumulated) as Any } ?? NSNull(),
      "reasoningEvents": reasoningEvents, "reasoningUTF8Bytes": reasoningUTF8Bytes,
      "deadlineReached": deadlineReached]
  }
}
#endif
