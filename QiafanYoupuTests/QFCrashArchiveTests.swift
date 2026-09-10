import CrashReporter
import Foundation
import XCTest

@testable import QiafanYoupu

final class QFCrashArchiveTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("QFCrashArchiveTests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
    directory = nil
    try super.tearDownWithError()
  }

  func testSavesRawReadableAndSymbolicationMetadata() throws {
    let archive = QFCrashArchive(directory: directory)
    try archive.prepare()
    let raw = Data([0, 1, 2, 3])
    let metadata = QFCrashMetadata(
      reportUUID: "crash-uuid", applicationIdentifier: "com.example.crashed-build",
      applicationVersion: "42", applicationMarketingVersion: "1.2",
      binaryImages: [
        .init(
          path: "/App/QiafanYoupu", uuid: "binary-dsym-uuid", baseAddress: "0x1000",
          size: 1024, cpuType: 16_777_228, cpuSubtype: 0)
      ])
    let record = try archive.save(raw: raw, readable: "Thread 0 Crashed", metadata: metadata)

    XCTAssertEqual(try Data(contentsOf: record.appendingPathComponent("raw.plcrash")), raw)
    XCTAssertEqual(
      try String(contentsOf: record.appendingPathComponent("report.crash")), "Thread 0 Crashed")
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: record.appendingPathComponent("metadata.json"))) as? [String: Any])
    XCTAssertEqual(json["applicationVersion"] as? String, "42")
    XCTAssertEqual(json["captureLibraryVersion"] as? String, "1.12.2")
    XCTAssertEqual(
      (json["binaryImages"] as? [[String: Any]])?.first?["uuid"] as? String, "binary-dsym-uuid")
    XCTAssertEqual(
      try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: record.appendingPathComponent("raw.plcrash").path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let protection =
      (attributes[.protectionKey] as? String)
      ?? (attributes[.protectionKey] as? FileProtectionType)?.rawValue
    #if targetEnvironment(simulator)
      // Simulator storage does not provide the device keybag/Data Protection attribute.
      if let protection {
        XCTAssertEqual(protection, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
      }
    #else
      XCTAssertEqual(protection, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
    #endif
  }

  func testRetryDoesNotDuplicatePendingReport() throws {
    let archive = QFCrashArchive(directory: directory)
    try archive.prepare()
    let raw = Data("same crash".utf8)
    let first = try archive.save(
      raw: raw, readable: "First conversion", metadata: QFCrashMetadata())
    let second = try archive.save(
      raw: raw, readable: "Retry conversion", metadata: QFCrashMetadata())
    XCTAssertEqual(first, second)
    XCTAssertEqual(try records().count, 1)
    XCTAssertEqual(
      try String(contentsOf: first.appendingPathComponent("report.crash")), "First conversion")
  }

  func testCountLimitEvictsOldestWholeRecord() throws {
    let archive = QFCrashArchive(directory: directory, maxRecords: 2)
    try archive.prepare()
    let first = try save("first", to: archive)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: first.path)
    let second = try save("second", to: archive)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: second.path)
    let third = try save("third", to: archive)

    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    XCTAssertEqual(Set(try records()), Set([second, third]))
  }

  func testByteLimitAndOversizedRecordPreserveExistingData() throws {
    let archive = QFCrashArchive(directory: directory, maxBytes: 2500)
    try archive.prepare()
    let first = try archive.save(
      raw: Data([1]), readable: String(repeating: "A", count: 1300), metadata: QFCrashMetadata())
    let second = try archive.save(
      raw: Data([2]), readable: String(repeating: "B", count: 1300), metadata: QFCrashMetadata())
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    XCTAssertEqual(try records(), [second])
    XCTAssertLessThanOrEqual(try diskBytes(), 2500)

    XCTAssertThrowsError(
      try archive.save(
        raw: Data([3]), readable: String(repeating: "C", count: 3000), metadata: QFCrashMetadata()))
    XCTAssertEqual(try records(), [second])
  }

  func testPrepareRemovesInterruptedStagingButKeepsPending() throws {
    let archive = QFCrashArchive(directory: directory)
    try archive.prepare()
    let staging = directory.appendingPathComponent(".staging-interrupted", isDirectory: true)
    let pending = directory.appendingPathComponent(".pending", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
    let rawURL = pending.appendingPathComponent("live_report.plcrash")
    let raw = Data([3, 2, 1])
    try raw.write(to: rawURL)

    try archive.prepare()

    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    XCTAssertEqual(try Data(contentsOf: rawURL), raw)
  }

  func testDamagedPendingReportRetainsRawAndConversionError() throws {
    let archive = QFCrashArchive(directory: directory)
    try archive.prepare()
    let raw = Data([0, 1, 2])
    let converted = QFCrashRecorder.decodePendingReport(raw)
    XCTAssertNotNil(converted.metadata.conversionError)
    XCTAssertTrue(converted.readable.contains("raw.plcrash"))
    let record = try archive.save(
      raw: raw, readable: converted.readable, metadata: converted.metadata)
    XCTAssertEqual(try Data(contentsOf: record.appendingPathComponent("raw.plcrash")), raw)
  }

  func testLibrarySnapshotPreservesReportAndBinaryUUIDsWithoutEnablingCapture() throws {
    // The SDK snapshot API returns current process data without installing handlers or crashing.
    let configuration = PLCrashReporterConfig(signalHandlerType: .mach, symbolicationStrategy: [])
    let reporter = try XCTUnwrap(PLCrashReporter(configuration: configuration))
    let raw = try reporter.generateLiveReportAndReturnError()
    let converted = QFCrashRecorder.decodePendingReport(raw)

    XCTAssertNil(converted.metadata.conversionError)
    XCTAssertNotNil(converted.metadata.reportUUID)
    XCTAssertTrue(converted.metadata.binaryImages.contains { $0.uuid?.isEmpty == false })
    XCTAssertTrue(converted.readable.contains("Binary Images:"))

    let archive = QFCrashArchive(directory: directory)
    try archive.prepare()
    let record = try archive.save(
      raw: raw, readable: converted.readable, metadata: converted.metadata)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: record.appendingPathComponent("metadata.json"))) as? [String: Any])
    XCTAssertEqual(json["reportUUID"] as? String, converted.metadata.reportUUID)
    let images = try XCTUnwrap(json["binaryImages"] as? [[String: Any]])
    XCTAssertEqual(
      images.compactMap { $0["uuid"] as? String },
      converted.metadata.binaryImages.compactMap(\.uuid))
  }

  private func save(_ text: String, to archive: QFCrashArchive) throws -> URL {
    try archive.save(raw: Data(text.utf8), readable: text, metadata: QFCrashMetadata())
  }

  private func records() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "crashbundle" }
  }

  private func diskBytes() throws -> Int {
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
    return try enumerator.reduce(0) { sum, item in
      let url = try XCTUnwrap(item as? URL)
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      return sum + (values.isRegularFile == true ? values.fileSize ?? 0 : 0)
    }
  }
}
