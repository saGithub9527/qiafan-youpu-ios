import AVKit
import SnapKit
import UIKit

@MainActor
final class QFVideoPreviewView: UIView {
  private let app: QFAppSession
  private let image = UIImageView()
  private let play = UIButton(type: .system)
  private let caption = QFContentUI.label("", size: 13, color: .white)
  private let spinner = UIActivityIndicatorView(style: .large)
  private var task: Task<Void, Never>?
  private var mediaID: String?
  private var file: URL?
  private var ownsFile = false
  private var generator: AVAssetImageGenerator?

  init(app: QFAppSession) {
    self.app = app
    super.init(frame: .zero)
    backgroundColor = .black
    layer.cornerRadius = 16; clipsToBounds = true
    snp.makeConstraints { $0.height.equalTo(220) }
    image.contentMode = .scaleAspectFill; image.clipsToBounds = true
    addSubview(image); image.snp.makeConstraints { $0.edges.equalToSuperview() }
    play.setImage(UIImage(systemName: "play.circle.fill"), for: .normal)
    play.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 52), forImageIn: .normal)
    play.tintColor = .white; play.accessibilityLabel = app.text("播放视频", "Play video")
    play.addAction(UIAction { [weak self] _ in self?.playVideo() }, for: .touchUpInside)
    addSubview(play); play.snp.makeConstraints { $0.edges.equalToSuperview() }
    caption.backgroundColor = UIColor.black.withAlphaComponent(0.5)
    caption.textAlignment = .center
    addSubview(caption); caption.snp.makeConstraints { $0.leading.trailing.bottom.equalToSuperview(); $0.height.greaterThanOrEqualTo(30) }
    spinner.color = .white; spinner.hidesWhenStopped = true
    addSubview(spinner); spinner.snp.makeConstraints { $0.center.equalToSuperview() }
    isHidden = true
  }
  required init?(coder: NSCoder) { nil }
  deinit {
    task?.cancel(); generator?.cancelAllCGImageGeneration()
    if ownsFile, let file { try? FileManager.default.removeItem(at: file) }
  }
  func load(_ id: String?) {
    guard id != mediaID else { return }
    task?.cancel(); generator?.cancelAllCGImageGeneration()
    if ownsFile, let file { try? FileManager.default.removeItem(at: file) }
    mediaID = id; file = nil; ownsFile = false; image.image = nil
    isHidden = id == nil
    guard let id else { return }
    spinner.startAnimating(); play.isHidden = true; caption.text = app.text("正在读取视频", "Loading video")
    let scope = app.contentScope
    task = Task { [weak self, app] in
      var temporary: URL?
      do {
        let url: URL
        if QFLocalMediaStore.isLocal(id) {
          url = try QFLocalMediaStore.url(id, scope: scope)
        } else {
          let data = try await app.loadContentMedia(id)
          let destination = FileManager.default.temporaryDirectory.appendingPathComponent("qf-video-preview-\(UUID().uuidString).mov")
          temporary = destination
          try await Task.detached(priority: .userInitiated) { try data.write(to: destination, options: .atomic) }.value
          url = destination
        }
        try Task.checkCancellation()
        guard let self, self.mediaID == id, app.contentScope == scope else { throw CancellationError() }
        self.file = url; self.ownsFile = temporary != nil; temporary = nil
        let asset = AVURLAsset(url: url)
        let maker = AVAssetImageGenerator(asset: asset)
        maker.appliesPreferredTrackTransform = true
        maker.maximumSize = CGSize(width: 960, height: 540)
        self.generator = maker
        let poster: CGImage = try await withCheckedThrowingContinuation { continuation in
          maker.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, _, error in
            if let image { continuation.resume(returning: image) }
            else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
          }
        }
        let duration = try await asset.load(.duration)
        try Task.checkCancellation()
        guard self.mediaID == id, app.contentScope == scope else { throw CancellationError() }
        self.image.image = UIImage(cgImage: poster)
        let seconds = duration.seconds.isFinite ? Int(max(0, min(duration.seconds, Double(Int32.max)))) : 0
        self.caption.text = String(format: self.app.text("%d:%02d · 点击播放", "%d:%02d · Tap to play"), seconds / 60, seconds % 60)
        self.play.isHidden = false; self.spinner.stopAnimating()
      } catch {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        guard let self, self.mediaID == id, app.contentScope == scope, !(error is CancellationError) else { return }
        self.spinner.stopAnimating(); self.play.isHidden = false
        self.caption.text = self.file == nil ? self.app.text("读取失败，点击重试", "Could not load. Tap to retry.") : self.app.text("预览暂不可用，点击播放", "Preview unavailable. Tap to play.")
      }
    }
  }
  private func playVideo() {
    guard let file else { let id = mediaID; mediaID = nil; load(id); return }
    var responder: UIResponder? = self
    while let value = responder {
      if let controller = value as? UIViewController {
        guard controller.presentedViewController == nil else { return }
        let player = QFContentVideoController(url: file)
        controller.present(player, animated: true)
        return
      }
      responder = value.next
    }
  }
}
