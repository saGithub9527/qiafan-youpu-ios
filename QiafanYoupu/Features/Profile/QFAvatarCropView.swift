import SnapKit
import UIKit

@MainActor
final class QFAvatarCropViewController: UIViewController, UIScrollViewDelegate {
  private let app: QFAppSession
  private let source: UIImage
  private let completion: (UIImage?) -> Void
  private let scroll = UIScrollView()
  private let picture = UIImageView()
  private var positioned = false
  private var finished = false
  init(app: QFAppSession, image: UIImage, completion: @escaping (UIImage?) -> Void) {
    self.app = app; source = image; self.completion = completion
    super.init(nibName: nil, bundle: nil); modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = QFUI.background
    let header = QFSettingsPageUI.header(app.text("裁剪头像", "Crop profile photo"), backLabel: app.text("返回", "Back")) { [weak self] in self?.finish(nil) }
    view.addSubview(header); header.snp.makeConstraints { $0.top.leading.trailing.equalTo(view.safeAreaLayoutGuide) }
    let hint = QFContentUI.label(app.text("拖动或双指缩放，选择头像范围", "Drag or pinch to choose the profile photo area"), size: 15, color: QFUI.secondary)
    hint.textAlignment = .center; view.addSubview(hint)
    hint.snp.makeConstraints { $0.top.equalTo(header.snp.bottom).offset(20); $0.leading.trailing.equalToSuperview().inset(20) }
    scroll.delegate = self; scroll.clipsToBounds = true; scroll.bounces = false
    scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
    scroll.layer.cornerRadius = 20; scroll.backgroundColor = QFUI.surface
    view.addSubview(scroll)
    scroll.snp.makeConstraints {
      $0.top.equalTo(hint.snp.bottom).offset(24); $0.centerX.equalToSuperview()
      $0.width.equalTo(view.safeAreaLayoutGuide.snp.width).offset(-48).priority(999)
      $0.width.lessThanOrEqualTo(400); $0.height.equalTo(scroll.snp.width)
    }
    picture.image = source; scroll.addSubview(picture)
    picture.snp.makeConstraints { $0.edges.equalTo(scroll.contentLayoutGuide); $0.width.equalTo(source.size.width); $0.height.equalTo(source.size.height) }
    let use = QFTabUI.button(app.text("使用这张头像", "Use this photo"), size: 17, weight: .semibold, color: QFUI.onPrimary, background: QFUI.primary) { [weak self] in self?.crop() }
    use.layer.cornerRadius = 16; view.addSubview(use)
    use.snp.makeConstraints { $0.top.greaterThanOrEqualTo(scroll.snp.bottom).offset(24); $0.leading.trailing.equalToSuperview().inset(24); $0.bottom.equalTo(view.safeAreaLayoutGuide).inset(20); $0.height.equalTo(52) }
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard !positioned, scroll.bounds.width > 0, source.size.width > 0, source.size.height > 0 else { return }
    positioned = true
    let scale = max(scroll.bounds.width / source.size.width, scroll.bounds.height / source.size.height)
    scroll.minimumZoomScale = scale; scroll.maximumZoomScale = scale * 5; scroll.zoomScale = scale
    scroll.contentOffset = CGPoint(x: max(0, (source.size.width * scale - scroll.bounds.width) / 2), y: max(0, (source.size.height * scale - scroll.bounds.height) / 2))
  }
  func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Account changes can dismiss the whole editor without pressing a crop button.
    if !finished, isBeingDismissed || presentingViewController == nil {
      finished = true; completion(nil)
    }
  }
  private func crop() {
    guard scroll.bounds.width > 0 else { return }
    let output: CGFloat = 512
    let ratio = output / scroll.bounds.width
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let result = UIGraphicsImageRenderer(size: CGSize(width: output, height: output), format: format).image { _ in
      source.draw(in: CGRect(x: -scroll.contentOffset.x * ratio, y: -scroll.contentOffset.y * ratio, width: source.size.width * scroll.zoomScale * ratio, height: source.size.height * scroll.zoomScale * ratio))
    }
    finish(result)
  }
  private func finish(_ image: UIImage?) {
    guard !finished else { return }; finished = true
    dismiss(animated: true) { [completion] in completion(image) }
  }
}
