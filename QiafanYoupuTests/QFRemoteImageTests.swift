import Kingfisher
import UIKit
import XCTest

@testable import QiafanYoupu

private final class QFImageFailureProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "images.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
  }
  override func stopLoading() {}
}

private final class QFImageSuccessProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var bytes = Data()
  static func configure(_ data: Data) { lock.lock(); bytes = data; lock.unlock() }
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "deferred-images.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock(); let data = Self.bytes; Self.lock.unlock()
    // Match a real HTTPS response. Kingfisher rejects a plain URLResponse before caching.
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "image/png", "Content-Length": String(data.count)])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

/// Delay the SDK's real store operation, so a write lands after account invalidation.
private final class QFDelayedAvatarCache: ImageCache, @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [() -> Void] = []
  var onPending: (() -> Void)?
  var onRemoved: ((String) -> Void)?
  override func store(_ image: UIImage, original: Data? = nil, forKey key: String,
    options: KingfisherParsedOptionsInfo, toDisk: Bool = true,
    completionHandler: (@Sendable (CacheStoreResult) -> Void)? = nil) {
    lock.lock()
    pending.append { [self] in finishStore(image, original: original, forKey: key, options: options, toDisk: toDisk, completionHandler: completionHandler) }
    let notification = onPending; lock.unlock(); notification?()
  }
  private func finishStore(_ image: UIImage, original: Data?, forKey key: String,
    options: KingfisherParsedOptionsInfo, toDisk: Bool,
    completionHandler: (@Sendable (CacheStoreResult) -> Void)?) {
    super.store(image, original: original, forKey: key, options: options, toDisk: toDisk, completionHandler: completionHandler)
  }
  func releasePending() {
    lock.lock(); let work = pending; pending.removeAll(); lock.unlock()
    work.forEach { $0() }
  }
  override func removeImage(forKey key: String, processorIdentifier identifier: String = "",
    forcedExtension: String? = nil, fromMemory: Bool = true, fromDisk: Bool = true,
    callbackQueue: CallbackQueue = .untouch, completionHandler: (@Sendable () -> Void)? = nil) {
    super.removeImage(forKey: key, processorIdentifier: identifier, forcedExtension: forcedExtension,
      fromMemory: fromMemory, fromDisk: fromDisk, callbackQueue: callbackQueue) { [weak self] in
        completionHandler?(); self?.onRemoved?(key)
      }
  }
}

final class QFRemoteImageTests: XCTestCase {
  private var directory: URL!
  private var cache: ImageCache!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("QFRemoteImageTests-\(UUID().uuidString)", isDirectory: true)
    cache = try ImageCache(name: "isolated", cacheDirectoryURL: directory)
    cache.memoryStorage.config.totalCostLimit = 1024 * 1024
    cache.diskStorage.config.sizeLimit = 4 * 1024 * 1024
  }

  override func tearDownWithError() throws {
    cache.clearMemoryCache()
    cache = nil
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
    directory = nil
    try super.tearDownWithError()
  }

  func testOnlyAbsoluteHTTPSWithoutCredentialsIsAccepted() throws {
    XCTAssertNotNil(request("https://images.invalid/avatar.png"))
    let invalid: [String?] = [
      nil, "", "/avatar.png", "file:///tmp/avatar.png", "http://images.invalid/avatar.png",
      "https://user:password@images.invalid/avatar.png", "https://images.invalid/a b",
      "https://images.invalid:99999/avatar.png",
    ]
    for url in invalid { XCTAssertNil(request(url)) }
    XCTAssertFalse(
      QFRemoteImageRequest.isAllowedURL(URL(string: "http://images.invalid/redirect")!))
  }

  func testCacheIdentityIncludesAccountEnvironmentAndAPIEndpoint() throws {
    let original = try XCTUnwrap(request())
    XCTAssertEqual(original.cacheKey, try XCTUnwrap(request()).cacheKey)
    let otherScopes = [
      request(user: "user-b"), request(environment: "production"),
      request(base: "https://other-api.invalid"), request("https://images.invalid/other.png"),
    ]
    for scoped in otherScopes {
      XCTAssertNotEqual(original.cacheKey, try XCTUnwrap(scoped).cacheKey)
    }
  }

  @MainActor
  func testSDKDiskRoundTripAndCrossUserCacheMiss() async throws {
    let original = try XCTUnwrap(request())
    let otherUser = try XCTUnwrap(request(user: "user-b"))
    let image = makeImage(.orange)
    let stored = expectation(description: "SDK writes isolated disk cache")
    cache.store(image, original: image.pngData(), forKey: original.cacheKey) { result in
      if case .failure = result.diskCacheResult { XCTFail("Image cache write failed") }
      stored.fulfill()
    }
    await fulfillment(of: [stored], timeout: 5)
    XCTAssertNotNil(cache.retrieveImageInMemoryCache(forKey: original.cacheKey))
    cache.clearMemoryCache()
    let hit = try await read(original.cacheKey)
    XCTAssertEqual(hit.cacheType, .disk)
    XCTAssertEqual(hit.image?.size, image.size)
    let miss = try await read(otherUser.cacheKey)
    XCTAssertEqual(miss.cacheType, .none)
    XCTAssertNil(miss.image)
    XCTAssertTrue(cache.diskStorage.directoryURL.path.hasPrefix(directory.path))
  }

  @MainActor
  func testDownloadFailureKeepsTheOriginalPlaceholder() async throws {
    let downloader = ImageDownloader(name: "QFRemoteImageTests-\(UUID().uuidString)")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QFImageFailureProtocol.self]
    configuration.urlCache = nil
    downloader.sessionConfiguration = configuration
    let imageView = QFRemoteImageView()
    let placeholder = makeImage(.green)
    let completed = expectation(description: "Image failure restores placeholder")
    imageView.load(
      try XCTUnwrap(request()), placeholder: placeholder, size: CGSize(width: 2, height: 2),
      cache: cache, downloader: downloader
    ) { succeeded in
      XCTAssertFalse(succeeded)
      XCTAssertEqual(imageView.image?.pngData(), placeholder.pngData())
      XCTAssertEqual(imageView.contentMode, .scaleAspectFit)
      completed.fulfill()
    }
    await fulfillment(of: [completed], timeout: 5)
  }

  @MainActor
  func testLateDeletedOwnerWriteIsRemovedWithoutCancellingAnotherAccount() async throws {
    let target = try XCTUnwrap(request("https://deferred-images.invalid/avatar.png"))
    let other = try XCTUnwrap(request("https://deferred-images.invalid/avatar.png", user: "unaffected-owner"))
    let delayed = try QFDelayedAvatarCache(name: "late-avatar", cacheDirectoryURL: directory)
    let downloader = ImageDownloader(name: "QFG09Avatar-\(UUID().uuidString)")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QFImageSuccessProtocol.self]; configuration.urlCache = nil
    downloader.sessionConfiguration = configuration
    QFImageSuccessProtocol.configure(try XCTUnwrap(makeImage(.orange).pngData()))
    let pending = expectation(description: "Both scoped SDK stores are waiting")
    pending.expectedFulfillmentCount = 2
    let removed = expectation(description: "The late deleted scope write is removed")
    let otherFinished = expectation(description: "The other account still completes")
    delayed.onPending = { pending.fulfill() }
    delayed.onRemoved = { key in if key == target.cacheKey { removed.fulfill() } }
    let targetView = QFRemoteImageView(), otherView = QFRemoteImageView()
    targetView.load(target, placeholder: nil, size: CGSize(width: 2, height: 2), cache: delayed, downloader: downloader)
    otherView.load(other, placeholder: nil, size: CGSize(width: 2, height: 2), cache: delayed, downloader: downloader) { loaded in
      XCTAssertTrue(loaded); otherFinished.fulfill()
    }
    await fulfillment(of: [pending], timeout: 5)
    QFRemoteImagePipeline.invalidateForDeletedAccount(account: target.accountScope, cache: delayed)
    delayed.releasePending()
    await fulfillment(of: [removed, otherFinished], timeout: 5)
    let processor = DownsamplingImageProcessor(size: CGSize(width: 2, height: 2))
    XCTAssertFalse(delayed.isCached(forKey: target.cacheKey, processorIdentifier: processor.identifier))
    XCTAssertTrue(delayed.isCached(forKey: other.cacheKey, processorIdentifier: processor.identifier))
    XCTAssertNil(targetView.image)
    XCTAssertNotNil(otherView.image)
    downloader.cancelAll()
  }

  private func request(
    _ url: String? = "https://images.invalid/avatar.png", user: String = "user-a",
    environment: String = "test", base: String = "https://api.invalid"
  ) -> QFRemoteImageRequest? {
    QFRemoteImageRequest(
      urlString: url, environment: environment, apiBaseURL: URL(string: base), userID: user)
  }

  private func read(_ key: String) async throws -> ImageCacheResult {
    try await withCheckedThrowingContinuation { continuation in
      cache.retrieveImage(forKey: key) { result in continuation.resume(with: result) }
    }
  }

  @MainActor
  private func makeImage(_ color: UIColor) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image {
      context in
      color.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
  }
}
