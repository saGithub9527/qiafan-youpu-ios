import UIKit

enum QFAdaptiveLayout {
  static let contentMaxWidth: CGFloat = 760
  static let formMaxWidth: CGFloat = 520

  // These thresholds describe the current container, including resized iPad windows.
  static func isCompactWidth(_ width: CGFloat) -> Bool { width < 360 }
  static func isCompactHeight(_ height: CGFloat) -> Bool { height < 500 }
}
