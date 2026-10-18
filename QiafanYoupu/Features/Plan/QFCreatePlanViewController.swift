import Combine
import CryptoKit
import SnapKit
import UIKit

/// Geometry taken from the approved 03/04 plan screens (390 × 844 pt).
enum QFCreatePlanLayout {
  static let pageInset: CGFloat = 20
  static let modeHeight: CGFloat = 38
  static let cardRadius: CGFloat = 18
  static let recipeImageSize: CGFloat = 56
  static let pickerImageSize: CGFloat = 72
  static let actionHeight: CGFloat = 50
}

@MainActor
final class QFCreatePlanViewController: QFProfileContentController {
  private let householdID: String?
  private let householdName: String?
  private let draftKind: String
  private let saved: () -> Void
  private var draft: QFManualPlanDraft
  private var saving = false
  private var persisted = true
  private let countLabel = QFContentUI.label("", size: 13, color: QFUI.secondary)
  private var saveButton: UIButton!
  override var reloadsOnAppearance: Bool { false }
  override var hasUnsavedChanges: Bool { saving || draft.recipeCount > 0 || !persisted }

  init(app: QFAppSession, initialDate: Date, assistantSeed: QFManualPlanDraft? = nil, saved: @escaping () -> Void) {
    householdID = app.planningHouseholdID
    householdName = app.planningScope.householdName
    if let assistantSeed {
      let identity = assistantSeed.recipes.keys.sorted().map { meal in
        ["meal": meal, "recipes": (assistantSeed.recipes[meal] ?? []).map { ["id": $0.id, "language": $0.language] }] as [String: Any]
      }
      let bytes = (try? JSONSerialization.data(withJSONObject: ["startDate": assistantSeed.startDate,
        "endDate": assistantSeed.endDate, "meals": identity], options: [.sortedKeys])) ?? Data()
      let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      draftKind = "assistant-plan.\(app.planningHouseholdID ?? "personal").\(digest)"
    } else { draftKind = "manual-plan.\(app.planningHouseholdID ?? "personal")" }
    self.saved = saved
    draft = QFContentDraftStore.load(QFManualPlanDraft.self, app: app, kind: draftKind) ?? assistantSeed
      ?? QFManualPlanDraft(date: QFContentDate.day(initialDate))
    super.init(app: app, title: app.text("制定计划", "Create plan") + " · " + (app.planningScope.householdName ?? app.text("个人", "Personal")))
  }
  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "plan.create.editor"
    footer.axis = .vertical
    footer.distribution = .fill
    footer.spacing = 8
    countLabel.textAlignment = .center
    saveButton = addFooter(app.text("保存计划", "Save plan")) { [weak self] in self?.submit() }
    saveButton.accessibilityIdentifier = "plan.create.save"
    footer.insertArrangedSubview(countLabel, at: 0)
    let divider = UIView()
    divider.backgroundColor = QFUI.border
    footer.insertArrangedSubview(divider, at: 0)
    divider.snp.makeConstraints { $0.height.equalTo(1 / UIScreen.main.scale) }
    render()
    // A language/scope change does not submit or discard this local draft.
    app.$interfaceLanguage.dropFirst().removeDuplicates().sink { [weak self] _ in
      guard let self else { return }
      self.updateHeading(self.app.text("制定计划", "Create plan") + " · " + (self.householdName ?? self.app.text("个人", "Personal")))
      self.render()
    }.store(in: &cancellables)
  }

  private func persist() -> Bool {
    persisted = QFContentDraftStore.save(draft, app: app, kind: draftKind)
    if !persisted { message(app.text("草稿保存失败，请重试。", "Could not save the draft. Please retry."), error: true) }
    return persisted
  }
  private func changed() { _ = persist(); render() }
  private func render() {
    let language = app.interfaceLanguage
    bodyStack.beginUpdates()
    bodyStack.row("mode", version: "\(draft.usesRange)-\(language)") { [self] in
      let control = UISegmentedControl(items: [app.text("单日", "Single day"), app.text("日期范围", "Date range")])
      control.selectedSegmentIndex = draft.usesRange ? 1 : 0
      control.selectedSegmentTintColor = QFUI.surface
      control.backgroundColor = QFUI.paleGreen
      control.accessibilityIdentifier = "plan.create.dateMode"
      control.snp.makeConstraints { $0.height.greaterThanOrEqualTo(QFCreatePlanLayout.modeHeight) }
      control.addAction(UIAction { [weak self, weak control] _ in
        guard let self, self.draft.pending == nil else { return }
        self.draft.usesRange = control?.selectedSegmentIndex == 1
        self.changed()
      }, for: .valueChanged)
      return control
    }
    bodyStack.row("dates", version: "\(draft.usesRange)-\(language)") { [self] in
      let start = dateRow(end: false)
      return QFTabUI.card(QFTabUI.stack(draft.usesRange ? [start, dateRow(end: true)] : [start], spacing: 12))
    }
    bodyStack.row("repeat", version: "\(draft.usesRange)-\(draft.repeats)-\(draft.weekdays)-\(language)") { [self] in
      let control = UISwitch()
      control.isOn = draft.usesRange && draft.repeats
      control.isEnabled = draft.usesRange
      control.onTintColor = QFUI.success
      control.accessibilityLabel = app.text("每周重复", "Repeat weekly")
      control.accessibilityIdentifier = "plan.create.repeat"
      control.addAction(UIAction { [weak self, weak control] _ in
        guard let self, self.draft.pending == nil else { return }
        self.draft.repeats = control?.isOn == true
        if self.draft.repeats && self.draft.weekdays.isEmpty,
          let date = QFManualPlanDraft.date(self.draft.startDate) {
          self.draft.weekdays = [(QFManualPlanDraft.calendar.component(.weekday, from: date) + 5) % 7 + 1]
        }
        self.changed()
      }, for: .valueChanged)
      let row = QFTabUI.stack([QFContentUI.label(app.text("每周重复", "Repeat weekly")), UIView(), control], axis: .horizontal, spacing: 8)
      row.alignment = .center
      let contents = QFTabUI.stack([row], spacing: 12)
      if draft.usesRange && draft.repeats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        formatter.calendar = QFManualPlanDraft.calendar
        let symbols = formatter.shortStandaloneWeekdaySymbols!
        let days = QFTabUI.stack([], axis: .horizontal, spacing: 2)
        days.distribution = .fillEqually
        for day in 1...7 {
          let selected = draft.weekdays.contains(day)
          let button = QFTabUI.button(symbols[day % 7], size: 12,
            color: selected ? QFUI.onPrimary : QFUI.text,
            background: selected ? QFUI.primary : QFUI.paleGreen) { [weak self] in
              guard let self, self.draft.pending == nil else { return }
              if self.draft.weekdays.contains(day) { self.draft.weekdays.removeAll { $0 == day } }
              else { self.draft.weekdays.append(day) }
              self.changed()
            }
          button.layer.cornerRadius = 10
          button.titleLabel?.adjustsFontSizeToFitWidth = true
          button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
          button.accessibilityTraits = selected ? [.button, .selected] : [.button]
          button.accessibilityIdentifier = "plan.create.weekday.\(day)"
          days.addArrangedSubview(button)
        }
        contents.addArrangedSubview(days)
      }
      return QFTabUI.card(contents)
    }
    if (try? draft.selectedDates()) == nil {
      bodyStack.row("invalid-dates", version: language) { [self] in
        QFContentUI.label(app.text("请选择有效日期、重复日和菜谱，日期范围最多 42 天。", "Choose valid dates, weekdays and recipes. The range can cover up to 42 days."), size: 13, color: QFUI.danger)
      }
    }
    if draft.pending != nil {
      bodyStack.row("pending", version: language) { [self] in
        QFContentUI.label(app.text("提交结果尚未确认，请重试。", "Submission is unconfirmed. Please retry."), size: 14, color: QFUI.primary)
      }
    }
    for meal in QFManualPlanDraft.meals {
      bodyStack.row("heading-\(meal)", version: "\(draft.recipes[meal]?.count ?? 0)-\(language)") { [self] in
        let title = QFContentUI.label("\(mealName(meal))  ·  \(draft.recipes[meal]?.count ?? 0)", size: 18, bold: true)
        let add = QFTabUI.iconButton("plus", label: app.text("添加菜谱", "Add recipe")) { [weak self] in self?.chooseRecipes(meal) }
        add.tintColor = QFUI.success
        add.backgroundColor = QFUI.paleGreen
        add.layer.cornerRadius = 15
        add.accessibilityIdentifier = "plan.create.add.\(meal)"
        let row = QFTabUI.stack([title, UIView(), add], axis: .horizontal, spacing: 8)
        row.alignment = .center
        return row
      }
      bodyStack.row("meal-\(meal)", version: "\(draft.recipes[meal] ?? [])-\(language)") { [self] in
        let items = draft.recipes[meal] ?? []
        let contents = QFTabUI.stack([], spacing: 10)
        if items.isEmpty {
          let add = QFContentUI.action(app.text("添加菜谱", "Add recipe")) { [weak self] in self?.chooseRecipes(meal) }
          let empty = QFContentUI.label(app.text("也可以先留空", "You can leave this empty"), size: 12, color: QFUI.secondary)
          empty.textAlignment = .center
          contents.addArrangedSubview(add)
          contents.addArrangedSubview(empty)
        } else {
          for (index, item) in items.enumerated() {
            if index > 0 {
              let separator = UIView(); separator.backgroundColor = QFUI.border
              separator.snp.makeConstraints { $0.height.equalTo(1 / UIScreen.main.scale) }
              contents.addArrangedSubview(separator)
            }
            contents.addArrangedSubview(recipeRow(item, meal: meal))
          }
        }
        return QFTabUI.card(contents)
      }
    }
    bodyStack.endUpdates()
    bodyStack.isUserInteractionEnabled = draft.pending == nil && !saving
    let dates = (try? draft.selectedDates())?.count ?? 0
    countLabel.text = app.format("已安排 %d 道菜 · %d 天", "%d recipes · %d days", draft.recipeCount, dates)
    saveButton.setTitle(draft.pending == nil ? app.text("保存计划", "Save plan") : app.text("重试", "Retry"), for: .normal)
    saveButton.isEnabled = !saving && (draft.pending != nil || (draft.recipeCount > 0 && dates > 0))
    saveButton.alpha = saveButton.isEnabled ? 1 : 0.5
  }
  private func dateRow(end: Bool) -> UIView {
    let label = QFContentUI.label(end ? app.text("结束日期", "End date") : app.text("日期", "Date"))
    let picker = UIDatePicker()
    picker.datePickerMode = .date
    picker.preferredDatePickerStyle = .compact
    picker.minimumDate = QFManualPlanDraft.date("1000-01-01")
    picker.maximumDate = QFManualPlanDraft.date("9999-12-31")
    picker.calendar = QFManualPlanDraft.calendar
    picker.timeZone = QFManualPlanDraft.calendar.timeZone
    picker.locale = Locale(identifier: app.interfaceLanguage)
    picker.date = QFManualPlanDraft.date(end ? draft.endDate : draft.startDate) ?? Date()
    picker.accessibilityIdentifier = end ? "plan.create.endDate" : "plan.create.startDate"
    picker.addAction(UIAction { [weak self, weak picker] _ in
      guard let self, let picker, self.draft.pending == nil else { return }
      if end { self.draft.endDate = QFManualPlanDraft.string(picker.date) }
      else { self.draft.startDate = QFManualPlanDraft.string(picker.date) }
      self.changed()
    }, for: .valueChanged)
    let row = QFTabUI.stack([label, UIView(), picker], axis: .horizontal, spacing: 8)
    row.alignment = .center
    return row
  }
  private func recipeRow(_ item: QFManualPlanDraft.Recipe, meal: String) -> UIView {
    let picture = QFContentImageView()
    picture.load(item.mediaId, app: app)
    picture.layer.cornerRadius = 12; picture.clipsToBounds = true
    picture.backgroundColor = QFUI.paleGreen
    picture.isUserInteractionEnabled = false
    picture.snp.makeConstraints { $0.size.equalTo(QFCreatePlanLayout.recipeImageSize) }
    let title = item.language == app.interfaceLanguage ? item.title : app.text("当前语言内容不可用", "Content unavailable in this language")
    let details = QFTabUI.stack([
      QFContentUI.label(title, size: 15, bold: true),
      QFContentUI.label([item.minutes.map { app.format("%d 分钟", "%d min", $0) } ?? "",
        app.format("%d 人份", "Serves %d", item.servings)].filter { !$0.isEmpty }.joined(separator: " · "),
        size: 12, color: QFUI.secondary)
    ], spacing: 5)
    let more = QFTabUI.iconButton("ellipsis", label: app.text("调整当餐计划", "Edit meal plan")) { [weak self] in
      self?.editRecipe(item, meal: meal)
    }
    more.accessibilityIdentifier = "plan.create.edit.\(meal).\(item.id)"
    let row = QFTabUI.stack([picture, details, more], axis: .horizontal, spacing: 10)
    row.alignment = .center
    return row
  }
  private func editRecipe(_ item: QFManualPlanDraft.Recipe, meal: String) {
    guard draft.pending == nil else { return }
    let alert = UIAlertController(title: app.text("用餐份数", "Servings"), message: nil, preferredStyle: .alert)
    alert.addTextField { field in
      field.text = String(item.servings); field.keyboardType = .numberPad
      field.accessibilityLabel = self.app.text("用餐份数", "Servings")
    }
    alert.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: app.text("移除", "Remove"), style: .destructive) { [weak self] _ in
      self?.draft.recipes[meal]?.removeAll { $0.id == item.id }; self?.changed()
    })
    alert.addAction(UIAlertAction(title: app.text("保存", "Save"), style: .default) { [weak self, weak alert] _ in
      guard let self else { return }
      guard let value = Int(alert?.textFields?.first?.text ?? ""), (1...100).contains(value) else {
        self.message(self.app.text("份数需为 1–100。", "Servings must be 1–100.")); return
      }
      if let index = self.draft.recipes[meal]?.firstIndex(where: { $0.id == item.id }) {
        self.draft.recipes[meal]?[index].servings = value; self.changed()
      }
    })
    open(alert)
  }
  private func chooseRecipes(_ meal: String) {
    guard draft.pending == nil else { return }
    let existing = draft.recipes[meal] ?? []
    let context = draft.usesRange ? "\(draft.startDate) – \(draft.endDate)" : draft.startDate
    open(QFPlanRecipePickerViewController(app: app, meal: meal, context: context,
      date: draft.usesRange ? nil : draft.startDate, householdID: householdID,
      existing: Set(existing.map(\.id)), capacity: 30 - existing.count) { [weak self] values in
        guard let self, self.draft.pending == nil else { return }
        let ids = Set((self.draft.recipes[meal] ?? []).map(\.id))
        self.draft.recipes[meal, default: []].append(contentsOf: values.filter { !ids.contains($0.id) })
        self.changed()
      })
  }
  private func submit() {
    guard !saving else { return }
    do {
      if draft.pending == nil {
        draft.pending = .init(body: try draft.request(householdID: householdID), language: app.interfaceLanguage)
      }
      guard persist(), let pending = draft.pending else { draft.pending = nil; return }
      saving = true; render()
      execute { [self] in
        defer {
          saving = false
          DispatchQueue.main.async { [weak self] in self?.render() }
        }
        do {
          let result = try await app.appendPlanBatch(pending)
          guard result.requestId == pending.body.requestId else { throw URLError(.badServerResponse) }
          QFContentDraftStore.remove(app: app, kind: draftKind)
          draft = QFManualPlanDraft(date: draft.startDate)
          saved()
          closeWithSuccess(app.format("已添加 %d 项，已存在 %d 项", "Added %d items; %d already existed", result.addedCount, result.skippedCount))
        } catch {
          // These explicit errors cannot have committed the transaction. Transport/5xx errors
          // retain the immutable receipt key; editing them would risk an unknown first result.
          if let api = error as? QFAPIError, QFManualPlanDraft.isDefinitiveRejection(api.code) {
            draft.pending = nil; _ = persist()
          }
          throw error
        }
      }
    } catch {
      message(app.text("请选择有效日期、重复日和菜谱，日期范围最多 42 天。", "Choose valid dates, weekdays and recipes. The range can cover up to 42 days."), error: true)
    }
  }
  override func close() {
    guard !saving else { return }
    guard hasUnsavedChanges else { super.close(); return }
    let alert = UIAlertController(title: app.text("保留未提交的内容？", "Keep unsubmitted changes?"), message: nil, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: app.text("继续编辑", "Keep editing"), style: .cancel))
    alert.addAction(UIAlertAction(title: app.text("保留草稿", "Keep draft"), style: .default) { [weak self] _ in
      guard let self, self.persist() else { return }; self.qfClose()
    })
    // An uncertain request remains recoverable; do not offer to erase its retry receipt.
    if draft.pending == nil {
      alert.addAction(UIAlertAction(title: app.text("放弃修改", "Discard changes"), style: .destructive) { [weak self] _ in
        guard let self else { return }
        QFContentDraftStore.remove(app: self.app, kind: self.draftKind); self.qfClose()
      })
    }
    open(alert)
  }
  private func mealName(_ value: String) -> String { QFPlanRecipePickerViewController.mealName(value, app: app) }
}
