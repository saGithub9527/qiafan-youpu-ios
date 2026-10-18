import Foundation
import AppKit
import SceneKit

let outputPath = CommandLine.arguments.dropFirst().first ?? "assistant-character.scn"
let scene = SCNScene()
let character = SCNNode()
character.name = "assistant.character.asset"
scene.rootNode.addChildNode(character)

func material(_ color: NSColor, roughness: CGFloat = 0.72, metalness: CGFloat = 0) -> SCNMaterial {
  let value = SCNMaterial()
  value.lightingModel = .physicallyBased
  value.diffuse.contents = color
  value.roughness.contents = NSNumber(value: Float(roughness))
  value.metalness.contents = NSNumber(value: Float(metalness))
  return value
}

func add(_ geometry: SCNGeometry, _ name: String, _ material: SCNMaterial, _ position: SCNVector3 = SCNVector3(0, 0, 0), to parent: SCNNode) -> SCNNode {
  geometry.materials = [material]
  let node = SCNNode(geometry: geometry)
  node.name = name
  node.position = position
  parent.addChildNode(node)
  return node
}

func capsule(_ radius: CGFloat, _ height: CGFloat, _ color: NSColor, _ name: String, _ position: SCNVector3, to parent: SCNNode) -> SCNNode {
  add(SCNCapsule(capRadius: radius, height: height), name, material(color), position, to: parent)
}

func sphere(_ radius: CGFloat, _ color: NSColor, _ name: String, _ position: SCNVector3, _ scale: SCNVector3 = SCNVector3(1, 1, 1), to parent: SCNNode) -> SCNNode {
  let node = add(SCNSphere(radius: radius), name, material(color), position, to: parent)
  node.scale = scale
  return node
}

func leaf(_ name: String, _ position: SCNVector3, _ rotation: CGFloat, to parent: SCNNode) {
  let node = sphere(0.23, NSColor(calibratedRed: 0.12, green: 0.25, blue: 0.12, alpha: 1), name, position, SCNVector3(0.62, 0.16, 1.15), to: parent)
  node.eulerAngles.z = rotation
}

let skin = NSColor(calibratedRed: 0.98, green: 0.74, blue: 0.62, alpha: 1)
let hair = NSColor(calibratedRed: 1.00, green: 0.76, blue: 0.54, alpha: 1)
let hairShadow = NSColor(calibratedRed: 0.91, green: 0.56, blue: 0.36, alpha: 1)
let leafGreen = NSColor(calibratedRed: 0.12, green: 0.25, blue: 0.12, alpha: 1)
let cream = NSColor(calibratedRed: 0.96, green: 0.87, blue: 0.71, alpha: 1)
let apronGreen = NSColor(calibratedRed: 0.12, green: 0.28, blue: 0.17, alpha: 1)
let orange = NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.13, alpha: 1)
let gold = NSColor(calibratedRed: 0.93, green: 0.64, blue: 0.16, alpha: 1)
let eyeGreen = NSColor(calibratedRed: 0.33, green: 0.56, blue: 0.20, alpha: 1)
let eyeAmber = NSColor(calibratedRed: 0.94, green: 0.65, blue: 0.16, alpha: 1)
let dark = NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.04, alpha: 1)
let lip = NSColor(calibratedRed: 0.72, green: 0.17, blue: 0.18, alpha: 1)
let blush = NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.38, alpha: 0.48)

// Chibi proportions follow the original mascot: oversized expressive head, compact body,
// cream cooking uniform, dark-green leaf motif and orange scarf accents.
let torso = add(SCNBox(width: 0.72, height: 0.76, length: 0.45, chamferRadius: 0.16), "assistant.torso", material(cream), SCNVector3(0, 0.34, 0), to: character)
_ = torso
_ = add(SCNBox(width: 0.50, height: 0.60, length: 0.055, chamferRadius: 0.04), "assistant.apron", material(apronGreen), SCNVector3(0, 0.25, 0.25), to: character)
let apronPocket = add(SCNBox(width: 0.30, height: 0.20, length: 0.035, chamferRadius: 0.02), "assistant.apron-pocket", material(apronGreen), SCNVector3(0, 0.08, 0.285), to: character)
apronPocket.eulerAngles.z = -0.08
// Orange neckerchief and waist bow from the static mascot.
_ = add(SCNBox(width: 0.34, height: 0.14, length: 0.07, chamferRadius: 0.03), "assistant.neckerchief", material(orange), SCNVector3(0, 0.74, 0.18), to: character)
let waistBow = add(SCNBox(width: 0.38, height: 0.10, length: 0.055, chamferRadius: 0.03), "assistant.waist-bow", material(orange), SCNVector3(0, 0.51, 0.30), to: character)
waistBow.eulerAngles.z = -0.12
_ = sphere(0.075, gold, "assistant.waist-flower-center", SCNVector3(0, 0.51, 0.34), SCNVector3(1, 0.82, 0.55), to: character)

let head = SCNNode(); head.name = "assistant.head"; head.position = SCNVector3(0, 1.36, 0); character.addChildNode(head)
_ = sphere(0.47, skin, "assistant.face", SCNVector3(0, 0, 0), SCNVector3(0.96, 1.10, 0.91), to: head)
// Hair cap, side curls and top curl mirror the silhouette of the original static asset.
_ = sphere(0.49, hair, "assistant.hair", SCNVector3(0, 0.20, -0.02), SCNVector3(1.00, 0.63, 0.94), to: head)
let fringe = add(SCNBox(width: 0.64, height: 0.20, length: 0.09, chamferRadius: 0.08), "assistant.fringe", material(hair), SCNVector3(-0.02, 0.31, 0.33), to: head)
fringe.eulerAngles.z = -0.09
_ = sphere(0.18, hairShadow, "assistant.left-curl", SCNVector3(-0.40, -0.02, 0.06), SCNVector3(0.72, 1.30, 0.90), to: head)
_ = sphere(0.18, hairShadow, "assistant.right-curl", SCNVector3(0.40, -0.02, 0.06), SCNVector3(0.72, 1.30, 0.90), to: head)
let topCurl = capsule(0.055, 0.34, hair, "assistant.top-curl", SCNVector3(0.04, 0.52, 0), to: head)
topCurl.eulerAngles.z = -0.28
let headband = add(SCNBox(width: 0.76, height: 0.075, length: 0.055, chamferRadius: 0.035), "assistant.headband", material(leafGreen), SCNVector3(0, 0.28, 0.31), to: head)
headband.eulerAngles.z = -0.05
leaf("assistant.leaf-left", SCNVector3(-0.38, 0.29, 0.28), -0.35, to: head)
leaf("assistant.leaf-right", SCNVector3(0.38, 0.25, 0.27), 0.35, to: head)
let flowerCenter = sphere(0.055, gold, "assistant.hair-flower-center", SCNVector3(0.33, 0.27, 0.36), to: head)
for (index, offset) in [SCNVector3(0, 0.085, 0), SCNVector3(0.085, 0, 0), SCNVector3(0, -0.085, 0), SCNVector3(-0.085, 0, 0)].enumerated() {
  let position = SCNVector3(flowerCenter.position.x + offset.x, flowerCenter.position.y + offset.y, flowerCenter.position.z + offset.z)
  _ = sphere(0.06, cream, "assistant.hair-flower-petal-\(index)", position, SCNVector3(0.80, 1.12, 0.36), to: head)
}

let leftEye = SCNNode(); leftEye.name = "assistant.left-eye"; leftEye.position = SCNVector3(-0.16, 0.07, 0.40); leftEye.scale = SCNVector3(1, 0.82, 0.44); head.addChildNode(leftEye)
let rightEye = SCNNode(); rightEye.name = "assistant.right-eye"; rightEye.position = SCNVector3(0.16, 0.07, 0.40); rightEye.scale = SCNVector3(1, 0.88, 0.44); head.addChildNode(rightEye)
_ = add(SCNSphere(radius: 0.105), "assistant.left-eye-white", material(NSColor.white), to: leftEye)
_ = add(SCNSphere(radius: 0.105), "assistant.right-eye-white", material(NSColor.white), to: rightEye)
_ = sphere(0.073, eyeGreen, "assistant.left-pupil", SCNVector3(0, 0, 0.072), SCNVector3(0.92, 1.18, 0.45), to: leftEye)
_ = sphere(0.073, eyeAmber, "assistant.right-pupil", SCNVector3(0, 0, 0.072), SCNVector3(0.92, 1.18, 0.45), to: rightEye)
_ = sphere(0.025, dark, "assistant.left-eye-glint", SCNVector3(-0.02, 0.035, 0.108), to: leftEye)
_ = sphere(0.025, dark, "assistant.right-eye-glint", SCNVector3(-0.02, 0.035, 0.108), to: rightEye)
let browGeometry = SCNBox(width: 0.20, height: 0.035, length: 0.035, chamferRadius: 0.014)
let leftBrow = add(browGeometry, "assistant.left-brow", material(hairShadow), SCNVector3(-0.16, 0.22, 0.41), to: head)
let rightBrow = add(browGeometry.copy() as! SCNGeometry, "assistant.right-brow", material(hairShadow), SCNVector3(0.16, 0.22, 0.41), to: head)
leftBrow.eulerAngles.z = 0.10; rightBrow.eulerAngles.z = -0.10
_ = sphere(0.048, skin, "assistant.nose", SCNVector3(0, -0.02, 0.43), SCNVector3(0.65, 0.90, 0.68), to: head)
_ = sphere(0.07, blush, "assistant.left-cheek", SCNVector3(-0.25, -0.10, 0.40), SCNVector3(1.4, 0.45, 0.25), to: head)
_ = sphere(0.07, blush, "assistant.right-cheek", SCNVector3(0.25, -0.10, 0.40), SCNVector3(1.4, 0.45, 0.25), to: head)
_ = add(SCNBox(width: 0.20, height: 0.027, length: 0.025, chamferRadius: 0.012), "assistant.mouth-line", material(lip, roughness: 0.55), SCNVector3(0, -0.18, 0.41), to: head)
let mouthOpen = sphere(0.075, lip, "assistant.mouth-open", SCNVector3(0, -0.18, 0.41), SCNVector3(1.22, 0.72, 0.38), to: head)
mouthOpen.isHidden = true

func arm(_ side: Float, _ name: String) {
  let arm = SCNNode(); arm.name = name; arm.position = SCNVector3(0.48 * side, 0.62, 0); character.addChildNode(arm)
  _ = capsule(0.13, 0.52, cream, "assistant.upper-arm", SCNVector3(0, -0.25, 0), to: arm)
  let cuff = add(SCNCylinder(radius: 0.13, height: 0.16), "assistant.cuff", material(leafGreen), SCNVector3(0, -0.51, 0), to: arm)
  cuff.eulerAngles.z = .pi / 2
  let elbow = SCNNode(); elbow.name = side < 0 ? "assistant.left-elbow" : "assistant.right-elbow"; elbow.position = SCNVector3(0, -0.57, 0); arm.addChildNode(elbow)
  _ = capsule(0.095, 0.34, skin, "assistant.forearm", SCNVector3(0, -0.17, 0), to: elbow)
  _ = sphere(0.12, skin, "assistant.hand", SCNVector3(0, -0.38, 0), SCNVector3(0.86, 1.08, 0.86), to: elbow)
}
arm(-1, "assistant.left-arm"); arm(1, "assistant.right-arm")

func leg(_ side: Float, _ name: String) {
  let leg = SCNNode(); leg.name = name; leg.position = SCNVector3(0.18 * side, -0.05, 0); character.addChildNode(leg)
  _ = capsule(0.15, 0.63, apronGreen, "assistant.trouser", SCNVector3(0, -0.32, 0), to: leg)
  _ = capsule(0.09, 0.20, cream, "assistant.sock", SCNVector3(0, -0.68, 0), to: leg)
  let shoe = add(SCNBox(width: 0.28, height: 0.15, length: 0.43, chamferRadius: 0.06), "assistant.shoe", material(leafGreen, metalness: 0.05), SCNVector3(0, -0.80, 0.09), to: leg)
  shoe.eulerAngles.y = side < 0 ? -0.06 : 0.06
  _ = sphere(0.035, gold, "assistant.shoe-button", SCNVector3(0, -0.76, 0.30), to: leg)
}
leg(-1, "assistant.left-leg"); leg(1, "assistant.right-leg")

// A small spoon is an accessory attached to the hand, matching the reference character.
// Re-parent the spoon under the right elbow so it follows the arm pose.
if let rightElbowNode = character.childNode(withName: "assistant.right-arm", recursively: true)?.childNode(withName: "assistant.right-elbow", recursively: true) {
  let spoon = SCNNode(); spoon.name = "assistant.spoon"; spoon.position = SCNVector3(0.10, -0.38, 0.08); spoon.eulerAngles.z = -0.55
  spoon.addChildNode(add(SCNCylinder(radius: 0.025, height: 0.36), "assistant.spoon-handle", material(orange), SCNVector3(0, -0.18, 0), to: spoon))
  _ = sphere(0.11, gold, "assistant.spoon-bowl", SCNVector3(0, -0.40, 0), SCNVector3(0.75, 0.26, 1.05), to: spoon)
  rightElbowNode.addChildNode(spoon)
}

let url = URL(fileURLWithPath: outputPath)
scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
print("wrote \(url.path)")
