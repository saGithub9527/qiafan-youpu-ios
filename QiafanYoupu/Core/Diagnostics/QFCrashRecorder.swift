import CrashReporter
import Darwin
import Foundation
import OSLog

/// Captures locally with PLCrashReporter; Swift decoding and file management only run at launch.
final class QFCrashRecorder {
  static let shared = QFCrashRecorder()

  enum StartResult: Equatable {
    case capturing
    case skippedDebugger
    case failed(String)
  }

  let reportsDirectory: URL

  private let archive: QFCrashArchive
  private let lock = NSLock()
  private let logger = Logger(subsystem: "com.talka.qiafanyoupu", category: "CrashRecorder")
  private var reporter: PLCrashReporter?
  private var startResult: StartResult?

  private init() {
    reportsDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Diagnostics/Crashes", isDirectory: true)
    archive = QFCrashArchive(directory: reportsDirectory)
  }

  /// Call once near the start of App.init. Repeated calls return the first result.
  /// A failed archive leaves the pending report intact and does not enable an overwriting writer.
  @discardableResult
  func start() -> StartResult {
    lock.lock()
    defer { lock.unlock() }
    if let startResult { return startResult }

    let result: StartResult
    do {
      try archive.prepare()
      let pendingBase = reportsDirectory.appendingPathComponent(".pending", isDirectory: true)
      try archive.prepareProtectedDirectory(pendingBase)
      let configuration = PLCrashReporterConfig(
        signalHandlerType: .mach,
        symbolicationStrategy: [],
        shouldRegisterUncaughtExceptionHandler: true,
        basePath: pendingBase.path,
        maxReportBytes: UInt(QFCrashArchive.pendingByteLimit)
      )
      guard let reporter = PLCrashReporter(configuration: configuration) else {
        throw RecorderError.initializationFailed
      }
      self.reporter = reporter

      // Pre-create the SDK's actual parent with protection, inherited by its crash-time file.
      let pendingURL = URL(fileURLWithPath: reporter.crashReportPath())
      try archive.prepareProtectedDirectory(pendingURL.deletingLastPathComponent())
      if reporter.hasPendingCrashReport() {
        let raw = try reporter.loadPendingCrashReportDataAndReturnError()
        let converted = Self.decodePendingReport(raw)
        try archive.save(raw: raw, readable: converted.readable, metadata: converted.metadata)
        guard reporter.purgePendingCrashReport() else { throw RecorderError.pendingPurgeFailed }
      }
      try archive.protectTree(pendingBase)

      #if DEBUG
        if try Self.isDebuggerAttached() {
          result = .skippedDebugger
        } else {
          try reporter.enableAndReturnError()
          result = .capturing
        }
      #else
        try reporter.enableAndReturnError()
        result = .capturing
      #endif
    } catch {
      let message = (error as NSError).localizedDescription
      logger.error("Local crash recorder could not start: \(message, privacy: .public)")
      result = .failed(message)
    }
    startResult = result
    return result
  }

  static func decodePendingReport(_ raw: Data) -> (readable: String, metadata: QFCrashMetadata) {
    do {
      let report = try PLCrashReport(data: raw)
      let readable = PLCrashReportTextFormatter.stringValue(
        for: report, with: PLCrashReportTextFormatiOS)
      let images = (report.images as? [PLCrashReportBinaryImageInfo] ?? []).map { image in
        QFCrashMetadata.BinaryImage(
          path: image.imageName ?? "",
          uuid: image.hasImageUUID ? image.imageUUID : nil,
          baseAddress: String(format: "0x%llx", image.imageBaseAddress),
          size: image.imageSize,
          cpuType: image.codeType?.type,
          cpuSubtype: image.codeType?.subtype
        )
      }
      let metadata = QFCrashMetadata(
        capturedAt: report.systemInfo.timestamp,
        reportUUID: report.uuidRef.map { CFUUIDCreateString(nil, $0) as String },
        applicationIdentifier: report.applicationInfo.applicationIdentifier,
        applicationVersion: report.applicationInfo.applicationVersion,
        applicationMarketingVersion: report.applicationInfo.applicationMarketingVersion,
        osVersion: report.systemInfo.operatingSystemVersion,
        osBuild: report.systemInfo.operatingSystemBuild,
        signalName: report.signalInfo.name,
        signalCode: report.signalInfo.code,
        exceptionName: report.hasExceptionInfo ? report.exceptionInfo.exceptionName : nil,
        binaryImages: images,
        conversionError: readable == nil ? "PLCrashReporter could not format readable text." : nil
      )
      return (
        readable ?? "Readable conversion unavailable. Preserve raw.plcrash for analysis.", metadata
      )
    } catch {
      // A truncated/damaged report still retains the original SDK bytes for offline analysis.
      let message = "PLCrashReporter could not decode this report: \(error.localizedDescription)"
      return (
        message + "\nOriginal bytes are preserved in raw.plcrash.\n",
        QFCrashMetadata(conversionError: message)
      )
    }
  }

  #if DEBUG
    private static func isDebuggerAttached() throws -> Bool {
      var process = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
      let status = query.withUnsafeMutableBufferPointer { pointer in
        sysctl(pointer.baseAddress, u_int(pointer.count), &process, &size, nil, 0)
      }
      guard status == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      return (process.kp_proc.p_flag & P_TRACED) != 0
    }
  #endif

  private enum RecorderError: LocalizedError {
    case initializationFailed
    case pendingPurgeFailed

    var errorDescription: String? {
      switch self {
      case .initializationFailed: return "PLCrashReporter initialization failed."
      case .pendingPurgeFailed:
        return "Archived report retained; pending report could not be removed."
      }
    }
  }
}

struct QFCrashMetadata: Encodable {
  struct BinaryImage: Encodable {
    let path: String
    let uuid: String?
    let baseAddress: String
    let size: UInt64
    let cpuType: UInt64?
    let cpuSubtype: UInt64?
  }

  let schemaVersion = 1
  let captureLibrary = "PLCrashReporter"
  let captureLibraryVersion = "1.12.2"
  var archivedAt = Date()
  var capturedAt: Date?
  var reportUUID: String?
  var applicationIdentifier: String?
  var applicationVersion: String?
  var applicationMarketingVersion: String?
  var osVersion: String?
  var osBuild: String?
  var signalName: String?
  var signalCode: String?
  var exceptionName: String?
  var binaryImages: [BinaryImage] = []
  var conversionError: String?
  let symbolication =
    "Match each binary UUID to the dSYM from the archived build. dSYMs are not embedded. Keep raw.plcrash and report.crash together."
}
