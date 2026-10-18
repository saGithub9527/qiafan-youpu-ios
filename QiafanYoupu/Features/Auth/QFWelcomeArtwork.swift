import SnapKit
import UIKit

@MainActor
final class QFAuthChefHeroView: UIView {
  init(app: QFAppSession) {
    super.init(frame: .zero)
    backgroundColor = QFAuthPalette.color(0xFFF0E7)
    let image = UIImageView(image: UIImage(named: "chef-logo"))
    image.contentMode = .scaleAspectFit
    addSubview(image)
    image.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 10, left: 17, bottom: 18, right: 17)) }
    isAccessibilityElement = true
    accessibilityLabel = app.text(
      "小狗厨师拿着锅铲和一锅蔬菜", "A puppy chef holding a spatula beside a pot of vegetables")
    accessibilityTraits = .image
  }
  required init?(coder: NSCoder) { return nil }
  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = min(bounds.width, bounds.height) / 2
  }
}
