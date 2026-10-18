#if DEBUG
import Foundation
import CryptoKit
import UIKit

/// Opt-in, fixed-input device check. Normal launches never run this or download a model.
@MainActor
enum QFLocalDeploymentCheck {
  private static var started = false
  private static var task: Task<Void, Never>?
  static func startIfRequested() {
    if !started, ProcessInfo.processInfo.arguments.contains("-QFCleanupRejectedQuantizations") {
      started = true
      task = Task { await cleanupRejectedExperiments(); task = nil }
      return
    }
    let download = ProcessInfo.processInfo.arguments.contains("-QFDownloadAndVerifyLocalModel")
    guard !started, download || ProcessInfo.processInfo.arguments.contains("-QFVerifyLocalModel") else { return }
    started = true
    task = Task {
      let idleTimer = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      defer { UIApplication.shared.isIdleTimerDisabled = idleTimer }
      let arguments = ProcessInfo.processInfo.arguments
      var run = "manual"
      if let index = arguments.firstIndex(of: "-QFCheckRun"), arguments.indices.contains(index + 1),
        let id = UUID(uuidString: arguments[index + 1]) { run = id.uuidString.lowercased() }
      var report: [String: Any] = ["model": "Qwen/Qwen3.5-2B", "backend": "llama.cpp CPU",
        "runID": run,
        "system": ProcessInfo.processInfo.operatingSystemVersionString,
        "createdAt": ISO8601DateFormatter().string(from: Date())]
      let started = Date()
      let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("qwen-deployment-check.json")
      func save() {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
          try? data.write(to: url, options: .atomic)
        }
      }
      do {
        let store = QFLocalModelStore.shared
        report["filename"] = store.descriptor.filename
        report["modelBytes"] = store.descriptor.bytes
        if download, store.state == .absent || store.state == .failed {
          if arguments.contains("-QFDeploymentMirror") { store.downloadFromDeploymentMirror(); report["downloadSource"] = "hf-mirror.com" }
          else { store.download(); report["downloadSource"] = "huggingface.co" }
        }
        for _ in 0..<40 {
          if store.state == .ready || store.state == .failed { break }
          report["status"] = "IN_PROGRESS"
          report["phase"] = store.state == .verifying ? "verification" : "download"
          if case .downloading(let progress) = store.state { report["downloadProgress"] = progress }
          save()
          try await Task.sleep(nanoseconds: 15_000_000_000)
        }
        guard store.state == .ready else { throw NSError(domain: "QFDeployment", code: 1) }
        report["status"] = "IN_PROGRESS"
        report["phase"] = "inference"
        report.removeValue(forKey: "downloadProgress")
        report["verifiedSHA256"] = store.descriptor.sha256
        save()
        let answer = try await QFOnDeviceInference.answer(model: store.modelURL,
          turns: [.init(role: "user", content: "请只回复这七个字：本地模型已就绪")], language: "zh-Hans")
        report["status"] = "INFERENCE_COMPLETED"
        report["answer"] = answer
        report["expectedPhrasePresent"] = answer.contains("本地模型已就绪")
        report["verifiedSHA256"] = store.descriptor.sha256
      } catch {
        if download { QFLocalModelStore.shared.pause() }
        report["status"] = "FAILED_OR_CANCELLED"
        report["error"] = String(describing: error)
        report["modelFailureReason"] = QFLocalModelStore.shared.failureReason
      }
      report["elapsedSecondsIncludingVerification"] = Date().timeIntervalSince(started)
      report["nativeMetrics"] = QFOnDeviceInference.latestMetrics
      report["peakMemoryMeasured"] = false
      save()
      task = nil
    }
  }
  private struct CleanupRecord: Codable, Sendable {
    let filename: String
    let status: String
    let removedBytes: Int64
  }
  /// This task's two rejected experiments only; byte count + SHA must match.
  /// Never touches the default model, user data, arbitrary paths or other caches.
  private static func cleanupRejectedExperiments() async {
    let store = QFLocalModelStore.shared
    for _ in 0..<20 {
      if store.state == .ready || store.state == .failed { break }
      do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
    }
    guard store.state == .ready, !Task.isCancelled else { return }
    let directory = store.directory, active = store.modelURL.lastPathComponent
    let cleanup = Task.detached(priority: .utility) { () -> [CleanupRecord] in
      let owned: [(String, Int64, String)] = [
        ("Qwen_Qwen3.5-2B-IQ2_M.gguf", 935046240, "dfbc93de1649b15ab98f3b7eceacbc1680e39c09288f159b8b36d9396b7fe41e"),
        ("Qwen_Qwen3.5-2B-IQ3_XXS.gguf", 1061530720, "46097c6dea388054c52a9684b800e780fc3c2b15ad3e36fad9084f2448b4e53b")
      ]
      var rows: [CleanupRecord] = []
      for (filename, bytes, expected) in owned {
        guard filename != active, !Task.isCancelled else { continue }
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
          rows.append(.init(filename: filename, status: "ABSENT", removedBytes: 0)); continue
        }
        do {
          let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
          guard values.isRegularFile == true, values.isSymbolicLink != true,
            values.fileSize == Int(bytes), let stream = InputStream(url: url) else { throw CocoaError(.fileReadCorruptFile) }
          stream.open(); defer { stream.close() }
          var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1024 * 1024)
          while stream.hasBytesAvailable {
            try Task.checkCancellation()
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw CocoaError(.fileReadUnknown) }; if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count)))
          }
          let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
          guard digest == expected else { throw CocoaError(.fileReadCorruptFile) }
          try Task.checkCancellation(); stream.close()
          try FileManager.default.removeItem(at: url)
          rows.append(.init(filename: filename, status: "REMOVED_VERIFIED_TASK_EXPERIMENT", removedBytes: bytes))
        } catch { rows.append(.init(filename: filename, status: "PRESERVED_FAILED_GUARD", removedBytes: 0)) }
      }
      return rows
    }
    let rows = await withTaskCancellationHandler(operation: { await cleanup.value }, onCancel: { cleanup.cancel() })
    let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("rejected-model-cleanup.json")
    if let data = try? JSONEncoder().encode(rows) { try? data.write(to: report, options: .atomic) }
  }
  static func cancel() { task?.cancel() }
}
#endif
