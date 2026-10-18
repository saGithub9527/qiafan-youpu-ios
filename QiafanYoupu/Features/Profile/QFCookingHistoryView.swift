import SnapKit
import UIKit

@MainActor
final class QFCookingHistoryViewController: QFProfileContentController {
  private var month = Date()
  private var selectedDate = QFContentDate.day(Date())
  private var records: [QFCookingRecord] = []
  private var cookingDays = 0
  private var listMode = false
  private var visibleLimit = 20
  private var backfillButton: UIButton!
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.firstWeekday = 2
    return value
  }
  init(app: QFAppSession) { super.init(app: app, title: app.text("做菜记录", "Cooking history")) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    backfillButton = addFooter(app.text("补记做菜", "Add cooking record")) { [weak self] in self?.beginBackfill() }
    load()
  }
  private func load() {
    setReloadAction { [weak self] in self?.load() }
    execute(reloadOnFailure: true) { [self] in
      let result: QFContentPage<QFCookingRecord> = try await app.contentRequest(
        path: "me/cooking-records", query: ["month": QFContentDate.month(month)])
      let summary: QFContentSummary = try await app.contentRequest(path: "me/content-summary")
      if isRefreshingContent { visibleLimit = 20 }
      records = result.items
      cookingDays = summary.cookingDays
      render()
    }
  }
  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row("total", version: String(cookingDays)) { [self] in
      QFTabUI.card(
        QFTabUI.stack(
          [
            QFContentUI.label(app.text("累计做菜", "Total cooking days"), size: 13),
            QFContentUI.label(app.format("%d 天", "%d days", cookingDays), size: 30, bold: true),
          ], spacing: 6), background: QFUI.paleGreen)
    }
    bodyStack.row("month", version: QFContentDate.month(month) + String(listMode)) { [self] in
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
      formatter.setLocalizedDateFormatFromTemplate("yMMMM")
      let title = QFContentUI.label(formatter.string(from: month), size: 18, bold: true)
      title.textAlignment = .center
      let previous = QFTabUI.iconButton(
        "chevron.left", label: app.text("上一个月", "Previous month"), size: 22, weight: .semibold
      ) { [weak self] in self?.changeMonth(-1) }
      let next = QFTabUI.iconButton(
        "chevron.right", label: app.text("下一个月", "Next month"), size: 22, weight: .semibold
      ) { [weak self] in self?.changeMonth(1) }
      previous.tintColor = QFUI.primary
      next.tintColor = QFUI.primary
      let monthRow = QFTabUI.stack([previous, title, next], axis: .horizontal, spacing: 10)
      let mode = QFContentUI.segments([app.text("月历", "Calendar"), app.text("列表", "List")], selected: listMode ? 1 : 0) { [weak self] index in
        self?.listMode = index == 1; self?.visibleLimit = 20; self?.render()
      }
      return QFTabUI.stack([monthRow, mode], spacing: 10)
    }
    if !listMode { renderCalendar() }
    let visible =
      listMode ? records.sorted { $0.date > $1.date } : records.filter { $0.date == selectedDate }
    bodyStack.row("date", version: selectedDate + String(listMode)) { [self] in
      let label = QFContentUI.label(listMode ? app.text("本月记录", "This month") : selectedDate, size: 18, bold: true)
      label.textAlignment = .center
      return label
    }
    var knownCosts: [String: Decimal] = [:]
    for item in visible {
      if let cost = item.cost, let amount = Decimal(string: cost) {
        knownCosts[item.currency, default: 0] += amount
      }
    }
    var summaryParts = [app.format("完成 %d 道", "%d completed", visible.count)]
    for currency in knownCosts.keys.sorted() {
      summaryParts.append("\(currency) \(knownCosts[currency] ?? 0)")
    }
    let unknownCount = visible.filter { $0.cost == nil }.count
    if unknownCount > 0 {
      summaryParts.append(app.format("%d 道成本待补全", "%d costs missing", unknownCount))
    }
    bodyStack.row("summary", version: summaryParts.joined()) {
      QFContentUI.label(summaryParts.joined(separator: " · "), size: 14, color: QFUI.secondary)
    }
    if visible.isEmpty {
      bodyStack.row("empty", version: String(listMode)) { [self] in
        QFTabUI.empty(listMode ? app.text("本月还没有做菜记录", "No cooking history this month") : app.text("这天还没有做菜记录", "No cooking history for this day"), detail: app.text("记录今天做过的菜。", "Record what you cooked today."))
      }
    }
    for item in visible.prefix(visibleLimit) {
      bodyStack.row(item.id, value: item) { [self] in
        let title = QFContentUI.action(item.title + " ›") { [weak self] in self?.edit(item) }
        let cost = item.cost.map { "\(item.currency) \($0)" } ?? app.text("成本待补全", "Cost missing")
        let date = QFContentUI.label("\(item.date) · \(item.mealTitle(app: app)) · \(cost)", size: 13, color: QFUI.secondary)
        date.textAlignment = .center
        return QFTabUI.card(
          QFTabUI.stack(
            [
              title,
              date,
            ], spacing: 6))
      }
    }
    if !listMode {
      bodyStack.row("actions") { [self] in
        let actions = QFTabUI.stack(
          [
            QFContentUI.action(app.text("菜品使用", "Dishes cooked")) { [weak self] in self?.statistics(.dishes) },
            QFContentUI.action(app.text("食材消耗", "Ingredients used")) { [weak self] in self?.statistics(.materials) },
            QFContentUI.action(app.text("备菜花销", "Shopping spend")) { [weak self] in self?.statistics(.costs) },
          ], axis: .horizontal, spacing: 8)
        actions.distribution = .fillEqually
        return actions
      }
    }
    bodyStack.endUpdates()
    backfillButton.setTitle(listMode ? app.text("选择日期补记", "Choose a date") : app.text("补记做菜", "Add cooking record"), for: .normal)
    setLoadMoreAction(
      visible.count > visibleLimit
        ? { [weak self] in
          guard let self else { return }
          self.visibleLimit += 20
          self.render()
        } : nil)
  }
  private func renderCalendar() {
    guard let interval = calendar.dateInterval(of: .month, for: month),
      let range = calendar.range(of: .day, in: .month, for: month)
    else { return }
    let first = (calendar.component(.weekday, from: interval.start) + 5) % 7
    let days = Set(records.map(\.date))
    bodyStack.row(
      "calendar", version: QFContentDate.month(month) + selectedDate + days.sorted().joined()
    ) { [self] in
      let grid = QFTabUI.stack([], spacing: 5)
      let formatter = DateFormatter()
      formatter.locale = Locale(
        identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
      let sundayFirst = formatter.shortStandaloneWeekdaySymbols ?? formatter.shortWeekdaySymbols ?? []
      let weekdayNames = sundayFirst.count == 7
        ? Array(sundayFirst[1...]) + [sundayFirst[0]]
        : ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
      let headers = QFTabUI.stack(
        weekdayNames.map { title in
          let label = QFContentUI.label(title, size: 12, color: QFUI.secondary)
          label.textAlignment = .center
          return label
        }, axis: .horizontal)
      headers.distribution = .fillEqually
      grid.addArrangedSubview(headers)
      for week in 0..<((first + range.count + 6) / 7) {
        let row = QFTabUI.stack([], axis: .horizontal, spacing: 2)
        row.distribution = .fillEqually
        for column in 0..<7 {
          let day = week * 7 + column - first + 1
          if day < 1 || day > range.count {
            row.addArrangedSubview(UIView())
            continue
          }
          let value = QFContentDate.month(month) + String(format: "-%02d", day)
          let button = QFTabUI.button(
            "\(day)" + (days.contains(value) ? "\n•" : ""), size: 14,
            color: selectedDate == value ? QFUI.onPrimary : QFUI.text,
            background: selectedDate == value ? QFUI.primary : .clear
          ) { [weak self] in
            self?.selectedDate = value
            self?.visibleLimit = 20
            self?.render()
          }
          button.titleLabel?.numberOfLines = 2
          button.titleLabel?.textAlignment = .center
          button.layer.cornerRadius = 12
          button.accessibilityLabel = value + (days.contains(value) ? app.text("，有做菜记录", ", has cooking history") : app.text("，没有记录", ", no history"))
          button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
          row.addArrangedSubview(button)
        }
        grid.addArrangedSubview(row)
      }
      return QFTabUI.card(grid)
    }
  }
  private func changeMonth(_ offset: Int) {
    visibleLimit = 20
    guard let next = calendar.date(byAdding: .month, value: offset, to: month) else { return }
    month = next
    selectedDate = QFContentDate.month(month) + "-01"
    load()
  }
  private func beginBackfill() {
    guard !listMode else {
      listMode = false
      visibleLimit = 20
      render()
      message(app.text("请在月历中选择要补记的日期。", "Choose a date in the calendar."))
      return
    }
    edit(nil)
  }
  private func edit(_ record: QFCookingRecord?) {
    guard record != nil || selectedDate <= QFContentDate.day(Date()) else {
      message(app.text("未来日期还不能补记做菜，请先选择今天或过去的日期。", "Cooking history cannot be added for a future date. Choose today or an earlier date."), error: true)
      return
    }
    let controller: QFProfileContentController
    if let record {
      controller = record.inventoryMode == "ACTUAL_MATERIALS"
        ? QFCookingRecordDetailViewController(app: app, record: record)
        : QFCookingRecordEditorViewController(app: app, record: record, existing: true)
    } else {
      controller = QFBackfillCookingViewController(app: app, date: selectedDate)
    }
    controller.onChanged = { [weak self] in
      self?.reloadIfVisible()
      self?.onChanged?()
    }
    open(controller)
  }
  private func statistics(_ kind: QFCookingStatisticsViewController.Kind) {
    if kind == .dishes { open(QFCookingUsageViewController(app: app, date: QFManualPlanDraft.date(selectedDate) ?? Date())); return }
    if kind == .costs {
      open(QFPurchasesViewController(app: app, date: selectedDate))
      return
    }
    open(
      QFCookingStatisticsViewController(
        app: app, date: selectedDate, records: records.filter { $0.date == selectedDate },
        kind: kind))
  }
}

@MainActor
final class QFCookingRecordEditorViewController: QFProfileContentController {
  private var draft: QFCookingRecord
  private var original: QFCookingRecord
  private let materialsStack = QFTabUI.stack([], spacing: 12)
  private var existing: Bool
  private var locksMaterials: Bool { ["ACTUAL_MATERIALS", "LEGACY_RECIPE"].contains(draft.inventoryMode ?? "") }
  private let fixedDate: String?
  private let onPrepared: ((QFCookingRecord) -> Void)?
  override var hasUnsavedChanges: Bool { draft != original }
  init(app: QFAppSession, record: QFCookingRecord, existing: Bool, fixedDate: String? = nil,
    onPrepared: ((QFCookingRecord) -> Void)? = nil) {
    self.onPrepared = onPrepared
    self.fixedDate = fixedDate
    var restored = onPrepared == nil ? QFContentDraftStore.load(QFCookingRecord.self, app: app, kind: "cooking-" + record.id) ?? record : record
    var baseline = record
    if existing {
      restored.inventoryMode = record.inventoryMode
      restored.plannedMealId = record.plannedMealId
      restored.expectedPlanRevision = nil
      if ["ACTUAL_MATERIALS", "LEGACY_RECIPE"].contains(record.inventoryMode ?? "") { restored.materials = record.materials }
    }
    if let fixedDate { restored.date = fixedDate; baseline.date = fixedDate }
    self.draft = restored
    original = baseline
    self.existing = existing
    super.init(app: app, title: existing ? app.text("做菜记录详情", "Cooking record details") : app.text("补记菜品", "Add dish"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    let save = addFooter(onPrepared == nil ? app.text("保存记录", "Save record") : app.text("保存菜品", "Save dish")) { [weak self] in self?.save() }
    save.accessibilityIdentifier = "cooking.record.save"
    render()
  }
  private func render() {
    QFTabUI.clear(bodyStack)
    if let fixedDate {
      let date = QFContentUI.label(fixedDate, size: 18, bold: true)
      date.textAlignment = .center
      bodyStack.addArrangedSubview(date)
    } else {
      let date = UIDatePicker()
      date.datePickerMode = .date
      date.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
      date.preferredDatePickerStyle = .compact
      let parser = DateFormatter()
      parser.calendar = Calendar(identifier: .gregorian)
      parser.locale = Locale(identifier: "en_US_POSIX")
      parser.dateFormat = "yyyy-MM-dd"
      date.date = parser.date(from: draft.date) ?? Date()
      date.maximumDate = Date()
      date.addAction(
        UIAction { [weak self, weak date] _ in
          guard let date else { return }
          self?.draft.date = QFContentDate.day(date.date)
        }, for: .valueChanged)
      bodyStack.addArrangedSubview(date)
    }
    bodyStack.addArrangedSubview(
      QFContentUI.field(app.text("实际做的菜品名称", "Dish you cooked"), text: draft.title) { [weak self] in self?.draft.title = $0 })
    let meals = QFCookingMeal.allCases
    bodyStack.addArrangedSubview(
      QFContentUI.segments(
        meals.map { $0.title(app: app) }, selected: meals.firstIndex(where: { $0.rawValue == draft.meal }) ?? UISegmentedControl.noSegment
      ) { [weak self] in
        guard meals.indices.contains($0) else { return }
        self?.draft.meal = meals[$0].rawValue
      })
    bodyStack.addArrangedSubview(
      QFContentUI.field(app.text("币种，例如 CNY / USD", "Currency, for example CNY / USD"), text: draft.currency) { [weak self] in
        self?.draft.currency = $0.uppercased()
      })
    bodyStack.addArrangedSubview(
      QFContentUI.field(app.text("这道菜的成本，未知时留空", "Cost of this dish; leave blank if unknown"), text: draft.cost ?? "", keyboard: .decimalPad) {
        [weak self] in self?.draft.cost = $0.isEmpty ? nil : $0
      })
    bodyStack.addArrangedSubview(QFContentUI.label(app.text("实际用料", "Materials used"), size: 19, bold: true))
    bodyStack.addArrangedSubview(materialsStack)
    renderMaterials()
    if !locksMaterials { bodyStack.addArrangedSubview(
      QFContentUI.anchoredAction(app.text("＋ 添加用料", "+ Add material")) { [weak self] sourceView in
        guard let self else { return }
        guard self.draft.materials.count < 40 else {
          self.message(self.app.text("每道菜最多添加40种用料。", "Each dish can include up to 40 materials."), error: true)
          return
        }
        self.chooseMaterial(from: sourceView) { [weak self] material in
          self?.draft.materials.append(material); self?.renderMaterials()
        }
      }) }
    bodyStack.addArrangedSubview(
      QFContentTextArea(app.text("备注", "Notes"), text: draft.note, limit: 2000) { [weak self] in self?.draft.note = $0
      })
    if existing, draft.plannedMealId != nil, draft.inventoryMode != "ACTUAL_MATERIALS" {
      bodyStack.addArrangedSubview(
        QFContentUI.action(app.text("查看库存扣减状态", "View inventory deduction status")) {
          [weak self] in self?.openDeductionJob()
        })
    }
    if existing {
      bodyStack.addArrangedSubview(
        QFContentUI.action(app.text("撤销这条记录", "Delete this record"), destructive: true) { [weak self] in
          guard let self else { return }
          self.confirm(self.app.text("撤销这条做菜记录？", "Delete this cooking record?"), detail: self.app.text("撤销后不再计入做菜统计。", "It will no longer count toward cooking statistics."), actionTitle: self.app.text("撤销记录", "Delete record"), destructive: true)
          { [weak self] in
            self?.execute { [weak self] in
              guard let self else { return }
              try await self.app.contentMutation(
                path: "me/cooking-records/\(self.draft.id)", method: "DELETE")
              QFContentDraftStore.remove(app: self.app, kind: "cooking-" + self.draft.id)
              self.onChanged?()
              self.qfClose()
            }
          }
        })
    }
  }
  private func renderMaterials() {
    QFTabUI.clear(materialsStack)
    for index in draft.materials.indices {
      let item = draft.materials[index]
      if locksMaterials {
        materialsStack.addArrangedSubview(QFTabUI.card(QFTabUI.stack([
          QFContentUI.label(item.name, size: 16, bold: true),
          QFContentUI.label("\(item.amount) \(item.unit)", size: 14, color: QFUI.secondary)
        ], spacing: 8)))
        continue
      }
      let name = QFContentUI.field(app.text("食材名称", "Ingredient name"), text: item.name) { [weak self] in
        self?.draft.materials[index].name = $0
        self?.draft.materials[index].ingredientId = nil
      }
      let amount = QFContentUI.field(app.text("实际用量", "Amount used"), text: item.amount, keyboard: .decimalPad) {
        [weak self] in self?.draft.materials[index].amount = $0
      }
      let unit = QFContentUI.field(app.text("单位", "Unit"), text: item.unit, limit: 20) { [weak self] in
        self?.draft.materials[index].unit = $0
      }
      let quantity = QFTabUI.stack([amount, unit], axis: .horizontal, spacing: 8)
      quantity.distribution = .fillEqually
      let remove = QFContentUI.action(app.text("移除", "Remove"), destructive: true) { [weak self] in
        self?.draft.materials.remove(at: index)
        self?.renderMaterials()
      }
      remove.accessibilityLabel = item.name.isEmpty
        ? app.text("移除未命名食材", "Remove unnamed ingredient")
        : app.format("移除%@", "Remove %@", item.name)
      materialsStack.addArrangedSubview(
        QFTabUI.card(QFTabUI.stack([name, quantity, remove], spacing: 8)))
    }
  }
  private func save() {
    if let fixedDate { draft.date = fixedDate }
    if let error = draft.validation(app: app) {
      message(error, error: true)
      return
    }
    if let onPrepared { onPrepared(draft); qfClose(); return }
    guard QFContentDraftStore.save(draft, app: app, kind: "cooking-" + draft.id) else {
      message(app.text("本机草稿暂时无法保存，请精简内容后重试。", "The local draft could not be saved. Shorten it and try again."), error: true)
      return
    }
    execute { [self] in
      let saved: QFCookingRecord = try await app.contentRequest(
        path: "me/cooking-records/\(draft.id)", method: "PUT",
        body: JSONEncoder().encode(draft.requestBody))
      QFContentDraftStore.remove(app: app, kind: "cooking-" + draft.id)
      draft = saved
      original = saved
      existing = true
      onChanged?()
      if saved.inventoryMode != "ACTUAL_MATERIALS", let plannedMealID = saved.plannedMealId {
        do {
          _ = try await app.consumeInventory(
            plannedMealID: plannedMealID,
            draft: QFInventoryConsumePlanDraft(
              cookingRecordId: saved.id, idempotencyKey: saved.id))
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          render()
          message(
            app.text(
              "记录已保存，但库存扣减任务尚未创建。请点“查看库存扣减状态”重试。",
              "The record was saved, but inventory deduction has not started. Tap View inventory deduction status to retry."),
            error: true)
          return
        }
      }
      qfClose()
    }
  }

  private func openDeductionJob() {
    guard let plannedMealID = draft.plannedMealId else { return }
    execute(label: app.text("正在读取扣减状态", "Loading deduction status")) { [self] in
      let job = try await app.consumeInventory(
        plannedMealID: plannedMealID,
        draft: QFInventoryConsumePlanDraft(
          cookingRecordId: draft.id, idempotencyKey: draft.id))
      try Task.checkCancellation()
      open(QFInventoryDeductionJobViewController(app: app, job: job))
    }
  }
  override func close() {
    if draft == original {
      super.close()
      return
    }
    let alert = UIAlertController(
      title: app.text("保留未提交的内容？", "Keep unsubmitted changes?"), message: app.text("返回不会自动发布或提交。", "Going back will not publish or submit anything automatically."), preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: app.text("继续编辑", "Keep editing"), style: .cancel))
    alert.addAction(UIAlertAction(title: app.text("保留草稿", "Keep draft"), style: .default) { [weak self] _ in
      guard let self else { return }
      if let onPrepared {
        onPrepared(draft)
        finishClose()
      } else if QFContentDraftStore.save(draft, app: app, kind: "cooking-" + draft.id) {
        finishClose()
      } else {
        message(app.text("本机草稿暂时无法保存，请精简内容后重试。", "The local draft could not be saved. Shorten it and try again."), error: true)
      }
    })
    alert.addAction(UIAlertAction(title: app.text("放弃修改", "Discard changes"), style: .destructive) { [weak self] _ in
      guard let self else { return }
      if onPrepared == nil {
        QFContentDraftStore.remove(app: app, kind: "cooking-" + draft.id)
      }
      finishClose()
    })
    open(alert)
  }
  private func finishClose() { super.close() }
}

@MainActor
private final class QFInventoryDeductionJobViewController: QFProfileContentController {
  private var job: QFInventoryDeductionJob
  private var retryButton: UIButton!
  private var cancelButton: UIButton!

  init(app: QFAppSession, job: QFInventoryDeductionJob) {
    self.job = job
    super.init(app: app, title: app.text("库存扣减状态", "Inventory deduction status"))
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    setReloadAction { [weak self] in self?.load() }
    cancelButton = addFooter(app.text("取消扣减", "Cancel deduction"), primary: false) {
      [weak self] in self?.confirmCancel()
    }
    retryButton = addFooter(app.text("重试扣减", "Retry deduction")) {
      [weak self] in self?.retry()
    }
    render()
  }

  private func load() {
    execute(reloadOnFailure: true) { [self] in
      job = try await app.inventoryDeductionJob(job.id)
      try Task.checkCancellation()
      render()
    }
  }

  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row(
      "summary", version: "\(job.status)|\(job.attempts)|\(job.updatedAt)|\(app.interfaceLanguage)"
    ) { [weak self] in
      guard let self else { return UIView() }
      let color = self.job.status == "COMPLETED"
        ? QFUI.green : self.job.status == "NEEDS_ATTENTION" ? QFUI.danger : QFUI.orange
      var rows: [UIView] = [
        QFTabUI.label(self.statusTitle(self.job.status), size: 20, weight: .semibold, color: color),
        QFTabUI.label(
          self.app.format("已尝试 %d 次", "%d attempts", self.job.attempts),
          size: 13, color: QFUI.secondary),
      ]
      if let error = self.job.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
        !error.isEmpty
      {
        rows.append(QFTabUI.label(error, size: 12, color: QFUI.danger, lines: 0))
      }
      return QFTabUI.card(QFTabUI.stack(rows, spacing: 7), padding: 14, border: true)
    }
    bodyStack.endUpdates()
    retryButton.isHidden = job.status != "NEEDS_ATTENTION"
    cancelButton.isHidden = !["PENDING", "RETRY", "NEEDS_ATTENTION"].contains(job.status)
  }

  private func retry() {
    execute(label: app.text("正在重试扣减", "Retrying deduction")) { [self] in
      job = try await app.retryInventoryDeductionJob(job.id)
      try Task.checkCancellation()
      render()
    }
  }

  private func confirmCancel() {
    confirm(
      app.text("取消库存扣减？", "Cancel inventory deduction?"),
      detail: app.text(
        "做菜记录会保留，但这次不会自动扣减库存。",
        "The cooking record remains, but inventory will not be deducted automatically."),
      actionTitle: app.text("取消扣减", "Cancel deduction"), destructive: true
    ) { [weak self] in self?.cancel() }
  }

  private func cancel() {
    execute(label: app.text("正在取消扣减", "Cancelling deduction")) { [self] in
      try await app.cancelInventoryDeductionJob(job.id)
      job = try await app.inventoryDeductionJob(job.id)
      try Task.checkCancellation()
      render()
    }
  }

  private func statusTitle(_ status: String) -> String {
    switch status {
    case "PENDING": return app.text("等待扣减", "Pending")
    case "PROCESSING": return app.text("正在扣减", "Processing")
    case "RETRY": return app.text("等待自动重试", "Waiting to retry")
    case "COMPLETED": return app.text("库存已扣减", "Inventory deducted")
    case "NEEDS_ATTENTION": return app.text("需要处理", "Needs attention")
    case "CANCELLED": return app.text("扣减已取消", "Deduction cancelled")
    default: return status
    }
  }
}

@MainActor
final class QFCookingStatisticsViewController: QFProfileContentController {
  enum Kind { case dishes, materials, costs }
  private let date: String
  private var records: [QFCookingRecord]
  private let kind: Kind
  private let monthScope: Bool
  private var visibleLimit = 20
  private let results = QFContentListTable(frame: .zero, style: .plain)
  init(app: QFAppSession, date: String, records: [QFCookingRecord], kind: Kind, monthScope: Bool = false) {
    self.date = date
    self.records = records
    self.kind = kind
    self.monthScope = monthScope
    super.init(app: app, title: kind == .dishes ? app.text("菜品使用", "Dishes cooked") : kind == .materials ? app.text("食材消耗", "Ingredients used") : app.text("备菜花销", "Shopping spend"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    installList(results, controls: QFContentUI.label(monthScope ? String(date.prefix(7)) : date, size: 18, bold: true))
    setReloadAction { [weak self] in self?.load() }
    render()
    if monthScope { load() }
  }
  private func load() {
    let reset = isRefreshingContent
    execute(reloadOnFailure: true) { [self] in
      let month: QFContentPage<QFCookingRecord> = try await app.contentRequest(
        path: "me/cooking-records", query: ["month": String(date.prefix(7))])
      records = monthScope ? month.items : month.items.filter { $0.date == date }
      if reset { visibleLimit = 20 }
      render()
    }
  }
  private func render() {
    var values: [String: Decimal] = [:]
    if kind == .dishes {
      for record in records { values[record.title, default: 0] += 1 }
    } else if kind == .materials {
      for item in records.flatMap(\.materials) {
        values[item.name + " · " + item.unit, default: 0] += Decimal(string: item.amount) ?? 0
      }
    } else {
      for item in records {
        if let cost = item.cost, let value = Decimal(string: cost) {
          values[item.currency, default: 0] += value
        }
      }
    }
    let keys = values.keys.sorted()
    let suffix = kind == .dishes ? app.text(" 次", " times") : ""
    let size: CGFloat = kind == .costs ? 24 : 17
    results.beginUpdatesForRows()
    for key in keys.prefix(visibleLimit) {
      let amount = values[key] ?? 0
      results.row(key, version: String(describing: amount)) {
        QFTabUI.card(QFContentUI.label("\(key)   \(amount)\(suffix)", size: size))
      }
    }
    if keys.isEmpty {
      results.row("empty") { [app] in QFTabUI.empty(app.text("暂无记录", "No records"), detail: app.text("先补记当天实际做菜信息。", "Add what you cooked that day first.")) }
    }
    results.endUpdatesForRows()
    setLoadMoreAction(
      keys.count > visibleLimit
        ? { [weak self] in
          guard let self else { return }
          self.visibleLimit += 20
          self.render()
        } : nil)
  }
}
