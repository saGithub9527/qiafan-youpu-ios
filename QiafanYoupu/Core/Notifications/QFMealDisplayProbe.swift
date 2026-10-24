#if DEBUG
import ActivityKit
import Foundation
import Security

/// One bounded, explicitly launched display probe. Never enters business data or the shared widget cache.
@MainActor
enum QFMealDisplayProbe {
  private static var binding: (scope: String, entry: String, deadline: Date)?
  @available(iOS 16.1, *)
  static func owns(_ attributes: QFMealActivityAttributes) -> Bool {
    guard let binding, Date() < binding.deadline,
      let document = QFMealSurfaceCoordinator.shared.document,
      document.status != .disabled, document.status != .signedOut else { return false }
    return document.scopeKey == binding.scope && attributes.scopeKey == binding.scope
      && attributes.entryID == binding.entry
  }

  static func runIfRequested(app: QFAppSession) async {
    let args = ProcessInfo.processInfo.arguments
    let remote = args.contains("-QFProbeRemoteMealSurfaces")
    guard (args.contains("-QFProbeMealSurfaces") || remote), #available(iOS 16.2, *),
      let index = args.firstIndex(of: "-QFCheckRun"), args.indices.contains(index + 1),
      let run = UUID(uuidString: args[index + 1]),
      let keyIndex = args.firstIndex(of: "-QFProbePublicKey"), args.indices.contains(keyIndex + 1),
      let publicDER = Data(base64Encoded: args[keyIndex + 1]),
      app.user != nil, app.api.environment.baseURL?.host == "test-api.yzsalingo.com" else { return }
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let file = folder.appendingPathComponent("meal-display-probe-" + run.uuidString.lowercased() + ".json")
    let cipherFile = folder.appendingPathComponent("meal-display-capability-" + run.uuidString.lowercased() + ".json")
    let startCipherFile = folder.appendingPathComponent("meal-display-start-capability-" + run.uuidString.lowercased() + ".json")
    var report: [String: Any] = ["runID": run.uuidString.lowercased(), "businessWrites": 0, "modelCalls": 0, "status": "WAITING_FOR_REAL_SCOPE"]
    func save() {
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      }
    }
    save()
    let wait = Date().addingTimeInterval(20)
    while QFMealSurfaceCoordinator.shared.document?.status != .empty,
      QFMealSurfaceCoordinator.shared.document?.status != .ready, Date() < wait {
      do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
    }
    guard let document = QFMealSurfaceCoordinator.shared.document,
      [.ready, .empty].contains(document.status), ActivityAuthorizationInfo().areActivitiesEnabled,
      Activity<QFMealActivityAttributes>.activities.isEmpty,
      let publicKey = SecKeyCreateWithData(publicDER as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits: 3072] as CFDictionary, nil) else {
      report["status"] = "PROBE_PRECONDITION_NOT_MET"; save(); return
    }
    let now = Date(), deadline = Date().addingTimeInterval(175)
    let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
    let entry = QFMealSurfaceEntry(id: "display-probe/" + run.uuidString.lowercased(), planID: run.uuidString.lowercased(),
      date: formatter.string(from: now), meal: "DINNER", scheduledAt: now.addingTimeInterval(120), expiresAt: deadline,
      recipeTitles: ["显示测试·未保存饮食计划"], requiredIngredients: [], inStockIngredients: [],
      missingIngredients: [], stockKnown: false, timezone: TimeZone.current.identifier)
    binding = (document.scopeKey, entry.id, deadline)
    defer {
      binding = nil; try? FileManager.default.removeItem(at: cipherFile)
      try? FileManager.default.removeItem(at: startCipherFile)
      QFMealSurfaceCoordinator.shared.refresh(force: true)
    }
    func writeCapability(_ token: Data, to target: URL) -> Bool {
      let clear = Data(token.map { String(format: "%02x", $0) }.joined().utf8)
      guard let encrypted = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA256, clear as CFData, nil) as Data? else { return false }
      let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
      guard let state = try? encoder.encode(entry), let stateObject = try? JSONSerialization.jsonObject(with: state) else { return false }
      let capability: [String: Any] = ["runID": run.uuidString.lowercased(), "ciphertext": encrypted.base64EncodedString(),
        "contentState": stateObject, "scopeKey": document.scopeKey, "entryID": entry.id]
      guard let data = try? JSONSerialization.data(withJSONObject: capability, options: [.sortedKeys]) else { return false }
      do { try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); return true }
      catch { return false }
    }
    do {
      let activity: Activity<QFMealActivityAttributes>
      if remote {
        guard #available(iOS 17.2, *) else { throw ProbeFailure.startTokenUnavailable }
        let tokenDeadline = Date().addingTimeInterval(20)
        while Activity<QFMealActivityAttributes>.pushToStartToken == nil, Date() < tokenDeadline {
          try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let token = Activity<QFMealActivityAttributes>.pushToStartToken,
          writeCapability(token, to: startCipherFile) else { throw ProbeFailure.startTokenUnavailable }
        report["status"] = "WAITING_FOR_REMOTE_START"; save()
        let startDeadline = Date().addingTimeInterval(45)
        while !Activity<QFMealActivityAttributes>.activities.contains(where: { owns($0.attributes) }), Date() < startDeadline {
          try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let started = Activity<QFMealActivityAttributes>.activities.first(where: { owns($0.attributes) }) else { throw ProbeFailure.remoteStartNotObserved }
        activity = started; report["remoteStartObserved"] = true
      } else {
        activity = try Activity.request(attributes: QFMealActivityAttributes(scopeKey: document.scopeKey, entryID: entry.id),
          content: ActivityContent(state: entry, staleDate: deadline), pushType: .token)
      }
      report["status"] = "DISPLAY_PROBE_ACTIVE"; report["systemActive"] = activity.activityState == .active; save()
      if let token = activity.pushToken, writeCapability(token, to: cipherFile) { report["capabilityEncrypted"] = true; save() }
      let tokens = Task { @MainActor in
        for await token in activity.pushTokenUpdates {
          guard !Task.isCancelled, Date() < deadline else { return }
          if writeCapability(token, to: cipherFile) { report["capabilityEncrypted"] = true; save() }
          return
        }
      }
      while Date() < deadline, owns(activity.attributes), !Task.isCancelled {
        let updated = activity.content.state.recipeTitles == ["显示检查已更新·未保存饮食计划"]
        if updated && report["remoteUpdateObserved"] as? Bool != true { report["remoteUpdateObserved"] = true; save() }
        if activity.activityState == .ended || activity.activityState == .dismissed {
          report["remoteEndObserved"] = true; break
        }
        do { try await Task.sleep(nanoseconds: 250_000_000) } catch { break }
      }
      tokens.cancel()
      await activity.end(nil, dismissalPolicy: .immediate)
      report["systemEnded"] = [.ended, .dismissed].contains(activity.activityState)
      report["status"] = "DISPLAY_PROBE_FINISHED"; save()
    } catch {
      if let failure = error as? ProbeFailure { report["probeFailure"] = String(describing: failure) }
      report["status"] = "DISPLAY_PROBE_FAILED"; report["failureType"] = String(describing: type(of: error)); save()
    }
  }
  private enum ProbeFailure: Error { case startTokenUnavailable, remoteStartNotObserved }
}
#endif
