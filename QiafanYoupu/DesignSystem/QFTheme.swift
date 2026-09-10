import SwiftUI

enum QFTheme {
  static let background = Color(hex: 0xF8F8F3)
  static let text = Color(hex: 0x202A25)
  static let secondary = Color(hex: 0x788176)
  static let orange = Color(hex: 0xF46236)
  static let green = Color(hex: 0x5D754E)
  static let paleGreen = Color(hex: 0xEDF2E5)
  static let border = Color(hex: 0xE3E7DC)
}

extension Color {
  init(hex: UInt) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255, opacity: 1)
  }
}
