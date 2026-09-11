#if DEBUG
  import Combine
  import Foundation

  enum QFRequestLogStatus: String, Codable {
    case inProgress
    case succeeded
    case failed
  }

  /// Debug-only raw request values, with bounded previews and disk retention.
  struct QFRequestLogEntry: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    var finishedAt: Date?
    let method: String
    let url: String
    let requestHeaders: [String: String]
    let requestBody: String
    var responseHeaders: [String: String]
    var responseBody: String
    var statusCode: Int?
    var errorDescription: String?

    var duration: TimeInterval? {
      finishedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }

    var status: QFRequestLogStatus {
      guard finishedAt != nil else { return .inProgress }
      if errorDescription == nil, let statusCode, (200..<300).contains(statusCode) {
        return .succeeded
      }
      return .failed
    }
  }

  /// Call from the main actor. The index contains file metadata, never all response bodies.
  @MainActor
  final class QFRequestLogStore: ObservableObject {
    static let shared = QFRequestLogStore(
      directoryURL: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Diagnostics/Requests", isDirectory: true)
    )

    @Published private(set) var entries: [QFRequestLogEntry] = []
    @Published private(set) var page = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var totalPages = 1
    @Published private(set) var revision = 0
    @Published private(set) var storageError: String?

    let pageSize = 20
    private let directoryURL: URL
    private let maxEntries: Int
    private let maxDiskBytes: Int
    private let maxBodyBytes: Int
    private let fileManager = FileManager.default
    private var files: [LogFile] = []
    private var lastSortKey: Int64 = 0

    private struct LogFile {
      let id: UUID
      let url: URL
      let sortKey: Int64
      var byteCount: Int
    }

    init(
      directoryURL: URL,
      maxEntries: Int = 500,
      maxDiskBytes: Int = 10 * 1024 * 1024,
      maxBodyBytes: Int = 16 * 1024
    ) {
      self.directoryURL = directoryURL
      self.maxEntries = max(0, min(500, maxEntries))
      self.maxDiskBytes = max(0, min(10 * 1024 * 1024, maxDiskBytes))
      self.maxBodyBytes = max(0, min(16 * 1024, maxBodyBytes))
      do {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        #if os(iOS)
          try fileManager.setAttributes(
            [
              .posixPermissions: 0o700,
              .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ], ofItemAtPath: directoryURL.path)
        #endif
        var excludedDirectory = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedDirectory.setResourceValues(values)
        try readFileIndex()
        try enforceLimits()
      } catch {
        reportStorageError(error)
      }
      loadPage(0)
    }

    @discardableResult
    func begin(request: URLRequest) -> UUID {
      let id = UUID()
      let now = Date()
      let entry = QFRequestLogEntry(
        id: id,
        startedAt: now,
        finishedAt: nil,
        method: request.httpMethod ?? "GET",
        url: request.url?.absoluteString ?? "[URL 不可用]",
        requestHeaders: request.allHTTPHeaderFields ?? [:],
        requestBody: request.httpBodyStream != nil
          ? QFRequestLogPreview.bounded("[流式请求体未读取]", limit: maxBodyBytes)
          : QFRequestLogPreview.body(
            request.httpBody,
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            limit: maxBodyBytes
          ),
        responseHeaders: [:],
        responseBody: "",
        statusCode: nil,
        errorDescription: nil
      )
      lastSortKey = max(lastSortKey + 1, Int64(now.timeIntervalSince1970 * 1_000_000))
      let filename = String(format: "%020lld-%@.json", lastSortKey, id.uuidString)
      let file = LogFile(
        id: id,
        url: directoryURL.appendingPathComponent(filename),
        sortKey: lastSortKey,
        byteCount: 0
      )
      persist(entry, file: file)
      return id
    }

    func finish(id: UUID, response: HTTPURLResponse?, data: Data?, error: Error?) {
      guard let file = files.first(where: { $0.id == id }), var entry = read(file) else { return }
      entry.finishedAt = Date()
      entry.statusCode = response?.statusCode
      let responseHeaders =
        response?.allHeaderFields.reduce(into: [String: String]()) {
          result, item in
          result[String(describing: item.key)] = String(describing: item.value)
        } ?? [:]
      entry.responseHeaders = responseHeaders
      entry.responseBody = QFRequestLogPreview.body(
        data,
        contentType: response?.value(forHTTPHeaderField: "Content-Type"),
        limit: maxBodyBytes
      )
      if let error {
        let failure = error as NSError
        entry.errorDescription = QFRequestLogPreview.bounded(
          "\(failure.domain)，错误码 \(failure.code)：\(failure.localizedDescription)",
          limit: maxBodyBytes)
      }
      persist(entry, file: file)
    }

    func loadPage(_ requestedPage: Int) {
      totalCount = files.count
      totalPages = max(1, (totalCount + pageSize - 1) / pageSize)
      page = min(max(0, requestedPage), totalPages - 1)
      let start = page * pageSize
      entries = files.dropFirst(start).prefix(pageSize).compactMap { read($0) }
    }

    func entry(id: UUID) -> QFRequestLogEntry? {
      guard let file = files.first(where: { $0.id == id }) else { return nil }
      return read(file)
    }

    private func readFileIndex() throws {
      let urls = try fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      )
      files = try urls.compactMap { url in
        guard url.pathExtension == "json" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count == 57 else { return nil }
        let split = name.index(name.startIndex, offsetBy: 20)
        guard name[split] == "-", let sortKey = Int64(name[..<split]),
          let id = UUID(uuidString: String(name[name.index(after: split)...]))
        else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { return nil }
        return LogFile(id: id, url: url, sortKey: sortKey, byteCount: values.fileSize ?? 0)
      }
      files.sort { $0.sortKey > $1.sortKey }
      lastSortKey = files.first?.sortKey ?? 0
    }

    private func read(_ file: LogFile) -> QFRequestLogEntry? {
      do {
        let data = try Data(contentsOf: file.url)
        return try JSONDecoder().decode(QFRequestLogEntry.self, from: data)
      } catch {
        reportStorageError(error)
        return nil
      }
    }

    private func persist(_ entry: QFRequestLogEntry, file: LogFile) {
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(entry)
        if maxEntries == 0 || data.count > maxDiskBytes {
          if let index = files.firstIndex(where: { $0.id == file.id }) {
            try fileManager.removeItem(at: files[index].url)
            files.remove(at: index)
          }
        } else {
          // Only this request is rewritten at completion; there is no aggregate body/index file.
          try data.write(to: file.url, options: .atomic)
          #if os(iOS)
            try fileManager.setAttributes(
              [
                .posixPermissions: 0o600,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
              ], ofItemAtPath: file.url.path)
          #endif
          var updated = file
          updated.byteCount = data.count
          if let index = files.firstIndex(where: { $0.id == file.id }) {
            files[index] = updated
          } else {
            files.insert(updated, at: 0)
          }
          try enforceLimits()
        }
        storageError = nil
      } catch {
        reportStorageError(error)
      }
      loadPage(page)
      revision &+= 1
    }

    private func enforceLimits() throws {
      var byteCount = files.reduce(0) { $0 + $1.byteCount }
      while files.count > maxEntries || byteCount > maxDiskBytes {
        guard let oldest = files.last else { break }
        try fileManager.removeItem(at: oldest.url)
        files.removeLast()
        byteCount -= oldest.byteCount
      }
    }

    private func reportStorageError(_ error: Error) {
      storageError = "请求日志文件读写失败（错误码 \((error as NSError).code)）"
    }
  }

  private enum QFRequestLogPreview {
    private static let truncation = "\n[内容已截断]"

    static func body(_ data: Data?, contentType: String?, limit: Int) -> String {
      guard let data, !data.isEmpty else { return "" }
      // Size limits protect the debug view; field names and values are never redacted.
      guard data.count <= 2 * 1024 * 1024 else {
        return bounded("[内容过大，已省略；\(data.count) 字节]", limit: limit)
      }
      let preview: String
      if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
        let formatted = try? JSONSerialization.data(
          withJSONObject: object,
          options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]),
        let text = String(data: formatted, encoding: .utf8)
      {
        preview = text
      } else if let text = String(data: data, encoding: .utf8) {
        preview = text
      } else {
        preview = "[二进制 Base64；\(data.count) 字节]\n" + data.base64EncodedString()
      }
      return bounded(preview, limit: limit)
    }

    static func bounded(_ string: String, limit: Int) -> String {
      guard limit > 0 else { return "" }
      guard string.utf8.count > limit else { return string }
      let marker = utf8Prefix(truncation, maxBytes: limit)
      return utf8Prefix(string, maxBytes: limit - marker.utf8.count) + marker
    }

    private static func utf8Prefix(_ string: String, maxBytes: Int) -> String {
      guard maxBytes > 0 else { return "" }
      var bytes = Array(string.utf8.prefix(maxBytes))
      // Remove an incomplete final Unicode scalar without inserting replacement characters.
      while !bytes.isEmpty {
        if let result = String(bytes: bytes, encoding: .utf8) { return result }
        bytes.removeLast()
      }
      return ""
    }
  }
#endif
