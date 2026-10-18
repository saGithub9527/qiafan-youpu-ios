import CryptoKit
import Foundation

/// Selected media belongs to a local draft until its owner explicitly submits the form.
enum QFLocalMediaStore {
  struct File: Codable, Sendable {
    let id: String
    let kind: String
    let mimeType: String
    let filename: String
    var uploadedID: String?
  }
  static func isLocal(_ id: String) -> Bool { id.hasPrefix("local:") }
  private static func folder(scope: String) throws -> URL {
    let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true).appendingPathComponent("QFLocalDraftMedia/" + digest, isDirectory: true)
  }
  private static func token(_ id: String) throws -> String {
    guard isLocal(id), let uuid = UUID(uuidString: String(id.dropFirst(6))) else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    return uuid.uuidString.lowercased()
  }
  static func save(_ data: Data, video: Bool, scope: String) throws -> QFContentMedia {
    var directory = try folder(scope: scope)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    let uuid = UUID().uuidString.lowercased()
    let file = File(id: "local:" + uuid, kind: video ? "VIDEO" : "IMAGE",
      mimeType: video ? "video/quicktime" : "image/jpeg", filename: uuid + (video ? ".mov" : ".jpg"))
    let destination = directory.appendingPathComponent(file.filename)
    do {
      try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      try JSONEncoder().encode(file).write(to: directory.appendingPathComponent(uuid + ".json"), options: .atomic)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    return QFContentMedia(id: file.id, kind: file.kind, mimeType: file.mimeType)
  }
  static func file(_ id: String, scope: String) throws -> File {
    let path = try folder(scope: scope).appendingPathComponent(token(id) + ".json")
    return try JSONDecoder().decode(File.self, from: Data(contentsOf: path))
  }
  static func url(_ id: String, scope: String) throws -> URL {
    let value = try file(id, scope: scope)
    guard value.filename == (try token(id)) + (value.kind == "VIDEO" ? ".mov" : ".jpg") else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return try folder(scope: scope).appendingPathComponent(value.filename)
  }
  static func markUploaded(_ id: String, remoteID: String, scope: String) throws {
    var value = try file(id, scope: scope)
    value.uploadedID = remoteID
    try JSONEncoder().encode(value).write(
      to: try folder(scope: scope).appendingPathComponent(token(id) + ".json"), options: .atomic)
  }
  static func remove(_ id: String?, scope: String) {
    guard let id, isLocal(id) else { return }
    if let path = try? url(id, scope: scope) { try? FileManager.default.removeItem(at: path) }
    if let directory = try? folder(scope: scope), let name = try? token(id) {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + ".json"))
    }
  }
  static func removeAll(scope: String) throws {
    let directory = try folder(scope: scope)
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }
}

@MainActor
extension QFAppSession {
  func uploadedMediaID(_ id: String) async throws -> String {
    guard QFLocalMediaStore.isLocal(id) else { return id }
    let scope = contentScope
    let file = try QFLocalMediaStore.file(id, scope: scope)
    if let uploaded = file.uploadedID { return uploaded }
    let url = try QFLocalMediaStore.url(id, scope: scope)
    let bytes = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
    try Task.checkCancellation()
    guard contentScope == scope else { throw CancellationError() }
    let uploaded = try await uploadContentMedia(bytes, mimeType: file.mimeType, filename: file.filename)
    guard contentScope == scope else { throw CancellationError() }
    try QFLocalMediaStore.markUploaded(id, remoteID: uploaded.id, scope: scope)
    return uploaded.id
  }
}
