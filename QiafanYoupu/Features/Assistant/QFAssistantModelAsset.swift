import Foundation
import ModelIO
import SceneKit
import UIKit

enum QFAssistantModelAssetDiagnosticCode: String, Equatable {
  case missingDataSet
  case unreadableDataSet
  case unsupportedDataSet
  case emptyScene
  case incompleteSkin
  case missingRequiredLocator
  case missingMorphChannel
}

struct QFAssistantModelAssetDiagnostic: Error, Equatable {
  let code: QFAssistantModelAssetDiagnosticCode
  let message: String
  let missingNames: [String]
  let fallbackReason: String

  init(code: QFAssistantModelAssetDiagnosticCode, message: String, missingNames: [String] = [], fallbackReason: String) {
    self.code = code
    self.message = message
    self.missingNames = missingNames.sorted()
    self.fallbackReason = fallbackReason
  }
}

struct QFAssistantMorphChannel {
  let name: String
  let morpher: SCNMorpher
  let index: Int
}

struct QFAssistantFaceLocatorMap {
  let leftEye: SCNNode
  let rightEye: SCNNode
  let leftBrow: SCNNode
  let rightBrow: SCNNode
  let mouth: SCNNode
}

struct QFAssistantNodeMap {
  let root: SCNNode
  let head: SCNNode
  let leftArm: [SCNNode]
  let rightArm: [SCNNode]
  let leftLeg: [SCNNode]
  let rightLeg: [SCNNode]
  let face: QFAssistantFaceLocatorMap
  let bones: [String: SCNNode]
  let morphChannels: [String: QFAssistantMorphChannel]
}

enum QFAssistantModelAssetLoadResult {
  case loaded(QFAssistantModelAsset)
  case fallback(QFAssistantModelAssetDiagnostic)

  var diagnostic: QFAssistantModelAssetDiagnostic? {
    guard case let .fallback(value) = self else { return nil }
    return value
  }
}

final class QFAssistantModelAsset {
  static let requiredBoneNames = [
    "root", "pelvis", "spine", "chest", "neck", "head",
    "upper_arm.L", "forearm.L", "hand.L", "upper_arm.R", "forearm.R", "hand.R",
    "thigh.L", "shin.L", "foot.L", "thigh.R", "shin.R", "foot.R",
  ]
  static let requiredMorphNames = [
    "face_neutral", "face_happy", "face_blink_L", "face_blink_R", "face_surprised", "face_thinking",
    "face_sad", "face_angry", "face_shy", "face_talk",
  ]

  let scene: SCNScene
  let rootNode: SCNNode
  let nodeMap: QFAssistantNodeMap
  let resourceName: String

  private init(scene: SCNScene, rootNode: SCNNode, nodeMap: QFAssistantNodeMap, resourceName: String) {
    self.scene = scene
    self.rootNode = rootNode
    self.nodeMap = nodeMap
    self.resourceName = resourceName
  }

  static func load(bundle: Bundle, resourceName: String = "cooking-fairy-mobile") -> QFAssistantModelAssetLoadResult {
    guard let dataAsset = NSDataAsset(name: resourceName, bundle: bundle) else {
      return .fallback(diagnostic(
        .missingDataSet,
        message: "The " + resourceName + " Data Set is not present in the requested bundle.",
        fallbackReason: "Keep the existing assistant-character.scn or procedural renderer when the runtime Data Set is absent."
      ))
    }
    return load(data: dataAsset.data, resourceName: resourceName, textureBundle: bundle)
  }

  static func load(data: Data, resourceName: String = "cooking-fairy-mobile") -> QFAssistantModelAssetLoadResult {
    load(data: data, resourceName: resourceName, textureBundle: nil)
  }

  private static func load(data: Data, resourceName: String, textureBundle: Bundle?) -> QFAssistantModelAssetLoadResult {
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("qf-" + UUID().uuidString, isDirectory: false)
      .appendingPathExtension("usdz")
    do {
      try data.write(to: temporaryURL, options: .atomic)
    } catch {
      return .fallback(diagnostic(
        .unreadableDataSet,
        message: "The " + resourceName + " Data Set could not be staged for ModelIO.",
        fallbackReason: "Use the legacy assistant renderer while the bundled asset remains unreadable."
      ))
    }
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    let mdlAsset = MDLAsset(url: temporaryURL)
    guard mdlAsset.count > 0 else {
      return .fallback(diagnostic(
        .unsupportedDataSet,
        message: "ModelIO did not find a model object in the " + resourceName + " Data Set.",
        fallbackReason: "Use the legacy assistant renderer for an empty or unsupported asset."
      ))
    }
    guard let loadedScene = scene(from: mdlAsset) else {
      return .fallback(diagnostic(
        .unsupportedDataSet,
        message: "SceneKit could not convert the " + resourceName + " ModelIO asset.",
        fallbackReason: "Use the legacy assistant renderer when the target OS cannot convert the USDZ asset."
      ))
    }

    let sceneCopy = SCNScene()
    let modelRoot = loadedScene.rootNode.childNode(withName: "CookingFairy", recursively: true)?.clone() ?? loadedScene.rootNode.clone()
    sceneCopy.rootNode.addChildNode(modelRoot)
    let result = validate(scene: sceneCopy, resourceName: resourceName, requireSkin: true)
    if case let .loaded(asset) = result, let textureBundle {
      asset.bindBundledMaterials(bundle: textureBundle)
    }
    return result
  }

  /// Validates an already converted SceneKit graph. The `requireSkin` switch is
  /// internal so unit tests can exercise deterministic naming diagnostics with
  /// small in-memory scenes without manufacturing a full SCNSkinner buffer.
  static func validate(scene: SCNScene, requireSkin: Bool = true) -> QFAssistantModelAssetLoadResult {
    validate(scene: scene, resourceName: "fixture", requireSkin: requireSkin)
  }

  private static func validate(scene: SCNScene, resourceName: String, requireSkin: Bool) -> QFAssistantModelAssetLoadResult {
    guard scene.rootNode.childNodes.isEmpty == false else {
      return .fallback(diagnostic(
        .emptyScene,
        message: "The converted " + resourceName + " scene has no root children.",
        fallbackReason: "Use the legacy assistant renderer when the converted scene is empty."
      ))
    }

    let modelRoot = scene.rootNode.childNode(withName: "CookingFairy", recursively: true) ?? scene.rootNode
    let requiredLocators = [
      "character.root", "character.head", "character.left-eye", "character.right-eye",
      "character.left-brow", "character.right-brow", "character.mouth",
      "character.left-arm", "character.right-arm", "character.left-leg", "character.right-leg",
    ]
    var locatorNodes = Dictionary(uniqueKeysWithValues: requiredLocators.compactMap { name in
      findNode(named: name, in: modelRoot).map { (name, $0) }
    })
    var missingLocators = requiredLocators.filter { locatorNodes[$0] == nil }
    if requireSkin && missingLocators.isEmpty == false {
      for (name, node) in synthesizedLocators(missing: missingLocators, in: modelRoot) {
        locatorNodes[name] = node
      }
      missingLocators = requiredLocators.filter { locatorNodes[$0] == nil }
    }
    guard missingLocators.isEmpty else {
      return .fallback(diagnostic(
        .missingRequiredLocator,
        message: "The " + resourceName + " scene is missing required character locators.",
        missingNames: missingLocators,
        fallbackReason: "Reject the partial graph and use assistant-character.scn so poses do not target the wrong nodes."
      ))
    }

    let missingBones = requiredBoneNames.filter { findNode(named: $0, in: modelRoot) == nil }
    guard missingBones.isEmpty else {
      return .fallback(diagnostic(
        .missingRequiredLocator,
        message: "The " + resourceName + " scene is missing required deform bones.",
        missingNames: missingBones,
        fallbackReason: "Reject the partial rig and keep the old model as the animation fallback."
      ))
    }

    let meshNodes = allNodes(in: modelRoot).filter { $0.geometry != nil }
    if requireSkin && meshNodes.contains(where: { $0.skinner != nil }) == false {
      return .fallback(diagnostic(
        .incompleteSkin,
        message: "The " + resourceName + " scene has geometry but no SceneKit skinner.",
        fallbackReason: "Reject a static mesh so the App never silently loses character posing."
      ))
    }

    var morphChannels: [String: QFAssistantMorphChannel] = [:]
    for node in meshNodes {
      guard let morpher = node.morpher else { continue }
      for index in morpher.targets.indices { morpher.setWeight(0, forTargetAt: index) }
      for (index, target) in morpher.targets.enumerated() {
        guard let name = target.name else { continue }
        morphChannels[name] = QFAssistantMorphChannel(name: name, morpher: morpher, index: index)
      }
    }
    let missingMorphs = requiredMorphNames.filter { morphChannels[$0] == nil }
    guard missingMorphs.isEmpty else {
      return .fallback(diagnostic(
        .missingMorphChannel,
        message: "The " + resourceName + " scene is missing expression channels.",
        missingNames: missingMorphs,
        fallbackReason: "Reject the partial expression set so blink and emotion updates remain deterministic."
      ))
    }

    // The corrected USDZ is deliberately a rest mesh/skin. The app owns the
    // action timeline; importing a merged auto-playing USD animation here
    // would compete with the controller and overwrite expression weights.
    for node in allNodes(in: modelRoot) { node.removeAllAnimations() }

    normalize(modelRoot)
    for node in meshNodes {
      node.geometry?.materials.forEach { material in
        material.lightingModel = .physicallyBased
        material.isDoubleSided = true
      }
    }

    let nodeMap = QFAssistantNodeMap(
      root: modelRoot,
      head: findNode(named: "head", in: modelRoot)!,
      leftArm: chain(["upper_arm.L", "forearm.L", "hand.L"], in: modelRoot),
      rightArm: chain(["upper_arm.R", "forearm.R", "hand.R"], in: modelRoot),
      leftLeg: chain(["thigh.L", "shin.L", "foot.L"], in: modelRoot),
      rightLeg: chain(["thigh.R", "shin.R", "foot.R"], in: modelRoot),
      face: QFAssistantFaceLocatorMap(
        leftEye: locatorNodes["character.left-eye"]!,
        rightEye: locatorNodes["character.right-eye"]!,
        leftBrow: locatorNodes["character.left-brow"]!,
        rightBrow: locatorNodes["character.right-brow"]!,
        mouth: locatorNodes["character.mouth"]!
      ),
      bones: Dictionary(uniqueKeysWithValues: requiredBoneNames.compactMap { name in
        findNode(named: name, in: modelRoot).map { (name, $0) }
      }),
      morphChannels: morphChannels
    )
    return .loaded(QFAssistantModelAsset(scene: scene, rootNode: modelRoot, nodeMap: nodeMap, resourceName: resourceName))
  }

  /// USDZ texture references are not consistently decoded by ModelIO/ImageIO
  /// on every iOS runtime. Bind the mobile texture datasets explicitly after
  /// the rig has been validated, then use a visible fallback color if a texture
  /// is unavailable. This keeps the character readable while preserving the
  /// imported skin, morphs, and animation graph.
  private func bindBundledMaterials(bundle: Bundle) {
    let baseColor = Self.image(named: "cooking-fairy-mobile-basecolor", bundle: bundle)
    let hasBaseColor = baseColor != nil
    let fallbackColor = UIColor(red: 0.95, green: 0.67, blue: 0.39, alpha: 1.0)

    for node in Self.allNodes(in: rootNode) {
      guard let geometry = node.geometry else { continue }
      if geometry.materials.isEmpty {
        geometry.materials = [SCNMaterial()]
      }
      geometry.materials = geometry.materials.map { _ in
        // The Hunyuan base color contains the character's illustrated shading.
        // A fresh unlit material reproduces it faithfully in the small overlay,
        // independent of ModelIO's PBR conversion and background brightness.
        // The geometry, skin and expressions remain fully three-dimensional.
        let material = SCNMaterial()
        material.name = "CookingFairy_Illustrated"
        material.lightingModel = .constant
        if let baseColor { material.diffuse.contents = baseColor }
        else { material.diffuse.contents = fallbackColor }
        material.isDoubleSided = true
        return material
      }
    }

    if hasBaseColor == false {
      // Keep the fallback observable in diagnostics without changing the
      // loader contract or forcing a second render path in the view.
      NSLog("QFAssistantModelAsset: mobile PBR base color is unavailable; using fallback material for %@", resourceName)
    }
  }

  private static func image(named name: String, bundle: Bundle) -> UIImage? {
    guard let dataAsset = NSDataAsset(name: name, bundle: bundle) else { return nil }
    return UIImage(data: dataAsset.data, scale: UIScreen.main.scale)
  }

  private static func scene(from asset: MDLAsset) -> SCNScene? {
    let selector = NSSelectorFromString("sceneWithMDLAsset:")
    guard SCNScene.responds(to: selector) else { return nil }
    return SCNScene.perform(selector, with: asset)?.takeUnretainedValue() as? SCNScene
  }

  private static func normalize(_ root: SCNNode) {
    let bounds = root.boundingBox
    let sourceHeight = max(0.001, bounds.max.z - bounds.min.z)
    let targetHeight: Float = 1.80
    let scale = targetHeight / sourceHeight
    root.eulerAngles.x = -.pi / 2
    root.scale = SCNVector3(scale, scale, scale)
    root.position = SCNVector3(0, -bounds.min.z * scale, 0)
  }

  private static func chain(_ names: [String], in root: SCNNode) -> [SCNNode] {
    names.compactMap { findNode(named: $0, in: root) }
  }

  private static func synthesizedLocators(missing: [String], in root: SCNNode) -> [String: SCNNode] {
    let head = findNode(named: "head", in: root)
    let anchors: [String: (SCNNode?, SCNVector3)] = [
      "character.root": (root, SCNVector3Zero),
      "character.head": (head, SCNVector3Zero),
      "character.left-eye": (head, SCNVector3(-0.11, 0.0, 0.12)),
      "character.right-eye": (head, SCNVector3(0.11, 0.0, 0.12)),
      "character.left-brow": (head, SCNVector3(-0.11, 0.03, 0.16)),
      "character.right-brow": (head, SCNVector3(0.11, 0.03, 0.16)),
      "character.mouth": (head, SCNVector3(0.0, -0.02, 0.08)),
      "character.left-arm": (findNode(named: "upper_arm.L", in: root), SCNVector3Zero),
      "character.right-arm": (findNode(named: "upper_arm.R", in: root), SCNVector3Zero),
      "character.left-leg": (findNode(named: "thigh.L", in: root), SCNVector3Zero),
      "character.right-leg": (findNode(named: "thigh.R", in: root), SCNVector3Zero),
    ]
    var result: [String: SCNNode] = [:]
    for name in missing {
      guard let (parent, position) = anchors[name], let parent else { continue }
      let node = SCNNode()
      node.name = name
      node.position = position
      parent.addChildNode(node)
      result[name] = node
    }
    return result
  }

  private static func findNode(named canonicalName: String, in root: SCNNode) -> SCNNode? {
    let aliases = [
      canonicalName,
      canonicalName.replacingOccurrences(of: ".", with: "_"),
      canonicalName.replacingOccurrences(of: "-", with: "_"),
      canonicalName.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "-", with: "_"),
    ]
    if let name = root.name, aliases.contains(name) { return root }
    for child in root.childNodes {
      if let match = findNode(named: canonicalName, in: child) { return match }
    }
    return nil
  }

  private static func allNodes(in root: SCNNode) -> [SCNNode] {
    [root] + root.childNodes.flatMap { allNodes(in: $0) }
  }

  private static func diagnostic(_ code: QFAssistantModelAssetDiagnosticCode, message: String, missingNames: [String] = [], fallbackReason: String) -> QFAssistantModelAssetDiagnostic {
    QFAssistantModelAssetDiagnostic(code: code, message: message, missingNames: missingNames, fallbackReason: fallbackReason)
  }
}
