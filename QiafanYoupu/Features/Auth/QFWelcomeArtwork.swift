import SnapKit
import UIKit

@MainActor
final class QFAuthChefHeroView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = QFAuthPalette.color(0xFFF0E7)
    let image = UIImageView(image: UIImage(named: "chef-logo"))
    image.contentMode = .scaleAspectFit
    addSubview(image)
    image.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 10, left: 17, bottom: 18, right: 17)) }
    isAccessibilityElement = true
    accessibilityLabel = "小狗厨师拿着锅铲和一锅蔬菜"
    accessibilityTraits = .image
  }
  required init?(coder: NSCoder) { return nil }
  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = min(bounds.width, bounds.height) / 2
  }
}

// The existing 342-point illustration artwork is laid out with SnapKit and scaled as a unit.
@MainActor
final class QFWelcomeArtworkView: UIView {
  private struct Placement {
    let rect: CGRect
    let constraints: [Constraint]
  }
  private var placements: [Placement] = []
  private var labels: [(UILabel, CGFloat)] = []
  private var corners: [(UIView, CGFloat)] = []
  private var scale: CGFloat = -1

  init(page: Int) {
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    isAccessibilityElement = true
    accessibilityTraits = .image
    switch page {
    case 0, 4:
      chef(ready: page == 4)
      accessibilityLabel = page == 4 ? "小狗厨师准备开饭" : "小狗厨师拿着锅铲和一锅蔬菜"
    case 1:
      world()
      accessibilityLabel = "按国家、口味与菜系探索：中国家常味点心，意大利地中海风味意面"
    case 2:
      recipe()
      accessibilityLabel = "搜索番茄炒蛋，准备番茄、鸡蛋和调味料，再跟着步骤做"
    default:
      plan()
      accessibilityLabel = "一周菜单安排了晚餐，食材清单中的蔬菜和鸡蛋已准备好"
    }
  }
  required init?(coder: NSCoder) { return nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    let next = min(bounds.width, bounds.height) / 342
    guard next > 0, abs(next - scale) > 0.001 else { return }
    scale = next
    for placement in placements {
      let rect = placement.rect
      for (constraint, value) in zip(placement.constraints, [rect.minX, rect.minY, rect.width, rect.height]) {
        constraint.update(offset: value * next)
      }
    }
    for (label, size) in labels { label.font = UIFont(descriptor: label.font.fontDescriptor, size: size * next) }
    for (view, radius) in corners { view.layer.cornerRadius = radius * next }
  }

  @discardableResult
  private func place(_ view: UIView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                     in parent: UIView? = nil) -> UIView {
    let parent = parent ?? self
    parent.addSubview(view)
    var constraints: [Constraint] = []
    view.snp.makeConstraints {
      constraints = [$0.leading.equalToSuperview().offset(x).constraint,
                     $0.top.equalToSuperview().offset(y).constraint,
                     $0.width.equalTo(width).constraint, $0.height.equalTo(height).constraint]
    }
    placements.append(Placement(rect: CGRect(x: x, y: y, width: width, height: height), constraints: constraints))
    return view
  }

  private func shape(_ color: UIColor, radius: CGFloat = 0) -> UIView {
    let view = UIView()
    view.backgroundColor = color
    view.layer.cornerRadius = radius
    corners.append((view, radius))
    return view
  }

  private func text(_ copy: String, size: CGFloat = 12, weight: UIFont.Weight = .regular,
                    color: UIColor = QFUI.text, centered: Bool = false) -> UILabel {
    let label = QFUI.label(copy, size: size, weight: weight, color: color, lines: 1)
    label.textAlignment = centered ? .center : .left
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.8
    labels.append((label, size))
    return label
  }

  private func image(_ asset: String, radius: CGFloat = 0, fill: Bool = false) -> UIImageView {
    let view = UIImageView(image: UIImage(named: asset))
    view.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
    view.clipsToBounds = true
    corners.append((view, radius))
    return view
  }

  private func symbol(_ name: String, color: UIColor) -> UIImageView {
    let view = UIImageView(image: UIImage(systemName: name))
    view.contentMode = .scaleAspectFit
    view.tintColor = color
    return view
  }

  private func chip(_ copy: String, background: UIColor = .white, color: UIColor = QFUI.green) -> UILabel {
    let label = text(copy, weight: .medium, color: color, centered: true)
    label.backgroundColor = background
    label.clipsToBounds = true
    corners.append((label, 15))
    return label
  }

  private func card() -> UIView {
    let view = shape(.white, radius: 22)
    view.layer.shadowColor = QFAuthPalette.color(0xD5E1C9).cgColor
    view.layer.shadowOpacity = 1
    view.layer.shadowRadius = 0
    view.layer.shadowOffset = CGSize(width: 4, height: 6)
    return view
  }

  private func chef(ready: Bool) {
    place(shape(QFAuthPalette.color(0xFFF0E5), radius: 139), 32, 30, 278, 278)
    if !ready { place(shape(QFAuthPalette.color(0xF3DBC0), radius: 8), 50, 298, 242, 17) }
    place(image("chef-logo"), 58, 8, 231, 297)
    place(chip(ready ? "从喜欢的一道菜开始" : "今天也要好好吃饭", color: QFAuthPalette.color(0xBF4223)), 84, 302, 174, 30)
    place(text("+", size: 30, weight: .light, color: QFUI.orange), 24, 112, 24, 30)
    place(text("+", size: 30, weight: .light, color: ready ? QFUI.green : QFUI.orange), ready ? 298 : 295, ready ? 231 : 50, 24, 30)
    place(shape(QFUI.orange, radius: 2.5), 57, 48, 5, 5)
    place(shape(QFAuthPalette.color(0xD6E5C9), radius: 3.5), 289, 225, 7, 7)
    if ready { place(chip("✓"), 275, 42, 38, 38) }
  }

  private func world() {
    place(QFAuthGlobeView(), 34, 38, 279, 279)
    place(chip("国家"), 27, 27, 62, 30)
    place(chip("口味"), 109, 10, 62, 30)
    place(chip("菜系"), 193, 21, 62, 30)
    let china = card()
    place(china, 7, 92, 144, 169)
    place(image("dish-dimsum", radius: 17, fill: true), 8, 8, 128, 112, in: china)
    place(text("中国 · 家常味", size: 13, weight: .semibold), 14, 130, 124, 19, in: china)
    place(text("熟悉，也有新惊喜", size: 10, color: QFUI.secondary), 14, 150, 124, 15, in: china)
    let italy = card()
    place(italy, 188, 143, 154, 167)
    place(image("dish-noodles", radius: 17, fill: true), 8, 8, 138, 108, in: italy)
    place(text("意大利 · 地中海风味", size: 11.8, weight: .semibold), 14, 127, 134, 19, in: italy)
    place(text("换个地方，尝点不同", size: 10.8, color: QFUI.secondary), 14, 147, 133, 16, in: italy)
    place(text("+", size: 30, weight: .light, color: QFUI.green), 305, 79, 24, 30)
    place(shape(QFUI.orange, radius: 4), 50, 305, 8, 8)
  }

  private func recipe() {
    let recipe = card()
    place(recipe, 22, 86, 296, 249)
    place(image("dish-rice", radius: 17, fill: true), 16, 23, 78, 78, in: recipe)
    place(text("番茄炒蛋", size: 17, weight: .semibold), 108, 32, 130, 28, in: recipe)
    place(chip("家常菜", background: QFUI.paleGreen), 108, 68, 70, 30, in: recipe)
    place(symbol("heart", color: QFUI.orange), 248, 33, 20, 20, in: recipe)
    place(text("准备食材", size: 13, weight: .semibold), 19, 120, 150, 19, in: recipe)
    for (index, item) in ["番茄", "鸡蛋", "调味料"].enumerated() {
      place(chip(item, background: QFAuthPalette.color(0xFAF5EB), color: QFUI.secondary),
            19 + CGFloat(index) * 73, 145, index == 2 ? 78 : 66, 30, in: recipe)
    }
    place(shape(QFUI.border), 19, 192, 259, 1, in: recipe)
    place(chip("1", background: QFAuthPalette.color(0xFFF0E5), color: QFAuthPalette.color(0xAB3A1C)), 19, 208, 20, 20, in: recipe)
    place(text("处理食材，开始第一步", weight: .semibold), 49, 206, 220, 24, in: recipe)
    let search = shape(.white, radius: 17)
    search.layer.borderWidth = 1
    search.layer.borderColor = QFUI.border.cgColor
    place(search, 44, 48, 257, 52)
    place(symbol("magnifyingglass", color: QFUI.orange), 17, 16, 19, 19, in: search)
    place(text("番茄炒蛋", size: 14, weight: .semibold), 48, 13, 160, 26, in: search)
    place(chip("→", background: QFAuthPalette.color(0xFFF0E5), color: QFUI.orange), 213, 15, 26, 23, in: search)
    place(text("+", size: 30, weight: .light, color: QFUI.orange), 8, 258, 24, 30)
    place(shape(QFUI.orange, radius: 3), 311, 72, 6, 6)
  }

  private func plan() {
    place(shape(QFUI.paleGreen, radius: 126), 53, 66, 265, 253)
    let calendar = card()
    place(calendar, 22, 59, 282, 228)
    place(text("我的一周菜单", size: 18, weight: .semibold), 20, 15, 233, 27, in: calendar)
    place(shape(QFUI.border), 20, 48, 239, 1, in: calendar)
    for (index, weekday) in ["一", "二", "三", "四", "五", "六", "日"].enumerated() {
      let x: CGFloat = 17 + CGFloat(index) * 36
      place(text(weekday, size: 11, color: QFUI.secondary, centered: true), x, 60, 30, 18, in: calendar)
      place(chip("\(14 + index)", background: index == 2 ? QFUI.orange : .clear,
                 color: index == 2 ? .white : QFUI.text), x, 84, 27, 30, in: calendar)
    }
    place(image("dish-vegetables", radius: 16, fill: true), 19, 135, 64, 64, in: calendar)
    place(text("今天吃点清爽的", size: 13, weight: .semibold), 95, 141, 147, 23, in: calendar)
    place(text("已加入晚餐计划", color: QFUI.secondary), 95, 165, 147, 23, in: calendar)
    place(chip("✓", background: QFUI.paleGreen), 241, 144, 22, 30, in: calendar)
    let shopping = card()
    place(shopping, 83, 250, 244, 87)
    place(text("食材清单", size: 13, weight: .semibold), 20, 12, 170, 20, in: shopping)
    place(text("✓  蔬菜", color: QFUI.secondary), 23, 42, 89, 20, in: shopping)
    place(text("✓  鸡蛋", color: QFUI.secondary), 110, 42, 89, 20, in: shopping)
    place(text("都安排好了", size: 10, weight: .semibold, color: QFUI.green), 167, 66, 70, 17, in: shopping)
    place(text("+", size: 30, weight: .light, color: QFUI.green), 312, 110, 24, 30)
    place(shape(QFUI.orange, radius: 3), 17, 279, 6, 6)
  }
}

@MainActor
private final class QFAuthGlobeView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    contentMode = .redraw
  }
  required init?(coder: NSCoder) { return nil }
  override func draw(_ rect: CGRect) {
    guard let context = UIGraphicsGetCurrentContext() else { return }
    QFUI.paleGreen.setFill()
    UIBezierPath(ovalIn: bounds).fill()
    let globe = bounds.insetBy(dx: bounds.width * 44 / 279, dy: bounds.height * 24 / 279)
    QFAuthPalette.color(0xADC399).setStroke()
    let outer = UIBezierPath(ovalIn: globe)
    outer.lineWidth = 1.6
    outer.stroke()
    let inner = UIBezierPath(ovalIn: globe.insetBy(dx: globe.width * 0.23, dy: 0))
    inner.lineWidth = 1.4
    inner.stroke()
    context.saveGState()
    outer.addClip()
    let lines = UIBezierPath()
    lines.move(to: CGPoint(x: globe.midX, y: globe.minY))
    lines.addLine(to: CGPoint(x: globe.midX, y: globe.maxY))
    for index in 1..<3 {
      let y = globe.minY + globe.height * CGFloat(index) / 3
      lines.move(to: CGPoint(x: globe.minX, y: y))
      lines.addLine(to: CGPoint(x: globe.maxX, y: y))
    }
    lines.lineWidth = 1.4
    lines.stroke()
    context.restoreGState()
  }
}
