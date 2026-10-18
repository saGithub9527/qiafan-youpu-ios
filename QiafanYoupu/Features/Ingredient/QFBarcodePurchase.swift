import Foundation

struct QFBarcodeProductInfo: Equatable {
  let name: String
  static func read(_ data: Data, requestedCode: String, language: String) throws -> Self? {
    guard data.count <= 256 * 1024,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["status"] as? String == "success",
      let product = object["product"] as? [String: Any],
      let code = product["code"] as? String,
      let expected = canonical(requestedCode), canonical(code) == expected else { return nil }
    let base = language == "pt-BR" ? "pt" : language.hasPrefix("zh") ? "zh" : language
    // Package product names are a reference to review, not an approved catalogue translation.
    for field in ["product_name_" + base, "product_name"] {
      guard let raw = product[field] as? String else { continue }
      let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty, name.utf16.count <= 100,
        name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
        return .init(name: name)
      }
    }
    return nil
  }
  private static func canonical(_ code: String) -> String? {
    guard [8, 12, 13, 14].contains(code.utf8.count), code.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return String(repeating: "0", count: 14 - code.utf8.count) + code
  }
}

extension QFPurchaseReceiptLine {
  static func scannedProduct(barcode: QFProductBarcode, name: String? = nil, source: String? = nil) -> Self {
    var line = Self(ingredientId: nil, name: name ?? "")
    line.quantity = "1" // Editable starting count, never extracted from code/pack size.
    line.unitCode = "piece"
    line.scanBarcode = barcode.value
    line.scanProductSource = source
    return line
  }
}

extension QFPurchaseReceiptDraft {
  enum ScannedProductAddition { case added, duplicate, locked, full }
  mutating func addScannedProduct(_ line: QFPurchaseReceiptLine) -> ScannedProductAddition {
    guard pending == nil else { return .locked }
    guard !items.contains(where: { $0.id == line.id || (line.scanBarcode != nil && $0.scanBarcode == line.scanBarcode) }) else { return .duplicate }
    guard items.count < 40 else { return .full }
    items.append(line)
    return .added
  }
}
