import SnapKit
import UIKit

@MainActor
final class QFMovePlanViewController: QFProfileContentController {
  private struct LocalDraft: Codable {
    let original: QFPlannedMeal
    var value: QFPlannedMealDraft
  }
  private let draftKey: String
  private let saved: () -> Void
  private var local: LocalDraft
  private var savedSuccessfully = false
  override var reloadsOnAppearance: Bool { false }
  override var hasUnsavedChanges: Bool { !savedSuccessfully && !local.original.matches(local.value) }

  init(app: QFAppSession, item: QFPlannedMeal, saved: @escaping () -> Void) {
    draftKey = "move-plan.\(item.id)"; self.saved = saved
    local = QFContentDraftStore.load(LocalDraft.self, app: app, kind: draftKey)
      ?? LocalDraft(original: item, value: item.editDraft)
    super.init(app: app, title: app.text("移动日期 / 餐次", "Move date / meal"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "plan.move.editor"
    let save = addFooter(app.text("保存修改", "Save changes")) { [weak self] in self?.submit() }
    save.accessibilityIdentifier = "plan.move.save"
    render()
  }
  private func persist() {
    if !QFContentDraftStore.save(local, app: app, kind: draftKey) {
      message(app.text("草稿保存失败，请重试。", "Could not save the draft. Please retry."), error: true)
    }
  }
  private func render() {
    QFTabUI.clear(bodyStack)
    bodyStack.addArrangedSubview(QFContentUI.label(local.original.title ?? app.text("未命名菜谱", "Untitled recipe"), size: 20, bold: true))
    let picker = UIDatePicker()
    picker.datePickerMode = .date; picker.preferredDatePickerStyle = .compact
    picker.calendar = QFManualPlanDraft.calendar; picker.timeZone = QFManualPlanDraft.calendar.timeZone
    picker.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    picker.minimumDate = QFManualPlanDraft.date("1000-01-01")
    picker.maximumDate = QFManualPlanDraft.date("9999-12-31")
    picker.date = QFManualPlanDraft.date(local.value.date) ?? Date()
    picker.accessibilityIdentifier = "plan.move.date"
    picker.accessibilityLabel = app.text("日期", "Date")
    picker.addAction(UIAction { [weak self, weak picker] _ in
      guard let self, let picker else { return }
      let formatter = DateFormatter(); formatter.calendar = QFManualPlanDraft.calendar
      formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = QFManualPlanDraft.calendar.timeZone
      formatter.dateFormat = "yyyy-MM-dd"
      self.local.value.date = formatter.string(from: picker.date); self.persist()
    }, for: .valueChanged)
    let row = QFTabUI.stack([QFContentUI.label(app.text("日期", "Date")), UIView(), picker], axis: .horizontal, spacing: 8)
    row.alignment = .center
    bodyStack.addArrangedSubview(QFTabUI.card(row))
    let codes = ["BREAKFAST", "LUNCH", "DINNER", "SNACK"]
    let meal = UISegmentedControl(items: codes.map { QFCookingMeal(rawValue: $0)!.title(app: app) })
    meal.selectedSegmentIndex = codes.firstIndex(of: local.value.meal) ?? 0
    meal.backgroundColor = QFUI.paleGreen; meal.selectedSegmentTintColor = QFUI.surface
    meal.accessibilityIdentifier = "plan.move.meal"
    meal.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
    meal.addAction(UIAction { [weak self, weak meal] _ in
      guard let self, let index = meal?.selectedSegmentIndex, codes.indices.contains(index) else { return }
      self.local.value.meal = codes[index]; self.persist()
    }, for: .valueChanged)
    bodyStack.addArrangedSubview(meal)
  }
  private func submit() {
    guard hasUnsavedChanges else { qfClose(); return }
    persist()
    let draft = local.value, id = local.original.id
    execute { [self] in
      do {
        _ = try await app.adjustPlannedMeal(id, draft: draft)
        QFContentDraftStore.remove(app: app, kind: draftKey)
        savedSuccessfully = true; saved(); qfClose()
      } catch let error as QFAPIError where error.code == 40900 {
        confirm(app.text("内容已变更", "Content changed"),
          detail: app.text("重新载入最新计划后再修改？当前未提交的修改将被替换。", "Reload the latest plan to edit it? This will replace your unsaved changes.")) { [weak self] in
            self?.reloadLatest()
          }
      }
    }
  }
  private func reloadLatest() {
    execute(reloadOnFailure: true) { [self] in
      let latest = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.plannedMeal(local.original.id) }
      local = LocalDraft(original: latest, value: latest.editDraft)
      persist(); render()
    }
  }
}
