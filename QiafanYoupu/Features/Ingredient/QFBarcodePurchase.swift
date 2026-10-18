import CoreFoundation
import Foundation

enum QFBarcodeLookupState: String {
  case found, notFound, unavailable, rateLimited, localOnly, skipped
}

struct QFBarcodeProductInfo: Equatable {
  struct NetContent: Equatable {
    let value: String
    let unit: String
  }
  let name: String?
  let packageLabel: String?
  let netContent: NetContent?
  static func read(_ data: Data, requestedCode: String, language: String) throws -> Self? {
    guard data.count <= 256 * 1024,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["status"] as? String == "success",
      let product = object["product"] as? [String: Any],
      let code = product["code"] as? String,
      let expected = canonical(requestedCode), canonical(code) == expected else { return nil }
    let base = language == "pt-BR" ? "pt" : language.hasPrefix("zh") ? "zh" : language
    // Package product names are a reference to review, not an approved catalogue translation.
    let name = ["product_name_" + base, "product_name"].compactMap {
      clean(product[$0] as? String, limit: 100)
    }.first
    let label = clean(product["quantity"] as? String, limit: 120)
    let contents = content(product, label: label)
    guard name != nil || label != nil || contents != nil else { return nil }
    return .init(name: name, packageLabel: label, netContent: contents)
  }
  private static func clean(_ raw: String?, limit: Int) -> String? {
    guard let raw else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf16.count <= limit,
      value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
    return value
  }
  private static func content(_ product: [String: Any], label: String?) -> NetContent? {
    // The API has returned both numbers and strings. Reject booleans and malformed
    // structured values rather than silently turning them into package weights.
    if let raw = product["product_quantity"] {
      let value: String?
      if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        value = number.stringValue
      } else { value = raw as? String }
      guard let value, let unit = product["product_quantity_unit"] as? String else { return nil }
      return validatedContent(value, unit: unit)
    }
    // A single explicit mass/volume is usable; multipacks remain a reference
    // label. Never multiply a package label into the number of items bought.
    guard let label,
      let regex = try? NSRegularExpression(pattern: #"^([0-9]{1,9}(?:[.,][0-9]{1,6})?)\s*(kg|g|ml|l)\s*(?:℮|e)?$"#, options: .caseInsensitive),
      let match = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
      let number = Range(match.range(at: 1), in: label), let unit = Range(match.range(at: 2), in: label) else { return nil }
    return validatedContent(String(label[number]).replacingOccurrences(of: ",", with: "."), unit: String(label[unit]))
  }
  private static func validatedContent(_ raw: String, unit: String) -> NetContent? {
    let normalizedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard ["g", "kg", "ml", "l"].contains(normalizedUnit),
      let number = QFPurchaseNumber.decimal(raw), number > 0 else { return nil }
    return .init(value: QFPurchaseNumber.string(number), unit: normalizedUnit)
  }
  private static func canonical(_ code: String) -> String? {
    guard [8, 12, 13, 14].contains(code.utf8.count), code.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return String(repeating: "0", count: 14 - code.utf8.count) + code
  }
}

extension QFPurchaseReceiptLine {
  static func scannedProduct(barcode: QFProductBarcode, name: String? = nil, source: String? = nil,
    info: QFBarcodeProductInfo? = nil, lookupState: QFBarcodeLookupState = .skipped) -> Self {
    var line = Self(ingredientId: nil, name: name ?? "")
    line.quantity = "1" // Editable starting count, never extracted from code/pack size.
    line.unitCode = "pack"
    line.packageUnit = "pack"
    line.scanBarcode = barcode.value
    line.scanBarcodeSymbology = barcode.symbology
    line.scanProductSource = source
    line.applyBarcodeInfo(info, status: info == nil ? lookupState : .found)
    return line
  }
  mutating func applyBarcodeInfo(_ info: QFBarcodeProductInfo?, status: QFBarcodeLookupState) {
    scanLookupState = status.rawValue
    guard let info else { return }
    scanProductSource = "OPEN_FOOD_FACTS"
    scanPackageLabel = info.packageLabel
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = info.name ?? "" }
    if packageSize == nil, packageContentUnit == nil,
      ["box", "bottle", "bag", "pack"].contains(unitCode), let contents = info.netContent {
      packageSize = contents.value; packageContentUnit = contents.unit; packageUnit = unitCode
    }
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
