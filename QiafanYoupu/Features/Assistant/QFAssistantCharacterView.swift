import QFOrbRenderer
import SnapKit
import UIKit

/// Retains the assistant's existing display boundary and conversation events.
/// Human model rendering has been replaced by the approved offline light orb.
@MainActor
final class QFAssistantCharacterView: UIView {
  private let orb = QFOrbView(frame: .zero)
  private var running = false
  var isReadyForDisplay: Bool { orb.displayState == .ready }
  var isAvailableForDisplay: Bool { orb.displayState != .loading }
  var onDisplayStateChanged: (() -> Void)? {
    get { orb.onDisplayStateChanged }
    set { orb.onDisplayStateChanged = newValue }
  }
  var interfaceLanguage: QFInterfaceLanguage = .simplifiedChinese {
    didSet { updateAccessibility() }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false; backgroundColor = .clear
    isUserInteractionEnabled = false
    addSubview(orb); orb.snp.makeConstraints { $0.edges.equalToSuperview() }
    updateAccessibility()
  }
  convenience init() { self.init(frame: .zero) }
  required init?(coder: NSCoder) { nil }

  func beginRigAnimation() { running = true; orb.setRendering(true) }
  func stopRigAnimation() { running = false; orb.setRendering(false) }
  func playGreeting() { playSceneAction(.greeting) }
  func playExcited() { playSceneAction(.positive) }
  func playSceneAction(_ intent: QFAssistantCharacterIntent) {
    guard running else { return }
    // Conversation events wake a colored light wave while the automatic
    // rotation and slow 3.4-second cycle continue.
    if intent != .idle { orb.pulse() }
  }
  private func updateAccessibility() {
    let language = interfaceLanguage
    accessibilityValue = language.text(chinese: "律动", english: "Flow")
  }
}
