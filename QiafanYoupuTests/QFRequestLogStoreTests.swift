#if DEBUG
  import Foundation
  import XCTest

  @testable import QiafanYoupu

  final class QFRequestLogStoreTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
      try super.setUpWithError()
      directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "QFRequestLogStoreTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
      if let directoryURL {
        try FileManager.default.removeItem(at: directoryURL)
      }
      directoryURL = nil
      try super.tearDownWithError()
    }

    @MainActor
    func testBeginAndFinishRetainRequestAndResponseMetadata() throws {
      let store = QFRequestLogStore(directoryURL: directoryURL)
      var request = makeRequest(path: "metadata")
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = Data(#"{"dish":"tomato"}"#.utf8)

      let id = store.begin(request: request)
      let pending = try XCTUnwrap(store.entry(id: id))
      XCTAssertEqual(pending.id, id)
      XCTAssertEqual(pending.method, "POST")
      XCTAssertEqual(pending.url, request.url?.absoluteString)
      XCTAssertNil(pending.finishedAt)
      XCTAssertNil(pending.statusCode)
      if case .inProgress = pending.status {} else { XCTFail("Expected an in-progress request") }

      let response = try XCTUnwrap(
        HTTPURLResponse(
          url: try XCTUnwrap(request.url), statusCode: 201, httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json", "X-Trace-ID": "trace-visible"]))
      store.finish(id: id, response: response, data: Data(#"{"ok":true}"#.utf8), error: nil)

      let finished = try XCTUnwrap(store.entry(id: id))
      XCTAssertEqual(finished.startedAt, pending.startedAt)
      XCTAssertNotNil(finished.finishedAt)
      XCTAssertGreaterThanOrEqual(try XCTUnwrap(finished.duration), 0)
      XCTAssertEqual(finished.statusCode, 201)
      XCTAssertNil(finished.errorDescription)
      XCTAssertTrue(finished.requestBody.contains("tomato"))
      XCTAssertTrue(finished.responseBody.contains("true"))
      XCTAssertEqual(header("X-Trace-ID", in: finished.responseHeaders), "trace-visible")
      if case .succeeded = finished.status {} else { XCTFail("Expected a successful request") }
      XCTAssertEqual(store.totalCount, 1)
    }

    @MainActor
    func testTransportFailureIsRecordedAndSurvivesReload() throws {
      let store = QFRequestLogStore(directoryURL: directoryURL)
      let id = store.begin(request: makeRequest(path: "timeout"))
      store.finish(id: id, response: nil, data: nil, error: URLError(.timedOut))

      let restored = QFRequestLogStore(directoryURL: directoryURL)
      let entry = try XCTUnwrap(restored.entry(id: id))
      XCTAssertNotNil(entry.finishedAt)
      XCTAssertNotNil(entry.duration)
      XCTAssertNil(entry.statusCode)
      XCTAssertFalse(try XCTUnwrap(entry.errorDescription).isEmpty)
      if case .failed = entry.status {} else { XCTFail("Expected a failed request") }
    }

    @MainActor
    func testRawHeadersURLAndNestedJSONPersistWithoutRedaction() throws {
      let secrets = [
        "url-user-secret-01", "url-password-secret-02", "query-token-secret-03",
        "query-password-secret-04", "authorization-secret-05", "cookie-secret-06",
        "request-api-key-secret-07", "body-password-secret-08", "body-token-secret-09",
        "body-refresh-secret-10", "response-token-secret-11", "response-secret-12",
        "response-cookie-secret-13", "response-api-key-secret-14",
      ]
      let url = try XCTUnwrap(
        URL(
          string:
            "https://\(secrets[0]):\(secrets[1])@example.invalid/log?%61ccess_token=\(secrets[2])&PaSsWoRd=\(secrets[3])&page=2"
        ))
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Bearer \(secrets[4])", forHTTPHeaderField: "aUtHoRiZaTiOn")
      request.setValue("session=\(secrets[5])", forHTTPHeaderField: "Cookie")
      request.setValue(secrets[6], forHTTPHeaderField: "X-API-Key")
      request.setValue("visible-request-trace", forHTTPHeaderField: "X-Trace-ID")
      request.httpBody = try JSONSerialization.data(withJSONObject: [
        "password": secrets[7],
        "nested": ["access_token": secrets[8], "safe": "visible-nested-value"],
        "items": [["refreshToken": secrets[9], "dish": "visible-dish"]],
      ])
      let response = try XCTUnwrap(
        HTTPURLResponse(
          url: url, statusCode: 200, httpVersion: "HTTP/1.1",
          headerFields: [
            "Content-Type": "application/json", "Set-Cookie": "session=\(secrets[12])",
            "X-API-Key": secrets[13], "X-Trace-ID": "visible-response-trace",
          ]))
      let responseData = try JSONSerialization.data(withJSONObject: [
        "data": [["token": secrets[10], "nested": ["secret": secrets[11]]]],
        "message": "visible-response-value",
      ])

      let store = QFRequestLogStore(directoryURL: directoryURL)
      let id = store.begin(request: request)
      store.finish(id: id, response: response, data: responseData, error: nil)

      let entry = try XCTUnwrap(store.entry(id: id))
      let encodedEntry = try JSONEncoder().encode(entry)
      let displayedEntry = String(decoding: encodedEntry, as: UTF8.self)
      let persistedFiles = try regularFiles()
      XCTAssertFalse(persistedFiles.isEmpty, "The test must inspect actual persisted records")
      let persistedText = try persistedFiles.map {
        String(decoding: try Data(contentsOf: $0), as: UTF8.self)
      }.joined(separator: "\n")
      for secret in secrets {
        XCTAssertTrue(displayedEntry.contains(secret), "Debug value was removed: \(secret)")
        XCTAssertTrue(
          persistedText.contains(secret), "Persisted debug value was removed: \(secret)")
      }
      XCTAssertTrue(entry.url.contains("page=2"))
      XCTAssertTrue(entry.requestBody.contains("visible-nested-value"))
      XCTAssertTrue(entry.requestBody.contains("visible-dish"))
      XCTAssertTrue(entry.responseBody.contains("visible-response-value"))
      XCTAssertEqual(header("X-Trace-ID", in: entry.requestHeaders), "visible-request-trace")
      XCTAssertEqual(header("X-Trace-ID", in: entry.responseHeaders), "visible-response-trace")

      let restored = QFRequestLogStore(directoryURL: directoryURL)
      let restoredEntry = try XCTUnwrap(restored.entry(id: id))
      XCTAssertEqual(restoredEntry.requestBody, entry.requestBody)
      XCTAssertEqual(restoredEntry.responseBody, entry.responseBody)
    }

    @MainActor
    func testLoginSessionValuesAndJSONTypesRemainIntactOnDisk() throws {
      let store = QFRequestLogStore(directoryURL: directoryURL)
      let request = makeRequest(path: "auth/quick/sessions")
      let body = Data(
        #"{"session":{"accessToken":"fixture-access-token","accessTokenExpiresIn":7200,"refreshToken":"fixture-refresh-token","refreshTokenExpiresIn":2592000},"user":{"passwordConfigured":false}}"#
          .utf8)
      let id = store.begin(request: request)
      store.finish(id: id, response: nil, data: body, error: nil)
      let restored = QFRequestLogStore(directoryURL: directoryURL)
      let entry = try XCTUnwrap(restored.entry(id: id))
      struct Preview: Decodable {
        struct Session: Decodable {
          let accessToken: String
          let accessTokenExpiresIn: Int
          let refreshToken: String
          let refreshTokenExpiresIn: Int
        }
        struct User: Decodable { let passwordConfigured: Bool }
        let session: Session
        let user: User
      }
      let decoded = try JSONDecoder().decode(Preview.self, from: Data(entry.responseBody.utf8))
      XCTAssertEqual(decoded.session.accessToken, "fixture-access-token")
      XCTAssertEqual(decoded.session.accessTokenExpiresIn, 7200)
      XCTAssertEqual(decoded.session.refreshToken, "fixture-refresh-token")
      XCTAssertEqual(decoded.session.refreshTokenExpiresIn, 2_592_000)
      XCTAssertFalse(decoded.user.passwordConfigured)
      XCTAssertFalse(entry.responseBody.contains("[REDACTED]"))
    }

    @MainActor
    func testDefaultBodyLimitIncludesTruncationMarkerAndPreservesUTF8() throws {
      let store = QFRequestLogStore(directoryURL: directoryURL)
      let tail = "body-tail-must-be-truncated"
      let body = try JSONSerialization.data(
        withJSONObject: [
          "access_token": "large-json-token-secret",
          "message": "visible-prefix-" + String(repeating: "菜", count: 12_000) + tail,
          "password": "long-json-password-secret",
        ], options: [.sortedKeys])
      var request = makeRequest(path: "large-body")
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = body
      let response = try XCTUnwrap(
        HTTPURLResponse(
          url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]))

      let id = store.begin(request: request)
      store.finish(id: id, response: response, data: body, error: nil)

      let entry = try XCTUnwrap(store.entry(id: id))
      for preview in [entry.requestBody, entry.responseBody] {
        XCTAssertLessThanOrEqual(preview.utf8.count, 16 * 1024)
        XCTAssertGreaterThan(preview.utf8.count, 15 * 1024)
        XCTAssertTrue(preview.contains("visible-prefix-"))
        XCTAssertFalse(preview.contains(tail))
        XCTAssertTrue(preview.contains("large-json-token-secret"))
        XCTAssertFalse(preview.contains("\u{FFFD}"), "Truncation split a UTF-8 character")
      }
    }

    @MainActor
    func testDeviceAndAppleCredentialsAndEncodedFormsRemainReadable() throws {
      let secrets = [
        "device-secret-value", "authorization-code-value", "identity-token-value",
        "form-password-value", "nested-url-password", "nested-url-token", "inline-bearer-value",
      ]
      var request = makeRequest(path: "auth-fields")
      request.httpMethod = "POST"
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.httpBody = Data("%70assword=\(secrets[3])&device%53ecret=\(secrets[0])&page=2".utf8)
      let response = try XCTUnwrap(
        HTTPURLResponse(
          url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
          headerFields: ["Content-Type": "application/json"]))
      let data = try JSONSerialization.data(withJSONObject: [
        "deviceSecret": secrets[0],
        "nested": [["authorizationCode": secrets[1], "identityToken": secrets[2]]],
        "callback":
          "https://user:\(secrets[4])@example.invalid/?identityToken=\(secrets[5])&page=3",
        "message": "Authorization: Bearer \(secrets[6])",
      ])
      let store = QFRequestLogStore(directoryURL: directoryURL)
      let id = store.begin(request: request)
      store.finish(id: id, response: response, data: data, error: nil)
      let entry = try XCTUnwrap(store.entry(id: id))
      XCTAssertTrue(entry.requestBody.contains("page=2"))
      XCTAssertTrue(entry.responseBody.contains("page=3"))
      let fileContents = try regularFiles().map { try Data(contentsOf: $0) }
      for secret in secrets {
        XCTAssertTrue((entry.requestBody + entry.responseBody).contains(secret))
        for content in fileContents {
          XCTAssertTrue(String(decoding: content, as: UTF8.self).contains(secret))
        }
      }
    }

    @MainActor
    func testTextBodiesAndLocalizedTransportErrorsArePreserved() throws {
      let secret = "unstructured-test-value-visible-in-debug"
      var request = makeRequest(path: "multipart")
      request.setValue("multipart/form-data; boundary=test", forHTTPHeaderField: "Content-Type")
      request.httpBody = Data(
        "--test\r\nContent-Disposition: form-data; name=\"password\"\r\n\r\n\(secret)\r\n--test--"
          .utf8)
      let response = try XCTUnwrap(
        HTTPURLResponse(
          url: try XCTUnwrap(request.url), statusCode: 500, httpVersion: nil,
          headerFields: ["Content-Type": "text/plain"]))
      let error = NSError(
        domain: NSURLErrorDomain, code: -1,
        userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLStringErrorKey: secret])
      let store = QFRequestLogStore(directoryURL: directoryURL)
      let id = store.begin(request: request)
      store.finish(id: id, response: response, data: Data(secret.utf8), error: error)
      let entry = try XCTUnwrap(store.entry(id: id))
      XCTAssertTrue(entry.requestBody.contains(secret))
      XCTAssertTrue(entry.responseBody.contains(secret))
      XCTAssertTrue(try XCTUnwrap(entry.errorDescription).contains(secret))
      if case .failed = entry.status {} else { XCTFail("HTTP 500 must be a failed request") }
      for file in try regularFiles() {
        XCTAssertTrue(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(secret))
      }
    }

    @MainActor
    func testDirectoryIsExcludedFromBackupAndHTTPFailureNeedsNoTransportError() throws {
      let store = QFRequestLogStore(directoryURL: directoryURL)
      let values = try directoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
      XCTAssertEqual(values.isExcludedFromBackup, true)
      let request = makeRequest(path: "http-failure")
      let response = try XCTUnwrap(
        HTTPURLResponse(
          url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil))
      let id = store.begin(request: request)
      store.finish(id: id, response: response, data: nil, error: nil)
      let entry = try XCTUnwrap(store.entry(id: id))
      XCTAssertNil(entry.errorDescription)
      if case .failed = entry.status {} else { XCTFail("HTTP 401 must be a failed request") }
    }

    @MainActor
    func testPagesContainTwentyNewestRecordsAndKeepOrderAfterReload() throws {
      let store = QFRequestLogStore(directoryURL: directoryURL)
      let ids = (0..<45).map { store.begin(request: makeRequest(path: "page-\($0)")) }
      let newestFirst = Array(ids.reversed())

      XCTAssertEqual(store.page, 0)
      XCTAssertEqual(store.totalCount, 45)
      XCTAssertEqual(store.totalPages, 3)
      XCTAssertEqual(store.entries.map(\.id), Array(newestFirst[0..<20]))

      store.loadPage(1)
      XCTAssertEqual(store.page, 1)
      XCTAssertEqual(store.entries.map(\.id), Array(newestFirst[20..<40]))
      store.loadPage(2)
      XCTAssertEqual(store.page, 2)
      XCTAssertEqual(store.entries.map(\.id), Array(newestFirst[40..<45]))
      XCTAssertNotNil(
        store.entry(id: ids[44]), "Details must also load records outside the current page")

      let restored = QFRequestLogStore(directoryURL: directoryURL)
      XCTAssertEqual(restored.totalCount, 45)
      XCTAssertEqual(restored.totalPages, 3)
      XCTAssertEqual(restored.entries.map(\.id), Array(newestFirst[0..<20]))
      restored.loadPage(2)
      XCTAssertEqual(restored.entries.map(\.id), Array(newestFirst[40..<45]))
    }

    @MainActor
    func testEntryLimitEvictsOldestRecordsAndLateFinishDoesNotRestoreThem() throws {
      let store = QFRequestLogStore(directoryURL: directoryURL, maxEntries: 3)
      let ids = (0..<7).map { store.begin(request: makeRequest(path: "limit-\($0)")) }

      XCTAssertEqual(store.totalCount, 3)
      XCTAssertEqual(store.entries.map(\.id), Array(ids.suffix(3).reversed()))
      for id in ids.prefix(4) {
        XCTAssertNil(store.entry(id: id))
      }
      store.finish(id: ids[0], response: nil, data: nil, error: URLError(.cancelled))
      XCTAssertEqual(store.totalCount, 3)
      XCTAssertNil(store.entry(id: ids[0]))

      let restored = QFRequestLogStore(directoryURL: directoryURL, maxEntries: 3)
      XCTAssertEqual(restored.totalCount, 3)
      XCTAssertEqual(restored.entries.map(\.id), Array(ids.suffix(3).reversed()))
    }

    @MainActor
    func testDiskLimitEvictsRecordsAndNeverExceedsActualFileBudget() throws {
      let budget = 8 * 1024
      let store = QFRequestLogStore(
        directoryURL: directoryURL, maxEntries: 100, maxDiskBytes: budget)
      let body = try JSONSerialization.data(withJSONObject: [
        "message": String(repeating: "visible-body", count: 150)
      ])
      var ids: [UUID] = []
      for index in 0..<12 {
        var request = makeRequest(path: "disk-\(index)")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let id = store.begin(request: request)
        ids.append(id)
        XCTAssertLessThanOrEqual(try persistedByteCount(), budget)
        store.finish(id: id, response: nil, data: body, error: nil)
        XCTAssertLessThanOrEqual(try persistedByteCount(), budget)
      }

      XCTAssertGreaterThan(store.totalCount, 0)
      XCTAssertLessThan(store.totalCount, ids.count)
      XCTAssertNil(store.entry(id: ids[0]))
      XCTAssertNotNil(store.entry(id: try XCTUnwrap(ids.last)))
      let restored = QFRequestLogStore(
        directoryURL: directoryURL, maxEntries: 100, maxDiskBytes: budget)
      XCTAssertEqual(restored.totalCount, store.totalCount)
      XCTAssertEqual(restored.entries.map(\.id), store.entries.map(\.id))
      XCTAssertLessThanOrEqual(try persistedByteCount(), budget)
    }

    @MainActor
    func testSingleRecordLargerThanDiskBudgetCannotBreakLimit() throws {
      let budget = 512
      let store = QFRequestLogStore(directoryURL: directoryURL, maxDiskBytes: budget)
      var request = makeRequest(path: "oversized-record")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: [
        "message": String(repeating: "visible-body", count: 300)
      ])
      let id = store.begin(request: request)
      XCTAssertLessThanOrEqual(try persistedByteCount(), budget)
      store.finish(id: id, response: nil, data: request.httpBody, error: nil)
      XCTAssertLessThanOrEqual(try persistedByteCount(), budget)
    }

    private func makeRequest(path: String) -> URLRequest {
      URLRequest(url: URL(string: "https://example.invalid/\(path)")!)
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
      headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func regularFiles() throws -> [URL] {
      let enumerator = try XCTUnwrap(
        FileManager.default.enumerator(
          at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey]))
      var files: [URL] = []
      for case let url as URL in enumerator {
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
          files.append(url)
        }
      }
      return files
    }

    private func persistedByteCount() throws -> Int {
      try regularFiles().reduce(0) { total, url in
        total + (try Data(contentsOf: url).count)
      }
    }
  }
#endif
