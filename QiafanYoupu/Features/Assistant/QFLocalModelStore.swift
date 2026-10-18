import Combine
import CryptoKit
import Foundation
import UIKit

struct QFLocalModelDescriptor: Decodable, Sendable {
  let id: String
  let filename: String
  let url: URL
  let bytes: Int64
  let sha256: String
  let licenseURL: URL
  var quantization: String { filename.replacingOccurrences(of: "Qwen_Qwen3.5-2B-", with: "").replacingOccurrences(of: ".gguf", with: "") }

  static var bundled: Self {
    let url = Bundle.main.url(forResource: "qwen-local-model", withExtension: "json")!
    let data = try! Data(contentsOf: url)
    return try! JSONDecoder().decode(Self.self, from: data)
  }
}

private final class QFModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
  let destination: URL
  let expectedBytes: Int64
  var progress: ((Double) -> Void)?
  var finished: ((Result<URL, Error>) -> Void)?
  init(destination: URL, expectedBytes: Int64) { self.destination = destination; self.expectedBytes = expectedBytes }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    progress?(min(1, Double(totalBytesWritten) / Double(expectedBytes)))
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL) {
    do {
      let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200...299).contains(status) else { throw NSError(domain: "QFModelHTTP", code: status) }
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: location, to: destination)
      finished?(.success(destination))
    } catch { finished?(.failure(error)) }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error, (error as NSError).code != NSURLErrorCancelled { finished?(.failure(error)) }
  }
}

@MainActor
final class QFLocalModelStore: ObservableObject {
  static let shared = QFLocalModelStore()
  enum State: Equatable { case absent, downloading(Double), verifying, ready, failed }
  @Published private(set) var state: State = .absent
  private(set) var failureReason: String?
  let descriptor = QFLocalModelDescriptor.bundled
  private var session: URLSession?
  private var task: URLSessionDownloadTask?
  private var delegate: QFModelDownloadDelegate?
  private var operation = UUID()
  private var verification: Task<Void, Never>?
  private var verificationURL: URL?
  private var downloadSource: URL?
  private var backgroundObserver: NSObjectProtocol?
  private var foregroundObserver: NSObjectProtocol?

  var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("OnDeviceModels", isDirectory: true)
  }
  var modelURL: URL { directory.appendingPathComponent(descriptor.filename) }
  private var receiptURL: URL { directory.appendingPathComponent("verified.json") }
  private var resumeURL: URL { directory.appendingPathComponent("download.resume") }
  private var resumeSourceURL: URL { directory.appendingPathComponent("download-source.txt") }

  private init() {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var resource = directory
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try? resource.setResourceValues(values)
    if FileManager.default.fileExists(atPath: modelURL.path) { verifyExisting() }
    backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
      object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.pause() } }
    foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
      object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in
          guard let self, self.state == .absent, self.task == nil else { return }
          if let url = self.verificationURL { let run = UUID(); self.operation = run; self.verify(url, run: run) }
          else if FileManager.default.fileExists(atPath: self.modelURL.path) { self.verifyExisting() }
        }
      }
  }

  func download() {
    startDownload(from: descriptor.url)
  }
#if DEBUG
  /// Deployment-only mirror. The bytes must still match the official source's pinned SHA.
  func downloadFromDeploymentMirror() {
    var url = URLComponents(url: descriptor.url, resolvingAgainstBaseURL: false)!
    url.host = "hf-mirror.com"
    startDownload(from: url.url!)
  }
#endif
  private func startDownload(from source: URL) {
    guard task == nil, state != .verifying, state != .ready else { return }
    let available = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage
    guard let available, available > descriptor.bytes + 512 * 1024 * 1024 else { failureReason = "insufficient-disk-space"; state = .failed; return }
    let run = UUID(); operation = run
    failureReason = nil; downloadSource = source
    let delegate = QFModelDownloadDelegate(destination: directory.appendingPathComponent("download.\(run.uuidString).gguf"), expectedBytes: descriptor.bytes)
    delegate.progress = { [weak self] value in
      Task { @MainActor in
        guard let self, self.operation == run else { return }
        if case .downloading(let old) = self.state, value - old < 0.01 { return }
        self.state = .downloading(value)
      }
    }
    delegate.finished = { [weak self] result in
      Task { @MainActor in
        guard let self, self.operation == run else {
          if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
          return
        }
        self.task = nil; self.session?.finishTasksAndInvalidate(); self.session = nil; self.delegate = nil
        switch result {
        case .success(let url): self.verify(url, run: run)
        case .failure(let error):
          try? FileManager.default.removeItem(at: self.resumeURL)
          try? FileManager.default.removeItem(at: self.resumeSourceURL)
          self.failureReason = (error as NSError).domain + ":" + String((error as NSError).code)
          self.state = .failed
        }
      }
    }
    let configuration = URLSessionConfiguration.default
    configuration.allowsCellularAccess = false
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 4 * 60 * 60
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    self.session = session; self.delegate = delegate
    if (try? String(contentsOf: resumeSourceURL, encoding: .utf8)) == source.absoluteString,
      let resume = try? Data(contentsOf: resumeURL) { task = session.downloadTask(withResumeData: resume) }
    else { task = session.downloadTask(with: source) }
    state = .downloading(0); task?.resume()
  }

  func pause() {
    if let verification {
      operation = UUID(); verification.cancel(); self.verification = nil; state = .absent
    }
    guard let task else { return }
    let run = UUID(); operation = run; self.task = nil; state = .absent
    let source = downloadSource
    task.cancel { [weak self] data in
      Task { @MainActor in
        guard let self, self.operation == run, let data else { return }
        try? data.write(to: self.resumeURL, options: .atomic)
        try? source?.absoluteString.write(to: self.resumeSourceURL, atomically: true, encoding: .utf8)
      }
    }
    session?.finishTasksAndInvalidate(); session = nil; delegate = nil
  }

  func delete() {
    operation = UUID(); task?.cancel(); task = nil
    session?.invalidateAndCancel(); session = nil; delegate = nil
    verification?.cancel(); verification = nil
    verificationURL = nil
    let staged = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.lastPathComponent.hasPrefix("download.") && $0.pathExtension == "gguf" }
    for url in [modelURL, receiptURL, resumeURL, resumeSourceURL] + staged {
      try? FileManager.default.removeItem(at: url)
    }
    failureReason = nil; state = .absent
  }

  /// Also accepts a model copied into the application container by the deployment tool.
  func verifyExisting() {
    guard task == nil, verification == nil else { return }
    let run = UUID(); operation = run
    verify(modelURL, run: run)
  }

  private func verify(_ url: URL, run: UUID) {
    state = .verifying; verificationURL = url
    let expected = descriptor
    verification = Task { [weak self] in
      let hashing = Task.detached(priority: .utility) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          Int64(size) == expected.bytes, let stream = InputStream(url: url) else { return false }
        stream.open(); defer { stream.close() }
        var hash = SHA256(); var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while stream.hasBytesAvailable {
          if Task.isCancelled { return false }
          let count = stream.read(&buffer, maxLength: buffer.count)
          if count < 0 { return false }; if count == 0 { break }
          hash.update(data: Data(buffer.prefix(count)))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == expected.sha256
      }
      let valid = await withTaskCancellationHandler(operation: { await hashing.value }, onCancel: { hashing.cancel() })
      guard let self, !Task.isCancelled, self.operation == run else { return }
      defer { self.verification = nil; self.verificationURL = nil }
      guard valid else {
        self.failureReason = "model-integrity-mismatch"
        if url != self.modelURL { try? FileManager.default.removeItem(at: url) }
        self.state = .failed; return
      }
      do {
        if url != self.modelURL {
          if FileManager.default.fileExists(atPath: self.modelURL.path) {
            _ = try FileManager.default.replaceItemAt(self.modelURL, withItemAt: url)
          } else { try FileManager.default.moveItem(at: url, to: self.modelURL) }
        }
        let receipt = ["id": expected.id, "sha256": expected.sha256]
        try JSONSerialization.data(withJSONObject: receipt).write(to: self.receiptURL, options: .atomic)
        try? FileManager.default.removeItem(at: self.resumeURL)
        try? FileManager.default.removeItem(at: self.resumeSourceURL)
        self.state = .ready
      } catch { self.failureReason = (error as NSError).domain + ":" + String((error as NSError).code); self.state = .failed }
    }
  }
}
