import Combine
import UIKit

@MainActor
final class QFBatchCookingEditorViewController: QFProfileContentController {
  private let date: String
  private var records: [QFCookingRecord]
  private var deferredRecords: [QFCookingRecord]
  private let draftKey: String
  private var submitButton: UIButton!
  private var reloadDraftOnReturn = false
  override var hasUnsavedChanges: Bool { !records.isEmpty }
  init(app: QFAppSession, date: String) {
    self.date = date; draftKey = "cooking-batch-" + date
    let restored = Self.restoreRecords(app: app, date: date)
    records = restored.current; deferredRecords = restored.deferred
    super.init(app: app, title: app.text("补记做菜", "Add cooking record"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    submitButton = addFooter(app.text("保存当天记录", "Save this day's records")) { [weak self] in self?.submit() }
    render()
    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] _ in
      self?.applyLanguage()
    }.store(in: &cancellables)
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if reloadDraftOnReturn {
      reloadDraftOnReturn = false
      retryDraftRecovery()
    }
  }
  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row("date", version: date + app.interfaceLanguage) { [self] in
      let label = QFContentUI.label(date, size: 19, bold: true); label.textAlignment = .center
      return label
    }
    if !deferredRecords.isEmpty {
      let dates = Set(deferredRecords.map(\.date)).sorted()
      bodyStack.row(
        "draft-recovery",
        version: dates.joined() + String(deferredRecords.count) + app.interfaceLanguage
      ) { [weak self] in
        guard let self else { return UIView() }
        let content = QFTabUI.stack([
          QFContentUI.label(self.app.text("部分旧草稿尚未归档", "Some older drafts still need attention"), size: 16, bold: true),
          QFContentUI.label(self.app.text(
            "目标日期存在冲突内容，或本机暂时无法写入。原内容仍保留，请先保存或整理该日草稿，再重试。",
            "The target date contains conflicting content, or this device could not save it. The original content is still kept. Save or organize that day's draft, then try again."),
            size: 14, color: QFUI.secondary),
        ], spacing: 8)
        for otherDate in dates {
          content.addArrangedSubview(QFContentUI.action(self.app.format(
            "查看 %@ 草稿", "View %@ draft", otherDate)) { [weak self] in
            guard let self else { return }
            let editor = QFBatchCookingEditorViewController(app: self.app, date: otherDate)
            editor.onChanged = { [weak self] in self?.onChanged?() }
            self.reloadDraftOnReturn = true
            self.open(editor)
          })
        }
        content.addArrangedSubview(QFContentUI.action(self.app.text("重试恢复", "Try recovery again")) {
          [weak self] in self?.retryDraftRecovery()
        })
        return QFTabUI.card(content)
      }
    }
    for meal in QFCookingMeal.allCases {
      let dishes = records.filter { $0.meal == meal.rawValue }
      bodyStack.row(
        "meal-" + meal.rawValue,
        version: String(dishes.count) + app.interfaceLanguage
      ) { [weak self] in
        guard let self else { return UIView() }
        let mealTitle = meal.title(app: self.app)
        let title = QFContentUI.label(self.app.format(
          "%@ · %d 道菜", "%@ · %d dishes", mealTitle, dishes.count), size: 18, bold: true)
        title.accessibilityTraits.insert(.header)
        let add = QFContentUI.action(self.app.text("＋ 添加菜品", "+ Add dish")) {
          [weak self] in self?.edit(nil, meal: meal)
        }
        add.accessibilityLabel = self.app.format("为%@添加菜品", "Add a dish to %@", mealTitle)
        return QFTabUI.stack([title, add], axis: .horizontal, spacing: 12)
      }
      for record in dishes { renderDish(record, meal: meal) }
    }
    // Keep an invalid legacy meal visible so its draft can be repaired instead of hidden.
    for record in records where QFCookingMeal(rawValue: record.meal) == nil {
      renderDish(record, meal: .lunch)
    }
    bodyStack.endUpdates()
    submitButton.isEnabled = !records.isEmpty
    submitButton.setTitle(
      records.isEmpty
        ? app.text("保存当天记录", "Save this day's records")
        : app.format("保存当天 %d 道菜", "Save %d dishes for this day", records.count),
      for: .normal)
  }
  private func renderDish(_ record: QFCookingRecord, meal: QFCookingMeal) {
    let encoded = (try? JSONEncoder().encode(record).base64EncodedString()) ?? record.id
    bodyStack.row(record.id, version: encoded + app.interfaceLanguage) { [weak self] in
      guard let self else { return UIView() }
      let name = QFContentUI.action(
        record.title.isEmpty ? self.app.text("未填写菜名 · 继续编辑", "Dish name missing · Continue editing") : record.title
      ) { [weak self] in
        self?.edit(record, meal: meal)
      }
      let remove = QFContentUI.action(self.app.text("移除", "Remove"), destructive: true) { [weak self] in
        guard let self else { return }
        self.records.removeAll { $0.id == record.id }
        if !self.persist() {
          self.message(self.app.text(
            "本机草稿暂时无法保存，请精简内容后重试。",
            "The local draft could not be saved. Shorten it and try again."), error: true)
        }
        self.render()
      }
      let accessibleName = record.title.isEmpty ? self.app.text("未命名菜品", "Unnamed dish") : record.title
      remove.accessibilityLabel = self.app.format("移除%@", "Remove %@", accessibleName)
      let cost = record.cost.map { "\(record.currency) \($0)" } ?? self.app.text("成本待补全", "Cost missing")
      return QFTabUI.card(QFTabUI.stack([name,
        QFContentUI.label(self.app.format(
          "%@ · %d 种用料 · %@", "%@ · %d materials · %@",
          record.mealTitle(app: self.app), record.materials.count, cost),
          size: 13, color: QFUI.secondary), remove], spacing: 8))
    }
  }
  private func edit(_ record: QFCookingRecord?, meal: QFCookingMeal) {
    guard deferredRecords.isEmpty else {
      message(app.text(
        "请先恢复其他日期的旧草稿，再继续编辑。当天已填好的菜品仍可保存。",
        "Recover the older drafts for other dates before continuing. You can still save completed dishes for this day."), error: true)
      return
    }
    guard record != nil || records.count < 30 else {
      message(app.text(
        "这次最多添加30道菜，请先保存后继续补记当天的菜品。",
        "You can add up to 30 dishes at a time. Save these before adding more for this day."), error: true)
      return
    }
    var value = record ?? QFCookingRecord()
    value.date = date
    if record == nil { value.meal = meal.rawValue }
    open(QFCookingRecordEditorViewController(app: app, record: value, existing: false, fixedDate: date) { [weak self] updated in
      guard let self else { return }
      var dish = updated
      dish.date = self.date
      if let index = self.records.firstIndex(where: { $0.id == dish.id }) { self.records[index] = dish }
      else { self.records.append(dish) }
      if !self.persist() {
        self.message(self.app.text(
          "本机草稿暂时无法保存，请精简内容后重试。",
          "The local draft could not be saved. Shorten it and try again."), error: true)
      }
      self.render()
    })
  }
  private static func restoreRecords(app: QFAppSession, date: String) -> (current: [QFCookingRecord], deferred: [QFCookingRecord]) {
    let key = "cooking-batch-" + date
    let stored = QFContentDraftStore.load([QFCookingRecord].self, app: app, kind: key) ?? []
    let current = stored.filter { $0.date == date }
    var deferred: [QFCookingRecord] = []
    // The previous editor allowed a dish to leave the parent date. Preserve its actual
    // date by moving it to that day's local draft, without uploading or changing it.
    for (otherDate, dishes) in Dictionary(grouping: stored.filter { $0.date != date }, by: \.date) {
      let otherKey = "cooking-batch-" + otherDate
      var target = QFContentDraftStore.load([QFCookingRecord].self, app: app, kind: otherKey) ?? []
      var pendingWrite: [QFCookingRecord] = []
      var conflicts: [QFCookingRecord] = []
      for dish in dishes {
        if let existing = target.first(where: { $0.id == dish.id }) {
          if existing != dish { conflicts.append(dish) }
        } else {
          target.append(dish)
          pendingWrite.append(dish)
        }
      }
      if pendingWrite.isEmpty || QFContentDraftStore.save(target, app: app, kind: otherKey) {
        deferred.append(contentsOf: conflicts)
      } else {
        deferred.append(contentsOf: conflicts + pendingWrite)
      }
    }
    let retained = current + deferred
    if retained.count != stored.count {
      if retained.isEmpty { QFContentDraftStore.remove(app: app, kind: key) }
      else { QFContentDraftStore.save(retained, app: app, kind: key) }
    }
    return (current, deferred)
  }
  private func retryDraftRecovery() {
    guard persist() else {
      message(app.text(
        "本机草稿暂时无法保存，已保留当前页面内容，请精简后重试。",
        "The local draft could not be saved. This page still keeps your content; shorten it and try again."), error: true)
      return
    }
    let restored = Self.restoreRecords(app: app, date: date)
    records = restored.current; deferredRecords = restored.deferred
    render()
  }
  @discardableResult
  private func persist() -> Bool {
    let retained = records + deferredRecords
    if retained.isEmpty {
      QFContentDraftStore.remove(app: app, kind: draftKey)
      return QFContentDraftStore.load([QFCookingRecord].self, app: app, kind: draftKey) == nil
    }
    return QFContentDraftStore.save(retained, app: app, kind: draftKey)
  }
  private func submit() {
    guard !records.isEmpty else { return }
    guard records.allSatisfy({ $0.date == date }) else {
      message(app.text(
        "只能保存所选日期的菜品，请返回后重新打开当天记录。",
        "Only dishes for the selected date can be saved. Go back and reopen that day's records."), error: true)
      return
    }
    if let invalid = records.first(where: { $0.validation != nil }) {
      message(
        (invalid.title.isEmpty ? app.text("未命名记录", "Unnamed record") : invalid.title)
          + app.text("：", ": ")
          + (invalid.validation(app: app) ?? app.text("请完善记录", "Complete the record")),
        error: true)
      return
    }
    view.endEditing(true)
    guard persist() else {
      message(app.text(
        "本机草稿暂时无法保存，请精简内容后重试。",
        "The local draft could not be saved. Shorten it and try again."), error: true)
      return
    }
    let pending = records
    execute(label: app.text("保存记录中", "Saving records")) { [self] in
      var savedCount = 0
      var localDraftSyncFailed = false
      do {
        for record in pending {
          let _: QFCookingRecord = try await app.contentRequest(path: "me/cooking-records/\(record.id)",
            method: "PUT", body: JSONEncoder().encode(record.requestBody))
          records.removeAll { $0.id == record.id }
          savedCount += 1
          if !persist() {
            localDraftSyncFailed = true
            throw QFAPIError(code: 50000, message: app.text(
              "本机草稿状态同步失败", "The local draft state could not be synchronized."))
          }
        }
      } catch is CancellationError {
        if savedCount > 0 {
          render()
          onChanged?()
        }
        throw CancellationError()
      }
      catch {
        render()
        if savedCount > 0 { onChanged?() }
        if localDraftSyncFailed {
          throw QFAPIError(
            code: 50000,
            message: app.format(
              "当天已保存%d道菜，但本机草稿状态暂未同步。再次保存会按原记录更新，不会重复新增。",
              "%d dishes were saved for this day, but the local draft state has not synchronized. Saving again updates the same records and will not create duplicates.",
              savedCount))
        }
        throw QFAPIError(code: 40000, message: app.format(
          "当天已保存%d道菜，其余%d道已保留。",
          "Saved %d dishes for this day; the other %d remain saved locally. ", savedCount, records.count)
          + Self.errorText(error, app: app))
      }
      onChanged?(); qfClose()
    }
  }
  override func close() {
    guard !records.isEmpty else { super.close(); return }
    let alert = UIAlertController(
      title: app.text("保留未提交的内容？", "Keep unsubmitted changes?"),
      message: app.text("返回不会自动发布或提交。", "Going back will not publish or submit anything automatically."),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: app.text("继续编辑", "Keep editing"), style: .cancel))
    alert.addAction(UIAlertAction(title: app.text("保留草稿", "Keep draft"), style: .default) { [weak self] _ in
      guard let self else { return }
      if persist() { finishClose() }
      else { message(app.text(
        "本机草稿暂时无法保存，请精简内容后重试。",
        "The local draft could not be saved. Shorten it and try again."), error: true) }
    })
    alert.addAction(UIAlertAction(title: app.text("放弃修改", "Discard changes"), style: .destructive) { [weak self] _ in
      guard let self else { return }
      let discarded = records
      records.removeAll()
      if persist() {
        finishClose()
      } else {
        records = discarded
        render()
        message(app.text(
          "本机草稿暂时无法更新，当前内容仍保留在页面中。",
          "The local draft could not be updated. Your content remains on this page."), error: true)
      }
    })
    open(alert)
  }
  private func applyLanguage() {
    updateHeading(app.text("补记做菜", "Add cooking record"), backLabel: app.text("返回", "Back"))
    render()
  }
  private func finishClose() { super.close() }
}
