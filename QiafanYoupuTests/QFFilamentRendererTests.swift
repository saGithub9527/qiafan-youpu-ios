import QFFilamentBridge
import UIKit
import XCTest

final class QFFilamentRendererTests: XCTestCase {
  @MainActor
  func testAuthoringCandidateRendersBakedClipsForReview() async throws {
    // Authoring diagnostics can stage a candidate temporarily in the test
    // bundle. Never read the host Documents folder from a simulator APP.
    guard let url = Bundle(for: Self.self).url(forResource: "AuthoringCandidate", withExtension: "glb", subdirectory: "FilamentFixtures")
    else { throw XCTSkip("Local authoring candidate is absent") }
    let (window, view) = mountedView()
    defer { view.dispose(); window.isHidden = true; window.rootViewController = nil; window.windowScene = nil }
    try view.load(glb: Data(contentsOf: url))
    XCTAssertEqual(view.animationNames.count, 10)
    for name in view.animationNames {
      XCTAssertTrue(view.playAnimation(named: name, looping: false, transitionDuration: 0))
      view.startRendering()
      try await Task.sleep(nanoseconds: 500_000_000)
      view.stopRendering()
      let frame = try await snapshot(view)
      let alpha = try alphaCounts(frame)
      XCTAssertGreaterThan(alpha.visible, 100)
      XCTAssertGreaterThan(alpha.transparent, 100)
      let proof = XCTAttachment(image: frame); proof.name = "candidate-\(name)"; proof.lifetime = .keepAlways; add(proof)
    }
    // Rendering these frames is diagnostic evidence, not visual acceptance.
  }

  @MainActor
  func testHunyuanPreviewLoadsPBRAndExpressionChannels() async throws {
    let (window, view) = mountedView()
    defer { view.dispose(); window.isHidden = true; window.rootViewController = nil; window.windowScene = nil }
    let bundle = Bundle(identifier: "com.talka.qiafanyoupu") ?? .main
    let url = try XCTUnwrap(bundle.url(forResource: "cooking-fairy", withExtension: "glb", subdirectory: "AssistantPreview"))
    try view.load(glb: Data(contentsOf: url))
    XCTAssertTrue(Set(["face_happy", "face_sad", "face_angry", "face_talk"]).isSubset(of: Set(view.morphTargetNames)))
    XCTAssertTrue(view.animationNames.isEmpty, "The current rest asset must not pretend to contain approved clips")
    view.startRendering()
    try await Task.sleep(nanoseconds: 650_000_000)
    let neutral = try await snapshot(view)
    XCTAssertTrue(view.setMorph(weight: 1, name: "face_happy"))
    try await Task.sleep(nanoseconds: 180_000_000)
    let happy = try await snapshot(view)
    XCTAssertNotEqual(neutral.pngData(), happy.pngData())
    for (name, image) in [("filament-hunyuan-neutral", neutral), ("filament-hunyuan-happy", happy)] {
      let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    let pixels = try alphaCounts(neutral)
    XCTAssertGreaterThan(pixels.visible, 100)
    XCTAssertGreaterThan(pixels.transparent, 100)
  }

  @MainActor
  func testInvalidGLBDoesNotStartRenderer() throws {
    let view = QFFilamentView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
    defer { view.dispose() }
    XCTAssertThrowsError(try view.load(glb: Data("invalid".utf8)))
    view.startRendering()
    XCTAssertFalse(view.isLoaded)
    XCTAssertFalse(view.isRendering)
    try view.load(glb: fixture("AnimatedMorphCube"))
    view.startRendering()
    XCTAssertTrue(view.isRendering)
    XCTAssertThrowsError(try view.load(glb: Data("invalid reload".utf8)))
    XCTAssertFalse(view.isRendering, "A failed replacement must not leave an idle display link running")
    XCTAssertFalse(view.isLoaded)
    try view.load(glb: fixture("AnimatedMorphCube"))
    view.bounds = .zero
    var responded = false
    view.captureFrame { image in XCTAssertNil(image); responded = true }
    XCTAssertTrue(responded, "An invalid capture size must finish immediately")
  }

  @MainActor
  func testSkeletalClipsRenderAboveTransparentBackgroundAndRelease() async throws {
    let (window, view) = mountedView()
    defer { view.dispose(); window.isHidden = true; window.rootViewController = nil; window.windowScene = nil }
    try view.load(glb: fixture("Fox"))
    XCTAssertEqual(Set(view.animationNames), Set(["Survey", "Walk", "Run"]))
    XCTAssertFalse(view.playAnimation(named: "missing", looping: false, transitionDuration: 0.2))
    XCTAssertTrue(view.playAnimation(named: "Walk", looping: true, transitionDuration: 0.2))
    view.startRendering()
    try await Task.sleep(nanoseconds: 600_000_000)
    let walk = try await snapshot(view)
    XCTAssertTrue(view.playAnimation(named: "Run", looping: true, transitionDuration: 0.2))
    try await Task.sleep(nanoseconds: 500_000_000)
    let run = try await snapshot(view)
    XCTAssertNotEqual(walk.pngData(), run.pngData(), "Clips must change the actual GPU rendering")
    let alpha = try alphaCounts(walk)
    XCTAssertGreaterThan(alpha.transparent, 100)
    XCTAssertGreaterThan(alpha.visible, 100, "A clear but empty frame is not successful rendering")
    for (name, image) in [("filament-skin-walk", walk), ("filament-skin-run", run)] {
      let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    let count = view.renderedFrameCount
    view.stopRendering()
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(count, view.renderedFrameCount)
    let paused = try await snapshot(view)
    try await Task.sleep(nanoseconds: 470_000_000)
    let stillPaused = try await snapshot(view)
    XCTAssertEqual(paused.pngData(), stillPaused.pngData(), "A stopped renderer must freeze the animation clock too")
    view.startRendering()
    try await Task.sleep(nanoseconds: 300_000_000)
    let resumed = try await snapshot(view)
    XCTAssertNotEqual(stillPaused.pngData(), resumed.pngData())
    view.dispose(); view.dispose()
    XCTAssertFalse(view.isLoaded)
    XCTAssertFalse(view.isRendering)
  }

  @MainActor
  func testMorphOverridesSurviveAnimationAndDisplayLinkDoesNotRetainView() async throws {
    let (window, surface) = mountedView()
    var view: QFFilamentView? = surface
    defer { window.isHidden = true; window.rootViewController = nil; window.windowScene = nil }
    try view!.load(glb: fixture("AnimatedMorphCube"))
    // This reference morph changes the cube's depth, so a frontal orthographic
    // camera cannot see its silhouette change. Check from a three-quarter view.
    view!.cameraYaw = 0.65
    let channel = try XCTUnwrap(view!.morphTargetNames.first)
    XCTAssertFalse(view!.setMorph(weight: .nan, name: channel))
    view!.startRendering()
    try await Task.sleep(nanoseconds: 350_000_000)
    let neutral = try await snapshot(view!)
    XCTAssertTrue(view!.setMorph(weight: 1, name: channel))
    if let clip = view!.animationNames.first {
      XCTAssertTrue(view!.playAnimation(named: clip, looping: true, transitionDuration: 0.2))
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    let morphed = try await snapshot(view!)
    XCTAssertNotEqual(neutral.pngData(), morphed.pngData())
    let attachment = XCTAttachment(image: morphed); attachment.name = "filament-morph-override"; attachment.lifetime = .keepAlways; add(attachment)
    XCTAssertTrue(view!.clearMorphOverride(name: channel))
    try await Task.sleep(nanoseconds: 250_000_000)
    let released = try await snapshot(view!)
    XCTAssertNotEqual(morphed.pngData(), released.pngData(), "Releasing a manual morph must restore the animated channel")
    // Removing UIKit ownership while a display link runs must release the view.
    weak var reference = view
    view?.removeFromSuperview()
    view?.dispose()
    view = nil
    // surface is a scoped fixture strong reference; the dedicated release test
    // below verifies deallocation rather than asserting over this local.
    XCTAssertFalse(reference?.isRendering ?? true)
  }

  @MainActor
  func testRunningViewCanDeallocateWithoutExplicitDispose() async throws {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
    let controller = UIViewController(); window.rootViewController = controller; window.isHidden = false
    var view: QFFilamentView? = QFFilamentView(frame: window.bounds)
    controller.view.addSubview(view!)
    try view!.load(glb: fixture("AnimatedMorphCube")); view!.startRendering()
    weak var reference = view
    try await Task.sleep(nanoseconds: 200_000_000)
    view?.removeFromSuperview(); view = nil
    // UIKit can autorelease a removed subview at the end of the current
    // transaction; allow that transaction to drain before testing ownership.
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertNil(reference)
    window.isHidden = true; window.rootViewController = nil; window.windowScene = nil
  }

  @MainActor
  private func mountedView() -> (UIWindow, QFFilamentView) {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    let controller = UIViewController(); window.rootViewController = controller
    controller.view.backgroundColor = .clear
    let view = QFFilamentView(frame: window.bounds); controller.view.addSubview(view)
    window.isHidden = false; view.layoutIfNeeded()
    return (window, view)
  }

  private func fixture(_ name: String) throws -> Data {
    let bundle = Bundle(for: Self.self)
    let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "glb", subdirectory: "FilamentFixtures"))
    return try Data(contentsOf: url)
  }

  @MainActor
  private func snapshot(_ view: QFFilamentView) async throws -> UIImage {
    let pending = expectation(description: "Metal readback")
    var result: UIImage?
    view.captureFrame { image in result = image; pending.fulfill() }
    await fulfillment(of: [pending], timeout: 10)
    return try XCTUnwrap(result)
  }

  private func alphaCounts(_ image: UIImage) throws -> (transparent: Int, visible: Int) {
    let cg = try XCTUnwrap(image.cgImage)
    var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    bytes.withUnsafeMutableBytes { raw in
      let context = CGContext(data: raw.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
        bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    }
    var clear = 0, visible = 0
    for index in stride(from: 3, to: bytes.count, by: 4) {
      if bytes[index] == 0 { clear += 1 }
      if bytes[index] > 128 { visible += 1 }
    }
    return (clear, visible)
  }
}
