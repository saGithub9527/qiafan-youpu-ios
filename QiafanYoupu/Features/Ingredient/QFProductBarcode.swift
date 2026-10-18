import Foundation

/// A scanned identifier, never a source of a purchase quantity or price.
/// `lookupCode` is only an eligible GTIN, not proof that a product exists or is food.
struct QFProductBarcode: Codable, Equatable {
  let value: String
  let symbology: String
  let lookupCode: String?

  init?(value: String, symbology: String) {
    guard !value.isEmpty, value.utf8.count <= 80 else { return nil }
    let candidate: String?
    switch symbology {
    case "EAN13", "EAN8":
      guard let digits = Self.digits(value, count: symbology == "EAN13" ? 13 : 8),
            Self.hasValidCheckDigit(digits) else { return nil }
      candidate = value
    case "UPCE":
      guard let digits = Self.digits(value, count: 8),
            let expanded = Self.expandUPCE(digits),
            Self.hasValidCheckDigit(expanded) else { return nil }
      candidate = "0" + expanded.map(String.init).joined()
    case "CODE128":
      guard Self.isSafeIdentifier(value) else { return nil }
      candidate = nil
    default:
      return nil
    }
    self.value = value
    self.symbology = symbology
    lookupCode = candidate.flatMap { Self.isRestricted($0) ? nil : $0 }
  }

  private enum CodingKeys: String, CodingKey { case value, symbology, lookupCode }

  /// Persisted derived fields cannot bypass the same validation used by scanning.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let value = try container.decode(String.self, forKey: .value)
    let symbology = try container.decode(String.self, forKey: .symbology)
    guard let validated = Self(value: value, symbology: symbology) else {
      throw DecodingError.dataCorruptedError(
        forKey: .value, in: container, debugDescription: "Invalid product barcode")
    }
    self = validated
  }

  private static func digits(_ value: String, count: Int) -> [Int]? {
    let bytes = Array(value.utf8)
    guard bytes.count == count, bytes.allSatisfy({ (48...57).contains($0) }) else {
      return nil
    }
    return bytes.map { Int($0 - 48) }
  }

  private static func hasValidCheckDigit(_ digits: [Int]) -> Bool {
    guard digits.contains(where: { $0 != 0 }) else { return false }
    let total = digits.reversed().enumerated().reduce(0) { result, item in
      result + item.element * (item.offset.isMultiple(of: 2) ? 1 : 3)
    }
    return total.isMultiple(of: 10)
  }

  /// Reverse GS1 General Specifications 5.2.2.4.1 zero suppression.
  /// GS1 UPC-E uses number system 0; require its full eight digits, including check.
  /// https://ref.gs1.org/standards/genspecs/24.0.0/ (pages 261–262).
  private static func expandUPCE(_ d: [Int]) -> [Int]? {
    guard d[0] == 0 else { return nil }
    switch d[6] {
    case 0...2:
      return [d[0], d[1], d[2], d[6], 0, 0, 0, 0, d[3], d[4], d[5], d[7]]
    case 3:
      guard d[3] >= 3 else { return nil }
      return [d[0], d[1], d[2], d[3], 0, 0, 0, 0, 0, d[4], d[5], d[7]]
    case 4:
      guard d[4] != 0 else { return nil }
      return [d[0], d[1], d[2], d[3], d[4], 0, 0, 0, 0, 0, d[5], d[7]]
    default:
      guard d[5] != 0 else { return nil }
      return [d[0], d[1], d[2], d[3], d[4], d[5], 0, 0, 0, 0, d[6], d[7]]
    }
  }

  private static func isRestricted(_ code: String) -> Bool {
    // Retailer-local 20–29 codes and both zero-padded representations of UPC 02
    // stay on-device. Their digits must not be guessed to encode price or weight.
    code.hasPrefix("2") || (code.count == 13 && (code.hasPrefix("02") || code.hasPrefix("002")))
  }

  private static func isSafeIdentifier(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    func isAlphanumeric(_ byte: UInt8) -> Bool {
      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
    guard let first = bytes.first, let last = bytes.last,
          isAlphanumeric(first), isAlphanumeric(last),
          !value.lowercased().hasPrefix("www."), !value.contains("//") else { return false }
    return bytes.allSatisfy { isAlphanumeric($0) || [32, 45, 46, 47, 95].contains($0) }
  }
}
