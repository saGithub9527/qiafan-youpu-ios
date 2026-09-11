import CryptoKit
import Foundation
import Kingfisher
import UIKit

/// An image resource belongs to one API environment and one user, even when its URL is shared.
struct QFRemoteImageRequest: Hashable, Sendable {
  let url: URL
  let cacheKey: String

  init?(urlString: String?, environment: String, apiBaseURL: URL?, userID: String) {
    guard !environment.isEmpty, !userID.isEmpty,
      let urlString, urlString.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      let url = URL(string: urlString), Self.isAllowedURL(url)
    else { return nil }
    self.url = url
    let parts = [
      "qf-avatar-v1", environment, apiBaseURL?.absoluteString ?? "", userID, url.absoluteString,
    ]
    let scopedKey = parts.map { "\($0.utf8.count):\($0)" }.joined()
    cacheKey = SHA256.hash(data: Data(scopedKey.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  static func isAllowedURL(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https"
      && !(url.host ?? "").isEmpty
      && url.user == nil && url.password == nil
      && (url.port.map { (1...65_535).contains($0) } ?? true)
  }
}

/// UIKit-only adapter; Kingfisher owns cancellation, decoding and cache lookup.
@MainActor
final class QFRemoteImageView: UIImageView {
  private var requestID = UUID()

  func load(
    _ request: QFRemoteImageRequest?, placeholder: UIImage?, size: CGSize,
    cache: ImageCache? = nil, downloader: ImageDownloader? = nil,
    completion: (@MainActor @Sendable (Bool) -> Void)? = nil
  ) {
    let identifier = UUID()
    requestID = identifier
    kf.cancelDownloadTask()
    image = placeholder
    contentMode = .scaleAspectFit
    guard let request else {
      // Reset Kingfisher's source identifier too, so a late old response cannot replace this placeholder.
      kf.setImage(with: Optional<Source>.none, placeholder: placeholder)
      completion?(false)
      return
    }
    let targetCache = cache ?? QFRemoteImagePipeline.cache
    let targetDownloader = downloader ?? QFRemoteImagePipeline.downloader
    let redirect = AnyRedirectHandler { _, _, newRequest, handler in
      guard let url = newRequest.url, QFRemoteImageRequest.isAllowedURL(url) else {
        handler(nil)
        return
      }
      handler(newRequest)
    }
    let options: KingfisherOptionsInfo = [
      .targetCache(targetCache), .downloader(targetDownloader),
      .processor(DownsamplingImageProcessor(size: size)),
      .scaleFactor(max(1, window?.screen.scale ?? traitCollection.displayScale)),
      .diskStoreWriteOptions([.atomic, .completeFileProtectionUntilFirstUserAuthentication]),
      .waitForCache, .redirectHandler(redirect),
    ]
    kf.setImage(
      with: KF.ImageResource(downloadURL: request.url, cacheKey: request.cacheKey),
      placeholder: placeholder, options: options
    ) { [weak self] result in
      guard let self, self.requestID == identifier else { return }
      switch result {
      case .success:
        self.contentMode = .scaleAspectFill
        // waitForCache ensures disk-budget cleanup also happens after foreground writes.
        targetCache.cleanExpiredDiskCache()
        completion?(true)
      case .failure:
        self.image = placeholder
        self.contentMode = .scaleAspectFit
        completion?(false)
      }
    }
  }
}

enum QFRemoteImagePipeline {
  // One bounded cache for all namespaces avoids multiplying budgets for previously used accounts.
  static let memoryLimit = 8 * 1024 * 1024
  static let diskLimit: UInt = 32 * 1024 * 1024

  static let cache: ImageCache = {
    let cache = ImageCache(name: "qf-avatar-v1")
    cache.memoryStorage.config.totalCostLimit = memoryLimit
    cache.memoryStorage.config.countLimit = 100
    cache.memoryStorage.config.expiration = .seconds(300)
    cache.diskStorage.config.sizeLimit = diskLimit
    cache.diskStorage.config.expiration = .days(7)
    cache.cleanExpiredDiskCache()
    return cache
  }()

  static let downloader: ImageDownloader = {
    let downloader = ImageDownloader(name: "qf-avatar-v1")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForResource = 30
    downloader.sessionConfiguration = configuration
    downloader.downloadTimeout = 15
    // Avatar URLs use their own HTTPS transport; API credentials and Device-Id are never forwarded.
    return downloader
  }()
}
