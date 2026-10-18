import Alamofire
import Foundation

/// Anonymous, bounded product-name lookup. No app auth, photos, history or prices.
@MainActor
final class QFBarcodeProductLookup {
  static let shared = QFBarcodeProductLookup()
  private let transport = QFAPIClient.makeTransport(configuration: .ephemeral, requestTimeout: 6, resourceTimeout: 8)
  private let cache = NSCache<NSString, Entry>()
  private var started: [Date] = []
  private var blockedUntil = Date.distantPast
  private final class Entry: NSObject {
    let value: QFBarcodeProductInfo?
    let expires: Date
    init(_ value: QFBarcodeProductInfo?) { self.value = value; expires = Date().addingTimeInterval(600) }
  }
  enum Failure: Error { case rateLimited, unavailable }
  init() { cache.countLimit = 64 }
  func name(for barcode: QFProductBarcode, language: String) async throws -> QFBarcodeProductInfo? {
    guard let code = barcode.lookupCode else { return nil }
    let key = (language + "|" + code) as NSString
    if let hit = cache.object(forKey: key), hit.expires > Date() { return hit.value }
    started.removeAll { Date().timeIntervalSince($0) >= 60 }
    guard Date() >= blockedUntil, started.count < 15 else { throw Failure.rateLimited }
    started.append(Date())
    var components = URLComponents(string: "https://world.openfoodfacts.org/api/v3/product/" + code)!
    let base = language == "pt-BR" ? "pt" : language.hasPrefix("zh") ? "zh" : language
    components.queryItems = [URLQueryItem(name: "fields", value: "code,product_name,product_name_" + base), URLQueryItem(name: "lc", value: base)]
    var request = URLRequest(url: components.url!)
    request.setValue("QiafanYoupu/1.0 (iOS; barcode-food-name)", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let response = await transport.request(request).serializingData(automaticallyCancelling: true).response
    try Task.checkCancellation()
    if response.response?.statusCode == 429 {
      blockedUntil = Date().addingTimeInterval(60); throw Failure.rateLimited
    }
    if response.response?.statusCode == 404 { cache.setObject(Entry(nil), forKey: key); return nil }
    guard response.error == nil, let status = response.response?.statusCode, (200..<300).contains(status),
      let bytes = response.data, bytes.count <= 256 * 1024 else { throw Failure.unavailable }
    let value = try QFBarcodeProductInfo.read(bytes, requestedCode: code, language: language)
    cache.setObject(Entry(value), forKey: key)
    return value
  }
}
