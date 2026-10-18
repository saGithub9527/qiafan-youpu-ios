import SnapKit
import UIKit

/// Optional package content is explicit; an unspecified box never becomes an estimated weight.
struct QFStockSpecification: Codable, Equatable {
  var packageSize: String?
  var packageContentUnit: String?
  var expiresOn: String?
  static func isPackage(_ code: String) -> Bool { ["box", "bottle", "bag", "pack"].contains(code) }
}
@MainActor
final class QFStockSpecificationViewController: QFProfileContentController {
  private var value: QFStockSpecification
  private let packaged: Bool
  private let units: [QFMeasurementUnit]
  private let confirmed: (QFStockSpecification) -> Void
  private var selectedUnit: String
  private var size = ""
  private var knownSize: Bool
  override var reloadsOnAppearance: Bool { false }
  init(app: QFAppSession, unitCode: String, value: QFStockSpecification, units: [QFMeasurementUnit], confirmed: @escaping (QFStockSpecification) -> Void) {
    self.value = value; packaged = QFStockSpecification.isPackage(unitCode); self.units = units
    self.confirmed = confirmed; selectedUnit = value.packageContentUnit ?? "g"
    size = value.packageSize ?? ""; knownSize = value.packageSize != nil
    super.init(app: app, title: app.text("规格与有效期", "Specification and expiry"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); render()
    _ = addFooter(app.text("确定", "Confirm")) { [weak self] in self?.finish() }
  }
  private func render() {
    QFTabUI.clear(bodyStack)
    if packaged {
      let toggle = UISwitch(); toggle.isOn = knownSize
      toggle.addAction(UIAction { [weak self, weak toggle] _ in guard let self, let toggle else { return }; self.knownSize = toggle.isOn; self.render() }, for: .valueChanged)
      bodyStack.addArrangedSubview(QFTabUI.stack([QFTabUI.label(app.text("已知每包装净含量", "Net content per package is known"), size: 16, lines: 0), UIView(), toggle], axis: .horizontal, spacing: 12))
      if knownSize {
        let sizeField = QFContentUI.field(app.text("每包装净含量", "Net content per package"), text: size, keyboard: .decimalPad) { [weak self] in self?.size = $0 }
        let unit = QFTabUI.button(unitName(selectedUnit), color: QFUI.text, background: QFUI.surface) { [weak self] in self?.chooseUnit() }
        let values = QFTabUI.stack([sizeField, unit], axis: .horizontal, spacing: 12); values.distribution = .fillEqually
        bodyStack.addArrangedSubview(values)
      }
    }
    let expiry = UISwitch(); expiry.isOn = value.expiresOn != nil
    let date = UIDatePicker(); date.datePickerMode = .date; date.preferredDatePickerStyle = .inline
    date.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    date.calendar = QFManualPlanDraft.calendar; date.timeZone = QFManualPlanDraft.calendar.timeZone
    date.date = value.expiresOn.flatMap(QFManualPlanDraft.date) ?? Date(); date.isHidden = value.expiresOn == nil
    date.addAction(UIAction { [weak self, weak date] _ in guard let self, let date else { return }; self.value.expiresOn = QFManualPlanDraft.string(date.date) }, for: .valueChanged)
    expiry.addAction(UIAction { [weak self, weak expiry, weak date] _ in
      guard let self, let expiry, let date else { return }; self.value.expiresOn = expiry.isOn ? QFManualPlanDraft.string(date.date) : nil; date.isHidden = !expiry.isOn
    }, for: .valueChanged)
    bodyStack.addArrangedSubview(QFTabUI.stack([QFTabUI.label(app.text("标注到期日期", "Add expiry date"), size: 16, lines: 0), UIView(), expiry], axis: .horizontal, spacing: 12))
    bodyStack.addArrangedSubview(date)
  }
  private func unitName(_ code: String) -> String { units.first { $0.code == code }?.name ?? code }
  private func chooseUnit() {
    let sheet = UIAlertController(title: app.text("选择单位", "Choose unit"), message: nil, preferredStyle: .actionSheet)
    for unit in units where ["MASS", "VOLUME"].contains(unit.dimension.uppercased()) {
      sheet.addAction(UIAlertAction(title: unit.name + " · " + unit.symbol, style: .default) { [weak self] _ in self?.selectedUnit = unit.code; self?.render() })
    }
    sheet.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel)); sheet.popoverPresentationController?.sourceView = bodyStack; sheet.popoverPresentationController?.sourceRect = bodyStack.bounds; open(sheet)
  }
  private func finish() {
    view.endEditing(true)
    if packaged && knownSize {
      let normalized = QFPurchaseNumber.normalize(size, locale: Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier))
      guard (QFPurchaseNumber.decimal(normalized) ?? 0) > 0 else { message(app.text("请输入大于 0 的数量。", "Enter a quantity greater than 0."), error: true); return }
      value.packageSize = normalized; value.packageContentUnit = selectedUnit
    } else { value.packageSize = nil; value.packageContentUnit = nil }
    confirmed(value); qfClose()
  }
}
