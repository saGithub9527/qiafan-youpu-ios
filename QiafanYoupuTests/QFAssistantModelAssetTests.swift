import ModelIO
import Metal
import SceneKit
import UIKit
import XCTest

@testable import QiafanYoupu

final class QFAssistantModelAssetTests: XCTestCase {
  @MainActor
  func testOverlayWindowPassesEmptySpaceAndKeepsControlsInteractive() {
    let window = QFAssistantOverlayWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
    let controller = UIViewController()
    window.rootViewController = controller
    let button = UIButton(frame: CGRect(x: 220, y: 400, width: 90, height: 110))
    controller.view.addSubview(button)
    window.windowLevel = QFAssistantOverlayWindow.assistantLevel
    window.isHidden = false
    defer { window.isHidden = true; window.rootViewController = nil; window.windowScene = nil }
    XCTAssertFalse(window.canBecomeKey)
    XCTAssertGreaterThan(window.windowLevel, UIWindow.Level.alert)
    XCTAssertNil(window.hitTest(CGPoint(x: 30, y: 50), with: nil))
    XCTAssertTrue(window.hitTest(CGPoint(x: 260, y: 450), with: nil) === button)
  }

  @MainActor
  func testManualChoicesSurviveAutomaticIntentUntilRestored() {
    let rig = QFAssistantRigView()
    rig.selectExpression(.sad)
    rig.selectPose(.wave)
    rig.playGreeting()
    XCTAssertEqual(rig.selectedFace, .sad)
    XCTAssertEqual(rig.selectedPose, .wave)
    XCTAssertEqual(rig.accessibilityValue, "难过")
    rig.resumeAutomaticAnimation()
    XCTAssertNil(rig.selectedFace)
    XCTAssertNil(rig.selectedPose)
    rig.stopRigAnimation()
  }

  @MainActor
  func testAllManualExpressionSelectionsRender() throws {
    let rig = QFAssistantRigView()
    var outputs = Set<Data>()
    for face in QFAssistantFaceSelection.allCases {
      rig.selectExpression(face)
      let image = rig.renderValidationExpression(.calm)
      outputs.insert(try XCTUnwrap(image.pngData()))
      let attachment = XCTAttachment(image: image)
      attachment.name = "manual-face-\(face.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
      XCTAssertEqual(rig.selectedFace, face)
    }
    XCTAssertEqual(outputs.count, QFAssistantFaceSelection.allCases.count)
    rig.stopRigAnimation()
  }
  @MainActor
  func testContinuousWaveTimeline() async {
    let rig = QFAssistantRigView()
    let frames = await rig.renderValidationWaveTimeline()
    XCTAssertEqual(frames.count, 40)
    XCTAssertGreaterThan(Set(frames.compactMap { $0.pngData() }).count, 8, "The real action timeline must animate across frames")
    for (index, frame) in frames.enumerated() {
      let attachment = XCTAttachment(image: frame)
      attachment.name = String(format: "wave-frame-%03d", index)
      attachment.lifetime = .keepAlways; add(attachment)
    }
    XCTAssertFalse(rig.isAnimatingForValidation)
  }
  @MainActor
  func testStoppedRigDoesNotResumeFromLateAction() {
    let rig = QFAssistantRigView()
    rig.beginRigAnimation()
    XCTAssertTrue(rig.isAnimatingForValidation)
    rig.stopRigAnimation()
    rig.playGreeting()
    XCTAssertFalse(rig.isAnimatingForValidation)
  }

  @MainActor
  func testAnimationTasksDoNotKeepRigAlive() {
    var rig: QFAssistantRigView? = QFAssistantRigView()
    weak var reference = rig
    rig?.beginRigAnimation()
    rig = nil
    XCTAssertNil(reference)
  }
  func testGreetingRequiresWholeEnglishWord() {
    for text in ["thinking", "this chicken dish", "something", "Which recipe?"] {
      XCTAssertEqual(QFAssistantCharacterIntent.from(text: text), .thinking)
    }
    XCTAssertEqual(QFAssistantCharacterIntent.from(text: "Hi!"), .greeting)
    XCTAssertEqual(QFAssistantCharacterIntent.from(text: "你好"), .greeting)
  }
  @MainActor
  func testExpressionsChangeRenderedFace() throws {
    let rig = QFAssistantRigView()
    let neutral = rig.renderValidationExpression(.calm)
    let baseline = XCTAttachment(image: neutral); baseline.name = "expression-neutral"; baseline.lifetime = .keepAlways; add(baseline)
    for emotion in QFAssistantRigView.QFAssistantEmotion.allCases where emotion != .calm {
      let image = rig.renderValidationExpression(emotion)
      let attachment = XCTAttachment(image: image); attachment.name = "expression-\(emotion)"; attachment.lifetime = .keepAlways; add(attachment)
      XCTAssertGreaterThan(try changedFacePixels(neutral, image), 10, "\(emotion) must change the face, not just another part of the image")
    }
    let blink = rig.renderValidationExpression(.calm, blink: 1)
    let attachment = XCTAttachment(image: blink); attachment.name = "expression-blink"; attachment.lifetime = .keepAlways; add(attachment)
    XCTAssertGreaterThan(try changedFacePixels(neutral, blink), 100, "Blink must affect the rendered eyes")
    rig.stopRigAnimation()
  }

  private func changedFacePixels(_ a: UIImage, _ b: UIImage) throws -> Int {
    // Fixed camera in the production validation scene. The region contains
    // eyes and mouth, excluding all limbs, clothing and badge.
    let face = CGRect(x: 174, y: 202, width: 130, height: 56)
    func pixels(_ image: UIImage) throws -> [UInt8] {
      let cropped = try XCTUnwrap(image.cgImage?.cropping(to: face))
      var bytes = [UInt8](repeating: 0, count: cropped.width * cropped.height * 4)
      try bytes.withUnsafeMutableBytes { pointer in
        let context = try XCTUnwrap(CGContext(data: pointer.baseAddress, width: cropped.width, height: cropped.height,
          bitsPerComponent: 8, bytesPerRow: cropped.width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
      }
      return bytes
    }
    let left = try pixels(a), right = try pixels(b)
    return stride(from: 0, to: left.count, by: 4).filter { index in
      (0..<3).contains { abs(Int(left[index + $0]) - Int(right[index + $0])) > 12 }
    }.count
  }
  @MainActor
  func testCharacterActionVisuals() {
    for pose in QFAssistantRigView.QFAssistantPose.allCases {
      // Each static pose starts at the bind pose. Timeline coverage below
      // separately exercises transitions on a continuously animated rig.
      let rig = QFAssistantRigView()
      let image = rig.renderValidationPose(pose)
      let attachment = XCTAttachment(image: image)
      attachment.name = "character-\(pose)"; attachment.lifetime = .keepAlways; add(attachment)
      XCTAssertNotNil(image.cgImage)
      rig.stopRigAnimation()
    }
  }
  @MainActor
  func testRenderCharacterPipelineStages() throws {
    let bundle = Bundle(identifier: "com.talka.qiafanyoupu") ?? Bundle.main
    guard case let .loaded(asset) = QFAssistantModelAsset.load(bundle: bundle) else {
      XCTFail("Character did not load"); return
    }
    let scene = asset.scene
    scene.background.contents = UIColor(white: 0.18, alpha: 1)
    let cameraNode = SCNNode()
    cameraNode.camera = SCNCamera()
    cameraNode.camera?.usesOrthographicProjection = true
    cameraNode.camera?.orthographicScale = 1.08
    cameraNode.position = SCNVector3(0, 0.90, 4)
    cameraNode.look(at: SCNVector3(0, 0.90, 0))
    scene.rootNode.addChildNode(cameraNode)
    for (position, intensity) in [(SCNVector3(2.4, 3.2, 4.4), CGFloat(300)), (SCNVector3(-2.2, 1.2, 2.2), CGFloat(90))] {
      let node = SCNNode(); node.light = SCNLight(); node.light?.type = .omni
      node.light?.intensity = intensity; node.position = position; scene.rootNode.addChildNode(node)
    }
    let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
    ambient.light?.intensity = 35; scene.rootNode.addChildNode(ambient)
    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    renderer.scene = scene; renderer.pointOfView = cameraNode
    func capture(_ name: String) {
      let image = renderer.snapshot(atTime: 0, with: CGSize(width: 480, height: 560), antialiasingMode: .multisampling4X)
      let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    let nodes = allNodes(in: asset.rootNode)
    for node in nodes {
      if let morpher = node.morpher { print("MORPH", node.name ?? "", morpher.calculationMode.rawValue, morpher.weights) }
      if let base = node.geometry?.sources(for: .vertex).first, let morpher = node.morpher {
        for (index, target) in morpher.targets.enumerated() {
          guard let source = target.sources(for: .vertex).first, source.vectorCount == base.vectorCount,
            base.bytesPerComponent == 4, source.bytesPerComponent == 4 else { continue }
          var largest: Float = 0
          base.data.withUnsafeBytes { baseBytes in
            source.data.withUnsafeBytes { targetBytes in
              for vector in 0..<base.vectorCount {
                for component in 0..<3 {
                  let a = baseBytes.loadUnaligned(fromByteOffset: base.dataOffset + vector * base.dataStride + component * 4, as: Float.self)
                  let b = targetBytes.loadUnaligned(fromByteOffset: source.dataOffset + vector * source.dataStride + component * 4, as: Float.self)
                  largest = max(largest, abs(a - b))
                }
              }
            }
          }
          print("TARGET", index, target.name ?? "", "maxdelta", largest)
        }
      }
      if let skinner = node.skinner {
        let outside = skinner.bones.filter { bone in !nodes.contains { $0 === bone } }
        print("SKIN", skinner.bones.count, "external bones", outside.count)
      }
      for material in node.geometry?.materials ?? [] {
        print("MATERIAL", material.name ?? "", "emission", String(describing: material.emission.contents), "emissionIntensity", material.emission.intensity,
              "normal", String(describing: material.normal.contents), "selfillum", String(describing: material.selfIllumination.contents))
      }
    }
    capture("01-current-zero-morph")
    let saved = nodes.compactMap { $0.morpher }
    for morpher in saved { for index in morpher.targets.indices { morpher.setWeight(0, forTargetAt: index) } }
    for node in nodes { node.removeAllAnimations() }
    capture("02-no-imported-animation")
    for node in nodes {
      guard let geometry = node.geometry else { continue }
      geometry.materials = geometry.materials.map { old in
        let fresh = SCNMaterial(); fresh.lightingModel = .constant; fresh.diffuse.contents = old.diffuse.contents
        fresh.isDoubleSided = true; return fresh
      }
    }
    capture("03-unlit-new-material")
    let happy = try XCTUnwrap(asset.nodeMap.morphChannels["face_happy"])
    happy.morpher.setWeight(1, forTargetAt: happy.index)
    capture("04-happy-unlit")
    happy.morpher.setWeight(0, forTargetAt: happy.index)
  }
  func testMissingDataSetProducesStableDiagnostic() {
    let result = QFAssistantModelAsset.load(bundle: Bundle(for: Self.self), resourceName: "missing-character-data")
    assertDiagnostic(result, code: .missingDataSet)
  }

  func testInvalidDataProducesUnsupportedDiagnostic() {
    let result = QFAssistantModelAsset.load(data: Data("not-a-usdz".utf8), resourceName: "fixture")
    assertDiagnostic(result, code: .unsupportedDataSet)
  }

  func testEmptySceneProducesEmptyDiagnostic() {
    let result = QFAssistantModelAsset.validate(scene: SCNScene(), requireSkin: false)
    assertDiagnostic(result, code: .emptyScene)
  }

  func testMissingRequiredLocatorProducesDeterministicDiagnostic() {
    let scene = makeFixtureScene(includeMorphs: true, missing: "character.left-eye")
    let result = QFAssistantModelAsset.validate(scene: scene, requireSkin: false)
    assertDiagnostic(result, code: .missingRequiredLocator)
    guard case let .fallback(diagnostic) = result else { return }
    XCTAssertEqual(diagnostic.missingNames, ["character.left-eye"])
  }

  func testMissingMorphProducesDeterministicDiagnostic() {
    let scene = makeFixtureScene(includeMorphs: false)
    let result = QFAssistantModelAsset.validate(scene: scene, requireSkin: false)
    assertDiagnostic(result, code: .missingMorphChannel)
    guard case let .fallback(diagnostic) = result else { return }
    XCTAssertEqual(diagnostic.missingNames, [QFAssistantModelAsset.requiredMorphNames.last!])
  }

  func testBundledRuntimeAssetLoadsAndMapsRig() {
    let appBundle = Bundle(identifier: "com.talka.qiafanyoupu") ?? Bundle.main
    let result = QFAssistantModelAsset.load(bundle: appBundle, resourceName: "cooking-fairy-mobile")
    guard case let .loaded(asset) = result else {
      let diagnostic = result.diagnostic
      XCTFail("Expected the bundled USDZ runtime asset to load: \(diagnostic?.code.rawValue ?? "unknown") missing=\(diagnostic?.missingNames ?? [])")
      return
    }
    XCTAssertEqual(asset.nodeMap.leftArm.count, 3)
    XCTAssertEqual(asset.nodeMap.rightArm.count, 3)
    XCTAssertEqual(asset.nodeMap.leftLeg.count, 3)
    XCTAssertEqual(asset.nodeMap.rightLeg.count, 3)
    XCTAssertEqual(asset.nodeMap.bones.count, QFAssistantModelAsset.requiredBoneNames.count)
    XCTAssertEqual(Set(asset.nodeMap.morphChannels.keys), Set(QFAssistantModelAsset.requiredMorphNames))

    let meshMaterials = allNodes(in: asset.rootNode)
      .compactMap { $0.geometry?.materials }
      .flatMap { $0 }
    XCTAssertTrue(meshMaterials.contains { $0.diffuse.contents is UIImage || $0.diffuse.contents is UIColor })
    XCTAssertTrue(meshMaterials.allSatisfy { $0.lightingModel == .constant })
    XCTAssertTrue(asset.nodeMap.morphChannels.values.allSatisfy { $0.morpher.weight(forTargetAt: $0.index) == 0 })
  }

  private func assertDiagnostic(_ result: QFAssistantModelAssetLoadResult, code: QFAssistantModelAssetDiagnosticCode, file: StaticString = #filePath, line: UInt = #line) {
    guard case let .fallback(diagnostic) = result else {
      XCTFail("Expected fallback diagnostic \(code.rawValue), got loaded result", file: file, line: line)
      return
    }
    XCTAssertEqual(diagnostic.code, code, file: file, line: line)
    XCTAssertFalse(diagnostic.fallbackReason.isEmpty, file: file, line: line)
  }

  private func makeFixtureScene(includeMorphs: Bool, missing: String? = nil) -> SCNScene {
    let scene = SCNScene()
    let character = SCNNode(); character.name = "CookingFairy"; scene.rootNode.addChildNode(character)
    let required = [
      "character.root", "character.head", "character.left-eye", "character.right-eye",
      "character.left-brow", "character.right-brow", "character.mouth",
      "character.left-arm", "character.right-arm", "character.left-leg", "character.right-leg",
      "root", "pelvis", "spine", "chest", "neck", "head",
      "upper_arm.L", "forearm.L", "hand.L", "upper_arm.R", "forearm.R", "hand.R",
      "thigh.L", "shin.L", "foot.L", "thigh.R", "shin.R", "foot.R",
    ]
    for name in required where name != missing {
      let node = SCNNode(); node.name = name.replacingOccurrences(of: ".", with: "_"); character.addChildNode(node)
    }
    let mesh = SCNNode(); mesh.name = "CookingFairyMesh"; mesh.geometry = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
    if includeMorphs {
      let morpher = SCNMorpher()
      var targets: [SCNGeometry] = []
      for name in QFAssistantModelAsset.requiredMorphNames {
        let target = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
        target.name = name
        targets.append(target)
      }
      morpher.targets = targets
      mesh.morpher = morpher
    } else {
      let morpher = SCNMorpher()
      var targets: [SCNGeometry] = []
      for name in QFAssistantModelAsset.requiredMorphNames.dropLast() {
        let target = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
        target.name = name
        targets.append(target)
      }
      morpher.targets = targets
      mesh.morpher = morpher
    }
    character.addChildNode(mesh)
    return scene
  }

  private func allNodes(in root: SCNNode) -> [SCNNode] {
    [root] + root.childNodes.flatMap { allNodes(in: $0) }
  }
}
