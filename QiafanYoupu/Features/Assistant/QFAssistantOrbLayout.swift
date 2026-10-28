import UIKit

/// Scene-local geometry only. A temporary keyboard clamp never rewrites the
/// saved relative position, so dismissing it restores the user's placement.
struct QFAssistantOrbLayout {
  static let buttonSize = CGSize(width: 92, height: 112)
  static let backEdgeWidth: CGFloat = 20
  let safeBounds: CGRect
  private let keyboardFrame: CGRect?

  enum BubbleSide: Equatable { case left, right, above, below }
  struct BubblePlacement: Equatable {
    let frame: CGRect
    let side: BubbleSide
  }

  init(bounds: CGRect, safeAreaInsets: UIEdgeInsets, keyboardFrame: CGRect? = nil) {
    let left = min(max(0, safeAreaInsets.left), max(0, bounds.width))
    let top = min(max(0, safeAreaInsets.top), max(0, bounds.height))
    safeBounds = CGRect(x: bounds.minX + left, y: bounds.minY + top,
      width: max(0, bounds.width - left - max(0, safeAreaInsets.right)),
      height: max(0, bounds.height - top - max(0, safeAreaInsets.bottom)))
    if let keyboardFrame, !keyboardFrame.isNull, !keyboardFrame.isEmpty,
       keyboardFrame.intersects(safeBounds) {
      self.keyboardFrame = keyboardFrame.insetBy(dx: -8, dy: -8)
    } else { self.keyboardFrame = nil }
  }

  func orbFrame(relativePosition: CGPoint?) -> CGRect {
    let size = fittedButtonSize(in: safeBounds)
    let center: CGPoint
    if let relativePosition {
      center = CGPoint(x: safeBounds.minX + size.width / 2 + max(0, safeBounds.width - size.width) * unit(relativePosition.x),
        y: safeBounds.minY + size.height / 2 + max(0, safeBounds.height - size.height) * unit(relativePosition.y))
    } else {
      // The first presentation retains the established trailing14/bottom126.
      let keyboardTop = keyboardFrame.map { $0.minY + 8 } ?? safeBounds.maxY
      center = CGPoint(x: safeBounds.maxX - 14 - size.width / 2,
        y: min(safeBounds.maxY, keyboardTop) - 126 - size.height / 2)
    }
    return orbFrame(center: center)
  }

  func orbFrame(center: CGPoint) -> CGRect {
    var best: CGRect?
    var bestScale: CGFloat = -1
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for region in unobstructedRegions(in: safeBounds) {
      let size = fittedButtonSize(in: region)
      guard size.width > 0, size.height > 0 else { continue }
      let frame = CGRect(x: clamp(center.x - size.width / 2, region.minX, region.maxX - size.width),
        y: clamp(center.y - size.height / 2, region.minY, region.maxY - size.height), width: size.width, height: size.height)
      let scale = size.width / Self.buttonSize.width
      let dx = frame.midX - center.x, dy = frame.midY - center.y
      let distance = dx * dx + dy * dy
      if scale > bestScale || (scale == bestScale && distance < bestDistance) {
        best = frame; bestScale = scale; bestDistance = distance
      }
    }
    return best ?? CGRect(origin: safeBounds.origin, size: .zero)
  }

  func relativePosition(for frame: CGRect) -> CGPoint {
    let width = safeBounds.width - frame.width, height = safeBounds.height - frame.height
    return CGPoint(x: width > 0 ? unit((frame.minX - safeBounds.minX) / width) : 0.5,
      y: height > 0 ? unit((frame.minY - safeBounds.minY) / height) : 0.5)
  }

  /// Measure at the actual candidate width; only the viewport is capped. The
  /// speech view retains the complete label inside its native scroll view.
  func bubblePlacement(near orb: CGRect, sizeThatFits: (CGSize) -> CGSize) -> BubblePlacement? {
    guard orb.width > 0, orb.height > 0 else { return nil }
    let bounds = safeBounds.insetBy(dx: min(18, safeBounds.width / 2), dy: min(8, safeBounds.height / 2))
    let gap: CGFloat = 8
    let left = CGRect(x: bounds.minX, y: bounds.minY, width: max(0, orb.minX - gap - bounds.minX), height: bounds.height)
    let rightX = max(bounds.minX, orb.maxX + gap)
    let right = CGRect(x: rightX, y: bounds.minY, width: max(0, bounds.maxX - rightX), height: bounds.height)
    let above = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, orb.minY - gap - bounds.minY))
    let belowY = max(bounds.minY, orb.maxY + gap)
    let below = CGRect(x: bounds.minX, y: belowY, width: bounds.width, height: max(0, bounds.maxY - belowY))
    let sides: [(BubbleSide, CGRect)] = orb.midX >= bounds.midX ? [(.left, left), (.right, right)] : [(.right, right), (.left, left)]
    let vertical: [(BubbleSide, CGRect)] = above.height >= below.height ? [(.above, above), (.below, below)] : [(.below, below), (.above, above)]
    let roomySides = sides.filter { $0.1.width >= min(160, bounds.width) }
    for (side, area) in roomySides + vertical + sides {
      let regions = unobstructedRegions(in: area).sorted { $0.width * $0.height > $1.width * $1.height }
      for region in regions where region.width >= 44 && region.height >= 44 {
        let limit = CGSize(width: min(240, region.width), height: region.height)
        let measured = sizeThatFits(limit)
        let size = CGSize(width: min(limit.width, max(0, measured.width)), height: min(limit.height, max(0, measured.height)))
        guard size.width > 0, size.height > 0 else { continue }
        let origin: CGPoint
        switch side {
        case .left: origin = CGPoint(x: orb.minX - gap - size.width, y: orb.midY - 12 - size.height / 2)
        case .right: origin = CGPoint(x: orb.maxX + gap, y: orb.midY - 12 - size.height / 2)
        case .above: origin = CGPoint(x: orb.midX - size.width / 2, y: orb.minY - gap - size.height)
        case .below: origin = CGPoint(x: orb.midX - size.width / 2, y: orb.maxY + gap)
        }
        return BubblePlacement(frame: CGRect(x: clamp(origin.x, region.minX, region.maxX - size.width),
          y: clamp(origin.y, region.minY, region.maxY - size.height), width: size.width, height: size.height), side: side)
      }
    }
    return nil
  }

  /// Keep both physical edge strips available to the host window's native
  /// navigation gestures. The rest of the transparent window stays passthrough.
  static func isBackEdge(_ point: CGPoint, in bounds: CGRect) -> Bool {
    point.x < bounds.minX + backEdgeWidth || point.x > bounds.maxX - backEdgeWidth
  }

  @MainActor
  static func makePanRecognizer(target: Any?, action: Selector?) -> UIPanGestureRecognizer {
    let pan = UIPanGestureRecognizer(target: target, action: action)
    pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 1
    pan.cancelsTouchesInView = true
    return pan
  }

  static func allowsActivation(panState: UIGestureRecognizer.State) -> Bool {
    panState == .possible || panState == .failed
  }

  private func fittedButtonSize(in rect: CGRect) -> CGSize {
    let scale = max(0, min(1, min(rect.width / Self.buttonSize.width, rect.height / Self.buttonSize.height)))
    return CGSize(width: Self.buttonSize.width * scale, height: Self.buttonSize.height * scale)
  }

  private func unobstructedRegions(in rect: CGRect) -> [CGRect] {
    guard !rect.isEmpty else { return [] }
    guard let keyboardFrame else { return [rect] }
    let cut = rect.intersection(keyboardFrame)
    guard !cut.isNull, !cut.isEmpty else { return [rect] }
    return [
      CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, cut.minY - rect.minY)),
      CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: max(0, rect.maxY - cut.maxY)),
      CGRect(x: rect.minX, y: rect.minY, width: max(0, cut.minX - rect.minX), height: rect.height),
      CGRect(x: cut.maxX, y: rect.minY, width: max(0, rect.maxX - cut.maxX), height: rect.height)
    ].filter { !$0.isEmpty }
  }

  private func unit(_ value: CGFloat) -> CGFloat { value.isFinite ? min(1, max(0, value)) : 0.5 }
  private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(max(value.isFinite ? value : lower, lower), max(lower, upper))
  }
}

/// A normal transparent UIView with a layout callback, not an extra touch target.
@MainActor
final class QFAssistantOrbContainerView: UIView {
  var onLayout: (() -> Void)?
  override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
  override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }
}
