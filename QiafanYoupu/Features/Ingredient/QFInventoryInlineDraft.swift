import CoreText
import Foundation
import SnapKit
import UIKit

/// Local-only edits. Once attempted, the exact request is retained until a definite response.
struct QFInventoryInlineDraft: Codable {
  let lot: QFInventoryLot
  var language: String? = nil
  var quantity: String
  var location: String
  var selectedUnitCode: String? = nil
  var effectiveUnitCode: String { selectedUnitCode ?? lot.unitCode }
  var pendingEdit: QFInventoryEditRequest?
  var pendingArchive: QFInventoryArchiveRequest?
  var isFrozen: Bool { pendingEdit != nil || pendingArchive != nil }
  init(lot: QFInventoryLot, language: String? = nil) {
    self.lot = lot; self.language = language; quantity = lot.currentQuantity; location = lot.location
  }
  mutating func convertUnit(to target: QFMeasurementUnit, units: [QFMeasurementUnit]) -> Bool {
    guard !isFrozen, let source = units.first(where: { $0.code == effectiveUnitCode }),
      source.dimension == target.dimension, ["MASS", "VOLUME"].contains(source.dimension),
      let raw = normalizedQuantity, let amount = Decimal(string: raw),
      let from = Decimal(string: source.factorToBase), let to = Decimal(string: target.factorToBase), from > 0, to > 0 else { return false }
    var value = amount * from / to; var rounded = Decimal()
    NSDecimalRound(&rounded, &value, 6, .plain)
    guard rounded == value, target.decimalAllowed || rounded == Decimal(NSDecimalNumber(decimal: rounded).int64Value) else { return false }
    quantity = NSDecimalNumber(decimal: rounded).stringValue; selectedUnitCode = target.code; return true
  }

  var normalizedQuantity: String? {
    let value = quantity.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
    guard value.range(of: #"^\d{1,14}(\.\d{1,6})?$"#, options: .regularExpression) != nil,
      let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), number >= 0 else { return nil }
    return NSDecimalNumber(decimal: number).stringValue
  }
}

enum QFInventoryLayout {
  static let cardRadius: CGFloat = 16
  static let iconSize: CGFloat = 48
  static let fieldHeight: CGFloat = 44
  static let sheetRadius: CGFloat = 26
}

@MainActor enum QFInventoryArtwork {
  static func make(ingredientID: String, category: String?, iconKey: String? = nil) -> UIView {
    let artworkID = iconKey ?? ingredientID
    // Canonical IDs only; never infer identity from translated display names.
    let dedicated = ["tomato": "🍅", "broccoli": "🥦", "egg": "🥚", "milk": "🥛", "carrot": "🥕", "potato": "🥔", "cucumber": "🥒", "onion": "🧅", "apple": "🍎", "salt": "🧂"]
    let fallback = ["VEGETABLE": "🥬", "MEAT_EGG": "🥩", "DAIRY": "🥛", "FRUIT": "🍎", "GRAIN": "🌾", "SEAFOOD": "🐟", "FUNGI_ALGAE": "🍄", "SEASONING": "🧂"]
    // Reuse the app's approved Emoji artwork. Some simulator runtimes advertise
    // AppleColorEmoji but render missing-glyph boxes even after CoreText resolution.
    let assets = ["VEGETABLE": "vegetable", "MEAT_EGG": "meat", "DAIRY": "milk", "FRUIT": "fruit", "GRAIN": "grain", "SEAFOOD": "seafood", "FUNGI_ALGAE": "mushroom", "SEASONING": "seasoning"]
    let dedicatedAssets = ["apple": "fruit", "salt": "seasoning"]
    let approvedAssets: Set<String> = ["tomato", "broccoli", "egg", "milk", "carrot", "potato", "cucumber", "onion", "fruit", "seasoning", "vegetable", "meat", "seafood", "grain", "mushroom", "generic"]
    let name = approvedAssets.contains(artworkID) ? artworkID : dedicated[artworkID] != nil ? dedicatedAssets[artworkID] ?? artworkID : assets[category ?? ""] ?? "generic"
    if let artwork = UIImage(named: "ingredient-" + name) {
      let slot = UIView(); slot.backgroundColor = QFUI.paleGreen; slot.layer.cornerRadius = 12
      let image = UIImageView(image: artwork); image.contentMode = .scaleAspectFit; image.isAccessibilityElement = false
      slot.addSubview(image); image.snp.makeConstraints { $0.center.equalToSuperview(); $0.size.equalTo(36) }
      slot.snp.makeConstraints { $0.size.equalTo(QFInventoryLayout.iconSize) }
      return slot
    }
    let emoji = dedicated[artworkID] ?? fallback[category ?? ""] ?? "🍽️"
    let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 32, nil)
    let resolved = CTFontCreateForString(font, emoji as CFString, CFRange(location: 0, length: emoji.utf16.count))
    var characters = Array(emoji.utf16), glyphs = [CGGlyph](repeating: 0, count: emoji.utf16.count)
    CTFontGetGlyphsForCharacters(resolved, &characters, &glyphs, characters.count)
    if glyphs.allSatisfy({ $0 == 0 }) || (CTFontCopyPostScriptName(resolved) as String).localizedCaseInsensitiveContains("LastResort") {
      let names = ["VEGETABLE": "leaf", "FRUIT": "carrot", "SEAFOOD": "fish", "DAIRY": "mug", "GRAIN": "leaf", "SEASONING": "drop", "MEAT_EGG": "fork.knife", "FUNGI_ALGAE": "leaf"]
      let symbol = QFTabUI.symbol(names[category ?? ""] ?? "fork.knife", size: 30, color: QFUI.green)
      let slot = UIView(); slot.backgroundColor = QFUI.paleGreen; slot.layer.cornerRadius = 12
      slot.addSubview(symbol); symbol.snp.makeConstraints { $0.center.equalToSuperview() }
      slot.snp.makeConstraints { $0.size.equalTo(QFInventoryLayout.iconSize) }
      return slot
    }
    let label = QFTabUI.label(emoji, size: 32)
    label.font = UIFont(name: "AppleColorEmoji", size: 32) ?? .systemFont(ofSize: 32)
    label.textAlignment = .center; label.isAccessibilityElement = false
    label.backgroundColor = QFUI.paleGreen; label.layer.cornerRadius = 12; label.clipsToBounds = true
    label.snp.makeConstraints { $0.size.equalTo(QFInventoryLayout.iconSize) }
    return label
  }
}

@MainActor final class QFInventoryDeleteSheet: UIViewController {
  private let app: QFAppSession
  private let context: String
  private let confirm: () -> Void
  init(app: QFAppSession, context: String, confirm: @escaping () -> Void) {
    self.app = app; self.context = context; self.confirm = confirm
    super.init(nibName: nil, bundle: nil); modalPresentationStyle = .pageSheet
    if let sheet = sheetPresentationController {
      if #available(iOS 16.0, *) {
        sheet.detents = [.custom(identifier: .init("inventory-delete")) { min(360, $0.maximumDetentValue) }, .large()]
      } else { sheet.detents = [.medium(), .large()] }
      sheet.prefersGrabberVisible = true; sheet.preferredCornerRadius = QFInventoryLayout.sheetRadius
    }
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = QFUI.background
    view.accessibilityIdentifier = "inventory.delete.sheet"
    let scroll = UIScrollView(); view.addSubview(scroll)
    scroll.snp.makeConstraints { $0.edges.equalTo(view.safeAreaLayoutGuide) }
    let symbol = QFTabUI.symbol("trash", size: 28, color: QFUI.danger)
    let title = QFTabUI.label(app.text("删除这条库存？", "Delete this stock item?"), size: 21, weight: .semibold, lines: 0)
    let subtitle = QFTabUI.label(context, size: 16, lines: 0)
    let detail = QFTabUI.label(app.text("已有计划会保留，重新生成采购单时将按剩余库存计算。", "Your plans will stay. Regenerating the shopping list will use the remaining stock."), size: 14, color: QFUI.secondary, lines: 0)
    [title, subtitle, detail].forEach { $0.textAlignment = .center }
    let cancel = QFTabUI.button(app.text("取消", "Cancel"), background: QFUI.surface) { [weak self] in self?.dismiss(animated: true) }
    let delete = QFTabUI.button(app.text("确认删除", "Confirm deletion"), color: .white, background: QFUI.danger) { [weak self] in
      guard let self else { return }; self.dismiss(animated: true, completion: self.confirm)
    }
    delete.accessibilityIdentifier = "inventory.delete.confirm"; cancel.accessibilityIdentifier = "inventory.delete.cancel"
    cancel.snp.makeConstraints { $0.height.greaterThanOrEqualTo(48) }; delete.snp.makeConstraints { $0.height.greaterThanOrEqualTo(48) }
    cancel.titleLabel?.numberOfLines = 2; delete.titleLabel?.numberOfLines = 2
    let actions = QFTabUI.stack([cancel, delete], axis: .horizontal, spacing: 12); actions.distribution = .fillEqually
    let iconRow = QFTabUI.stack([UIView(), symbol, UIView()], axis: .horizontal, spacing: 0); iconRow.distribution = .equalCentering
    let stack = QFTabUI.stack([iconRow, title, subtitle, detail, actions], spacing: 18)
    scroll.addSubview(stack)
    stack.snp.makeConstraints { $0.edges.equalTo(scroll.contentLayoutGuide).inset(UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20)); $0.width.equalTo(scroll.frameLayoutGuide).offset(-40) }
  }
}
