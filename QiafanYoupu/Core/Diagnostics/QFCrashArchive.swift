import CryptoKit
import Foundation

/// Normal-launch storage only. This class is never called from a signal/exception handler.
final class QFCrashArchive {
  static let pendingByteLimit = 2 * 1024 * 1024
  static let totalByteLimit = 20 * 1024 * 1024
  static let totalRecordLimit = 20

  let directory: URL
  private let maxRecords: Int
  private let maxBytes: Int
  private let fileManager: FileManager

  init(
    directory: URL,
    maxRecords: Int = totalRecordLimit - 1,
    maxBytes: Int = totalByteLimit - pendingByteLimit,
    fileManager: FileManager = .default
  ) {
    self.directory = directory
    self.maxRecords = max(1, min(maxRecords, Self.totalRecordLimit - 1))
    self.maxBytes = max(1, min(maxBytes, Self.totalByteLimit - Self.pendingByteLimit))
    self.fileManager = fileManager
  }

  func prepare() throws {
    try prepareProtectedDirectory(directory)
    for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    where url.lastPathComponent.hasPrefix(".staging-") {
      // Pending is purged only after the final rename, so an interrupted write is safe to retry.
      try fileManager.removeItem(at: url)
    }
    try prune(reservingRecords: 0, reservingBytes: 0)
  }

  @discardableResult
  func save(raw: Data, readable: String, metadata: QFCrashMetadata) throws -> URL {
    let id = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    let destination = directory.appendingPathComponent(
      "report-\(id).crashbundle", isDirectory: true)
    if fileManager.fileExists(atPath: destination.path) {
      // A previous launch may have committed all files but failed to purge the SDK pending file.
      let savedRaw = try Data(contentsOf: destination.appendingPathComponent("raw.plcrash"))
      guard savedRaw == raw,
        fileManager.fileExists(atPath: destination.appendingPathComponent("report.crash").path),
        fileManager.fileExists(atPath: destination.appendingPathComponent("metadata.json").path)
      else { throw ArchiveError.invalidExistingArchive }
      return destination
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let files: [(String, Data)] = [
      ("raw.plcrash", raw),
      ("report.crash", Data(readable.utf8)),
      ("metadata.json", try encoder.encode(metadata)),
    ]
    let byteCount = files.reduce(0) { $0 + $1.1.count }
    guard byteCount <= maxBytes else { throw ArchiveError.reportExceedsBudget }
    try prune(reservingRecords: 1, reservingBytes: byteCount)

    let staging = directory.appendingPathComponent(".staging-\(id)", isDirectory: true)
    try prepareProtectedDirectory(staging)
    do {
      for (name, data) in files {
        let url = staging.appendingPathComponent(name)
        try data.write(
          to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try protect(url, isDirectory: false)
      }
      try fileManager.moveItem(at: staging, to: destination)
      return destination
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }
  }

  func prepareProtectedDirectory(_ url: URL) throws {
    // All parents created within Crashes need protection before PLCrashReporter installs.
    if url.standardizedFileURL != directory.standardizedFileURL {
      let parent = url.deletingLastPathComponent()
      if parent.path.hasPrefix(directory.path + "/") || parent == directory {
        try prepareProtectedDirectory(parent)
      }
    }
    try fileManager.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        .posixPermissions: 0o700,
      ])
    try protect(url, isDirectory: true)
  }

  func protectTree(_ root: URL) throws {
    try protect(root, isDirectory: true)
    guard
      let enumerator = fileManager.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])
    else { return }
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      try protect(url, isDirectory: values.isDirectory == true)
    }
  }

  private func protect(_ url: URL, isDirectory: Bool) throws {
    try fileManager.setAttributes(
      [
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        .posixPermissions: isDirectory ? 0o700 : 0o600,
      ], ofItemAtPath: url.path)
    var mutableURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try mutableURL.setResourceValues(values)
  }

  private struct Record {
    let url: URL
    let date: Date
    let bytes: Int
  }

  private func prune(reservingRecords: Int, reservingBytes: Int) throws {
    let urls = try fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )
    var records: [Record] = []
    for url in urls where url.pathExtension == "crashbundle" {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
      guard values.isDirectory == true else { throw ArchiveError.invalidExistingArchive }
      let files = try fileManager.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.fileSizeKey])
      var bytes = 0
      for file in files {
        bytes += try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      }
      records.append(
        Record(url: url, date: values.contentModificationDate ?? .distantPast, bytes: bytes))
    }
    records.sort { $0.date == $1.date ? $0.url.path < $1.url.path : $0.date < $1.date }

    var bytes = records.reduce(0) { $0 + $1.bytes }
    while records.count + reservingRecords > maxRecords || bytes + reservingBytes > maxBytes {
      guard !records.isEmpty else { throw ArchiveError.reportExceedsBudget }
      let oldest = records.removeFirst()
      try fileManager.removeItem(at: oldest.url)
      bytes -= oldest.bytes
    }
  }

  private enum ArchiveError: LocalizedError {
    case invalidExistingArchive
    case reportExceedsBudget

    var errorDescription: String? {
      switch self {
      case .invalidExistingArchive: return "An existing crash archive is incomplete or invalid."
      case .reportExceedsBudget:
        return "Crash report exceeds the local archive budget; pending bytes are retained."
      }
    }
  }
}
