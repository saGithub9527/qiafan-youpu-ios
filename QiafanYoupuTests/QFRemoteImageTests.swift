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
