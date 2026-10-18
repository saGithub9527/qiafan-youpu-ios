import SnapKit
import UIKit

struct QFCookingMonthSummary: Codable {
  let month: String
  let completedCount: Int
  let cookingDays: Int
  let recordDates: [String]
  let totals: [QFCurrencyTotal]
  let missingCostCount: Int
}
struct QFCookingHistoryPage: Decodable {
  let items: [QFCookingRecord]
  let total: Int
  let summary: QFCookingMonthSummary
  let totals: [QFCurrencyTotal]
  let missingCostCount: Int
}
struct QFPlanHistoryDayState {
  var items: [QFCookingRecord] = []
  var total: Int?
  var summary: QFCookingMonthSummary?
  var totals: [QFCurrencyTotal] = []
  var missingCostCount = 0
  var nextPage = 0
  var reachedEmptyPage = false
  var updatedAt = Date.distantPast
  var hasMore: Bool { !reachedEmptyPage && items.count < (total ?? 0) }
  mutating func apply(_ page: QFCookingHistoryPage, at index: Int) {
    if index == 0 { items = [] }
    var positions = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
    for item in page.items {
      if let old = positions[item.id] { items[old] = item }
      else { positions[item.id] = items.count; items.append(item) }
    }
    total = page.total; summary = page.summary; totals = page.totals
    missingCostCount = page.missingCostCount; nextPage = index + 1; updatedAt = Date()
  }
}
enum QFPlanHistoryLayout {
  static let pageInset: CGFloat = 24
  static let cardRadius: CGFloat = 18
  static let summaryHeight: CGFloat = 90
  static let dateHeight: CGFloat = 64
  static let recordHeight: CGFloat = 86
}

/// Design08 is the plan history entry; the profile calendar/list remains independent.
@MainActor
final class QFPlanCookingHistoryViewController: QFProfileContentController {
  private var selected: Date
  private var weekStart: Date
  private var state = QFPlanHistoryDayState()
  private var dayCache: [String: QFPlanHistoryDayState] = [:]
  private var failure: String?
  private var needsReload = false
  private let results = QFContentListTable(frame: .zero, style: .plain)
  private var calendar: Calendar { Calendar(identifier: .gregorian) }
  private var dateKey: String { QFContentDate.day(selected) }
  override var reloadsOnAppearance: Bool { false }

  init(app: QFAppSession, date: Date = Date()) {
    let calendar = Calendar(identifier: .gregorian)
    selected = calendar.startOfDay(for: date)
    weekStart = calendar.date(byAdding: .day, value: -3, to: selected) ?? selected
    super.init(app: app, title: app.text("做菜记录", "Cooking history"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); view.accessibilityIdentifier = "plan.history"
    let add = QFTabUI.button(app.text("补记", "Add record"), size: 14, color: QFUI.orange) { [weak self] in self?.backfill() }
    add.accessibilityIdentifier = "plan.history.add"
    installHeaderAction(add)
    results.horizontalInset = QFPlanHistoryLayout.pageInset; results.spacing = 12
    results.contentInset.top = 16; results.contentInset.bottom = 8
    results.accessibilityIdentifier = "plan.history.list"
    installList(results)
    setReloadAction { [weak self] in self?.load(force: true) }
    render(); load()
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if needsReload { needsReload = false; load(force: true) }
  }
  private func load(append: Bool = false, force: Bool = false) {
    let requestedDate = dateKey
    let requestedLanguage = app.interfaceLanguage
    let first = append ? state.nextPage : 0
    // Refresh the pages already shown so a write does not collapse a long list to page one.
    let last = append ? first : isRefreshingContent ? 0 : max(0, state.nextPage - 1)
    let previous = state
    execute(reloadOnFailure: true, loadingMore: append, showsInitialReadProgress: false) { [self] in
      do {
        var updated = append ? previous : QFPlanHistoryDayState()
        for page in first...last {
          let response: QFCookingHistoryPage = try await QFContentLoadingContext.$forceRefresh.withValue(force || isRefreshingContent) {
            try await app.contentRequest(path: "me/cooking-records", query: ["month": String(requestedDate.prefix(7)), "date": requestedDate, "page": String(page)])
          }
          try Task.checkCancellation()
          guard dateKey == requestedDate, app.interfaceLanguage == requestedLanguage else { throw CancellationError() }
          let before = updated.items.count
          updated.apply(response, at: page)
          // A stale count or an empty page must not cause a loop of automatic requests.
          if !updated.hasMore || updated.items.count == before { if updated.items.count == before { updated.reachedEmptyPage = true }; break }
        }
        state = updated; failure = nil; dayCache[requestedDate] = updated
        if dayCache.count > 10, let oldest = dayCache.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key { dayCache.removeValue(forKey: oldest) }
        render()
      } catch is CancellationError { throw CancellationError() }
      catch {
        guard dateKey == requestedDate else { throw CancellationError() }
        if append { throw error }
        failure = Self.errorText(error, app: app); render()
      }
    }
  }
  private func select(_ date: Date, shiftWeek: Bool = false) {
    selected = calendar.startOfDay(for: date)
    if shiftWeek { weekStart = calendar.date(byAdding: .day, value: -3, to: selected) ?? selected }
    state = dayCache[dateKey] ?? QFPlanHistoryDayState(); failure = nil
    render(); results.setContentOffset(CGPoint(x: 0, y: -results.adjustedContentInset.top), animated: false)
    if Date().timeIntervalSince(state.updatedAt) >= 120 { load() }
  }
  private func shiftWeek(_ offset: Int) {
    guard let date = calendar.date(byAdding: .day, value: offset * 7, to: selected) else { return }
    select(date, shiftWeek: true)
  }
  private func invalidateAfterWrite() {
    dayCache.removeAll(); needsReload = true; onChanged?()
  }
  private func backfill() {
    guard dateKey <= QFContentDate.day(Date()) else {
      message(app.text("未来日期还不能补记做菜，请先选择今天或过去的日期。", "Cooking history cannot be added for a future date. Choose today or an earlier date."), error: true); return
    }
    let editor = QFBackfillCookingViewController(app: app, date: dateKey, householdID: app.planningHouseholdID)
    editor.onChanged = { [weak self] in self?.invalidateAfterWrite() }; open(editor)
  }
  private func detail(_ record: QFCookingRecord) {
    let editor: QFProfileContentController = record.inventoryMode == "ACTUAL_MATERIALS"
      ? QFCookingRecordDetailViewController(app: app, record: record)
      : QFCookingRecordEditorViewController(app: app, record: record, existing: true)
    editor.onChanged = { [weak self] in self?.invalidateAfterWrite() }; open(editor)
  }
  private func statistics() {
    let controller = QFCookingUsageViewController(app: app, date: QFManualPlanDraft.date(dateKey) ?? Date())
    open(controller)
  }
  private func localizedDate(_ date: Date, template: String) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    formatter.calendar = calendar; formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: date)
  }
  private func money(_ currency: String, _ amount: String) -> String {
    let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = currency
    formatter.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    guard let value = Decimal(string: amount), let text = formatter.string(from: NSDecimalNumber(decimal: value)) else { return currency + " " + amount }
    return text
  }
  private func costs(_ values: [QFCurrencyTotal], missing: Int) -> String {
    var parts = values.map { money($0.currency, $0.total) }
    if missing > 0 { parts.append(app.format("%d 道成本待补全", "%d costs missing", missing)) }
    return parts.isEmpty ? "—" : parts.joined(separator: " · ")
  }
  private func render() {
    let summary = state.summary
    let language = app.interfaceLanguage
    results.beginUpdatesForRows()
    results.row("summary", version: "\(summary?.completedCount ?? -1)|\(summary?.cookingDays ?? -1)|" + language) { [weak self] in
      guard let self else { return UIView() }
      let row = QFTabUI.stack([
        summaryCard(app.text("本月完成", "Completed this month"), value: summary.map { String($0.completedCount) } ?? "—", unit: app.text("道", "dishes")),
        summaryCard(app.text("下厨天数", "Cooking days"), value: summary.map { String($0.cookingDays) } ?? "—", unit: app.text("天", "days"))
      ], axis: .horizontal, spacing: 12)
      row.distribution = .fillEqually; return row
    }
    results.row("dates", version: dateKey + QFContentDate.day(weekStart) + (summary?.recordDates.joined() ?? "") + language) { [weak self] in
      guard let self else { return UIView() }
      let title = QFContentUI.label(localizedDate(selected, template: "yMMMM"), size: 19, bold: true)
      let previous = QFTabUI.iconButton("chevron.left", label: app.text("上周", "Previous week"), size: 20) { [weak self] in self?.shiftWeek(-1) }
      let next = QFTabUI.iconButton("chevron.right", label: app.text("下周", "Next week"), size: 20) { [weak self] in self?.shiftWeek(1) }
      previous.accessibilityIdentifier = "plan.history.previous"; next.accessibilityIdentifier = "plan.history.next"
      let header = QFTabUI.stack([title, previous, next], axis: .horizontal, spacing: 6)
      let days = QFTabUI.stack([], axis: .horizontal, spacing: 4); days.distribution = .fillEqually
      for offset in 0..<7 {
        guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { continue }
        let key = QFContentDate.day(date), active = key == dateKey
        let label = QFContentUI.label(localizedDate(date, template: "EEEEE"), size: 12, color: QFUI.secondary); label.textAlignment = .center
        let day = QFContentUI.label(String(calendar.component(.day, from: date)), size: 17, bold: active, color: active ? QFUI.green : QFUI.text); day.textAlignment = .center
        let dot = QFContentUI.label(summary?.recordDates.contains(key) == true ? "•" : " ", size: 12, color: QFUI.orange); dot.textAlignment = .center; dot.isAccessibilityElement = false
        let content = QFTabUI.stack([label, day, dot], spacing: 3)
        let button = control(content, padding: 6, background: active ? QFUI.paleGreen : .clear) { [weak self] in self?.select(date) }
        button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(QFPlanHistoryLayout.dateHeight) }
        button.accessibilityIdentifier = "plan.history.date." + key
        button.accessibilityLabel = localizedDate(date, template: "yMMMMdEEEE")
        if active { button.accessibilityTraits.insert(.selected) }
        days.addArrangedSubview(button)
      }
      return QFTabUI.stack([header, days], spacing: 12)
    }
    results.row("day", version: dateKey + String(state.total ?? -1) + costs(state.totals, missing: state.missingCostCount) + language) { [weak self] in
      guard let self else { return UIView() }
      let text = (calendar.isDateInToday(selected) ? app.text("今天", "Today") + " · " : "") + localizedDate(selected, template: "MMMd")
      let title = QFContentUI.label(text, size: 18, bold: true)
      let amount = state.total.map { self.app.format("完成 %d 道", "%d completed", $0) } ?? "—"
      let detail = QFContentUI.label(amount + " · " + costs(state.totals, missing: state.missingCostCount), size: 13, color: QFUI.green)
      detail.textAlignment = .right
      return QFTabUI.stack([title, detail], axis: .horizontal, spacing: 12)
    }
    if let failure {
      results.row("failure", version: failure + language) { [weak self] in
        guard let self else { return UIView() }
        let button = control(QFTabUI.stack([QFContentUI.label(app.text("加载失败", "Could not load"), size: 17, bold: true), QFContentUI.label(failure, size: 14, color: QFUI.secondary), QFContentUI.label(app.text("重试", "Retry"), size: 15, color: QFUI.orange)], spacing: 8), padding: 16) { [weak self] in self?.load(force: true) }
        button.accessibilityIdentifier = "plan.history.retry"
        button.accessibilityLabel = failure + " " + app.text("重试", "Retry")
        return button
      }
    } else if state.total == nil {
      results.row("loading", version: language) { [app] in
        let spinner = UIActivityIndicatorView(style: .medium); spinner.startAnimating()
        return QFTabUI.card(QFTabUI.stack([spinner, QFContentUI.label(app.text("加载中", "Loading"), size: 15, color: QFUI.secondary)], axis: .horizontal, spacing: 12))
      }
    } else if state.items.isEmpty {
      results.row("empty", version: language) { [app] in QFTabUI.empty(app.text("这天还没有做菜记录", "No cooking history for this day"), detail: app.text("记录今天做过的菜。", "Record what you cooked today.")) }
    }
    for record in state.items {
      let version = (try? JSONEncoder().encode(record).base64EncodedString()) ?? record.id
      results.row("record." + record.id, version: version + language) { [weak self] in
        guard let self else { return UIView() }
        let title = QFContentUI.label(record.title, size: 19, bold: true)
        let note = QFContentUI.label(record.mealTitle(app: app) + " · " + app.text("已完成", "Completed"), size: 13, color: QFUI.secondary)
        let price = QFContentUI.label(record.cost.map { self.money(record.currency, $0) } ?? app.text("成本待补全", "Cost missing"), size: 16)
        price.textAlignment = .right; price.setContentHuggingPriority(.required, for: .horizontal)
        let row = QFTabUI.stack([QFTabUI.stack([title, note], spacing: 10), price, QFTabUI.symbol("chevron.right", size: 14, color: QFUI.secondary)], axis: .horizontal, spacing: 10); row.alignment = .center
        let button = control(row, padding: 18) { [weak self] in self?.detail(record) }
        button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(QFPlanHistoryLayout.recordHeight) }
        button.accessibilityIdentifier = "plan.history.record." + record.id
        button.accessibilityLabel = [record.title, record.mealTitle(app: app), price.text ?? ""].joined(separator: ", ")
        return button
      }
    }
    results.row("cost", version: costs(summary?.totals ?? [], missing: summary?.missingCostCount ?? 0) + language) { [weak self] in
      guard let self else { return UIView() }
      let amount = QFContentUI.label(costs(summary?.totals ?? [], missing: summary?.missingCostCount ?? 0), size: 16, color: QFUI.green); amount.textAlignment = .right
      return QFTabUI.stack([QFContentUI.label(app.text("本月消耗成本", "This month's ingredient cost"), size: 13, color: QFUI.secondary), amount], axis: .horizontal, spacing: 12)
    }
    results.row("statistics", version: language) { [weak self] in
      guard let self else { return UIView() }
      let button = control(QFTabUI.stack([QFContentUI.label(app.text("菜品使用统计", "Dish statistics"), size: 17, bold: true), QFTabUI.symbol("chevron.right", size: 18, color: QFUI.secondary)], axis: .horizontal, spacing: 12), padding: 16) { [weak self] in self?.statistics() }
      button.accessibilityLabel = app.text("菜品使用统计", "Dish statistics"); return button
    }
    results.endUpdatesForRows()
    setLoadMoreAction(state.hasMore ? { [weak self] in self?.load(append: true) } : nil)
  }
  private func summaryCard(_ title: String, value: String, unit: String) -> UIView {
    let label = QFContentUI.label(value, size: 30, bold: true)
    label.setContentHuggingPriority(.required, for: .horizontal)
    let number = QFTabUI.stack([label, QFContentUI.label(unit, size: 13, color: QFUI.secondary), UIView()], axis: .horizontal, spacing: 8); number.alignment = .lastBaseline
    let card = QFTabUI.card(QFTabUI.stack([QFContentUI.label(title, size: 13, color: QFUI.secondary), number], spacing: 10), padding: 16)
    card.snp.makeConstraints { $0.height.greaterThanOrEqualTo(QFPlanHistoryLayout.summaryHeight) }; return card
  }
  private func control(_ content: UIView, padding: CGFloat, background: UIColor = QFUI.surface, action: @escaping () -> Void) -> UIControl {
    let control = UIControl(); control.backgroundColor = background; control.layer.cornerRadius = QFPlanHistoryLayout.cardRadius
    control.addSubview(content); content.isUserInteractionEnabled = false
    content.snp.makeConstraints { $0.edges.equalToSuperview().inset(padding) }
    control.addAction(UIAction { _ in action() }, for: .touchUpInside); control.accessibilityTraits = .button
    control.isAccessibilityElement = true; return control
  }
}
