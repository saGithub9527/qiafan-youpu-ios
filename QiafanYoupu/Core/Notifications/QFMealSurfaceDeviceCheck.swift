#if DEBUG
import Foundation

/// Explicit read-only device metadata check. No model requests or business mutations.
@MainActor
enum QFMealSurfaceDeviceCheck {
  static func collectIfRequested(app: QFAppSession) async {
    let args = ProcessInfo.processInfo.arguments
    guard args.contains("-QFReadMealSurfaces"), let index = args.firstIndex(of: "-QFCheckRun"),
      args.indices.contains(index + 1), let run = UUID(uuidString: args[index + 1]) else { return }
    let deadline = Date().addingTimeInterval(35)
    while Date() < deadline {
      let status = QFMealLivePushService.shared.diagnosticStatus()
      if status["deviceLeaseRegistered"] as? Bool == true,
         (status["startTokenAvailable"] as? Bool == true || status["remoteStartSupported"] as? Bool == false) { break }
      do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
    }
    var result = QFMealLivePushService.shared.diagnosticStatus()
    let coordinator = QFMealSurfaceCoordinator.shared
    result["runID"] = run.uuidString.lowercased(); result["signedIn"] = app.user != nil
    result["sharedCacheAvailable"] = coordinator.cacheAvailable
    result["mealEntryCount"] = coordinator.document?.entries.count ?? 0
    result["status"] = "READ_ONLY_MEAL_SURFACE_METADATA"; result["businessWrites"] = 0; result["modelCalls"] = 0
    let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("meal-surface-status-" + run.uuidString.lowercased() + ".json")
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
      try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
  }
}
#endif
