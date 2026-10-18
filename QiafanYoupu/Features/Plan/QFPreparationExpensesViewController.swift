import DGCharts
import SnapKit
import UIKit

/// Design11: purchase outlay and consumption cost have independent, currency-separated totals.
@MainActor
final class QFPreparationExpensesViewController: QFProfileContentController {
  private let referenceDate: Date
  private let householdID: String?
  private var range: QFExpenseRange
  private var selectedPeriod = 0
  private var summary: QFPreparationExpenses?
  private var receipts: [QFPurchaseReceipt] = []
  private var total = 0
  private var nextPage = 0
  private var reachedEnd = false
  private var failure: String?
  private var updatedAt = Date.distantPast
  private var needsReload = false
  private var chartCurrency: String?
  private var locale: Locale { Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier) }
  override var reloadsOnAppearance: Bool { false }

  init(app: QFAppSession, date: Date = Date(), householdID: String? = nil) {
    referenceDate = date; range = .week(containing: date); self.householdID = householdID
    super.init(app: app, title: app.text("备菜花销", "Prep expenses"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); view.accessibilityIdentifier = "plan.expenses"
    let add = QFTabUI.button(app.text("记一笔", "Add receipt"), size: 14, color: QFUI.orange) { [weak self] in self?.createReceipt() }
    add.accessibilityIdentifier = "plan.expenses.add"; installHeaderAction(add)
    setReloadAction { [weak self] in self?.load(force: true) }
    render(); load()
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if needsReload || (summary != nil && Date().timeIntervalSince(updatedAt) > 120) { needsReload = false; load(force: true) }
  }
  private func query(page: Int? = nil) -> [String: String] {
    var value = range.query; value["householdId"] = householdID
    if let page { value["page"] = String(page) }; return value
  }
  private func load(append: Bool = false, force: Bool = false) {
    let context = range; let language = app.interfaceLanguage; let page = append ? nextPage : 0
    execute(reloadOnFailure: true, loadingMore: append, showsInitialReadProgress: false) { [self] in
      do {
        let response: QFPurchaseReceiptPage = try await QFContentLoadingContext.$forceRefresh.withValue(force) {
          try await app.contentRequest(path: "me/purchase-receipts", query: query(page: page))
        }
        let freshSummary: QFPreparationExpenses? = append ? summary : try await QFContentLoadingContext.$forceRefresh.withValue(force) {
          try await app.contentRequest(path: "me/preparation-expenses", query: query())
        }
        try Task.checkCancellation(); guard range == context, language == app.interfaceLanguage else { throw CancellationError() }
        if append {
          let known = Set(receipts.map(\.id)); let additions = response.items.filter { !known.contains($0.id) }
          receipts.append(contentsOf: additions); reachedEnd = additions.isEmpty
        } else { receipts = response.items; reachedEnd = response.items.isEmpty }
        total = response.total; nextPage = page + 1; summary = freshSummary; failure = nil; updatedAt = Date()
        render()
      } catch is CancellationError { throw CancellationError() }
      catch { if append { throw error }; failure = Self.errorText(error, app: app); render() }
    }
  }
  private func changed() { needsReload = true; onChanged?() }
  private func createReceipt() {
    let editor = QFPurchaseReceiptViewController(app: app, date: QFContentDate.day(referenceDate), householdID: householdID)
    editor.onChanged = { [weak self] in self?.changed() }; open(editor)
  }
  private func openReceipt(_ item: QFPurchaseReceipt) {
    if item.source == "LEGACY" {
      let editor = QFPurchasesViewController(app: app, date: item.date)
      editor.onChanged = { [weak self] in self?.changed() }; open(editor); return
    }
    let editor = QFPurchaseReceiptViewController(app: app, receipt: item)
    editor.onChanged = { [weak self] in self?.changed() }; open(editor)
  }
  private func openCost() {
    open(QFCookingCostsViewController(app: app, range: range, householdID: householdID))
  }
  private func selectPeriod(_ index: Int) {
    if index == 2 {
      let picker = QFExpenseDateRangeController(app: app, range: range) { [weak self] value in self?.changeRange(value, selected: 2) }
      open(picker); return
    }
    changeRange(index == 0 ? .week(containing: referenceDate) : .month(containing: referenceDate), selected: index)
  }
  private func changeRange(_ value: QFExpenseRange, selected: Int) {
    guard range != value || selectedPeriod != selected else { return }
    range = value; selectedPeriod = selected; summary = nil; receipts = []; nextPage = 0; total = 0; failure = nil; reachedEnd = false
    render(); load()
  }
  private func money(_ value: QFCurrencyTotal) -> String { QFPurchaseNumber.money(value.total, currency: value.currency, locale: locale) }
  private func totals(_ values: [QFCurrencyTotal]) -> String { values.isEmpty ? "—" : values.map(money).joined(separator: "\n") }
  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row("period", version: "\(range)|\(selectedPeriod)|\(app.interfaceLanguage)") { [weak self] in
      guard let self else { return UIView() }
      let tabs = QFContentUI.segments([self.app.text("本周", "This week"), self.app.text("本月", "This month"), self.app.text("自定义", "Custom")], selected: self.selectedPeriod) { [weak self] in self?.selectPeriod($0) }
      return QFTabUI.stack([tabs, QFTabUI.label(self.range.startDate + " – " + self.range.endDate, size: 12, color: QFUI.secondary)], spacing: 10)
    }
    if let summary {
      bodyStack.row("summary", value: summary) { [weak self] in self?.summaryCard(summary) ?? UIView() }
      bodyStack.row("trend", version: "\(summary.trend.map { $0.date + String(describing: $0.totals) })|\(chartCurrency ?? "")|\(app.interfaceLanguage)") { [weak self] in self?.chart(summary) ?? UIView() }
    } else {
      bodyStack.row("initial", version: (failure ?? "loading") + app.interfaceLanguage) { [weak self] in
        guard let self else { return UIView() }
        return QFTabUI.empty(self.failure == nil ? self.app.text("正在加载", "Loading") : self.app.text("暂时无法加载", "Unable to load"), detail: self.failure ?? self.app.text("采购账单与消耗成本", "Purchase receipts and cooking costs"))
      }
    }
    bodyStack.row("list-title", version: "\(total)|\(app.interfaceLanguage)") { [app, total] in
      QFTabUI.stack([QFTabUI.label(app.text("采购账单", "Purchase receipt"), size: 18, weight: .semibold), UIView(), QFTabUI.label(app.format("共 %d 笔", "%d receipts", total), size: 12, color: QFUI.secondary)], axis: .horizontal, spacing: 12)
    }
    if summary != nil && receipts.isEmpty {
      bodyStack.row("empty", version: app.interfaceLanguage) { [app] in QFTabUI.empty(app.text("暂无采购账单", "No purchase receipts"), detail: app.text("记下一笔采购，支出会显示在这里。", "Record a purchase to see your spending here.")) }
    }
    for item in receipts { bodyStack.row(item.id, value: item) { [weak self] in self?.receiptCard(item) ?? UIView() } }
    bodyStack.endUpdates(); setLoadMoreAction(!reachedEnd && receipts.count < total ? { [weak self] in self?.load(append: true) } : nil)
  }
  private func summaryCard(_ value: QFPreparationExpenses) -> UIView {
    let heading = QFTabUI.label(app.text("实际采购支出", "Purchase spending"), size: 14, color: .white)
    let amount = QFTabUI.label(totals(value.purchaseTotals), size: 34, weight: .bold, color: .white, lines: 0)
    let count = QFTabUI.label(app.format("%d 笔采购 · %d 笔价格待补全", "%d receipts · %d awaiting prices", value.purchaseCount, value.pendingPurchaseCount), size: 12, color: .white, lines: 0)
    let divider = UIView(); divider.backgroundColor = UIColor.white.withAlphaComponent(0.2); divider.snp.makeConstraints { $0.height.equalTo(1) }
    let cost = QFTabUI.button(app.text("食材消耗成本", "Ingredient consumption cost") + "  " + totals(value.consumptionTotals) + "  ›", size: 14, color: .white) { [weak self] in self?.openCost() }
    cost.titleLabel?.numberOfLines = 0; cost.contentHorizontalAlignment = .leading
    return QFTabUI.card(QFTabUI.stack([heading, amount, count, divider, cost], spacing: 12), padding: 18, background: QFUI.green)
  }
  private func chart(_ value: QFPreparationExpenses) -> UIView {
    let days = range.days
    let points = Dictionary(uniqueKeysWithValues: value.trend.map { ($0.date, $0.totals) })
    let currencies = Set(value.trend.flatMap { $0.totals.map(\.currency) }).sorted()
    let currency = chartCurrency.flatMap { currencies.contains($0) ? $0 : nil } ?? currencies.first
    var views: [UIView] = [QFTabUI.label(app.text("每日支出", "Daily spending"), size: 16, weight: .semibold)]
    if currencies.count > 1 {
      views.append(QFContentUI.segments(currencies, selected: currencies.firstIndex(of: currency ?? "") ?? 0) { [weak self] index in self?.chartCurrency = currencies[index]; self?.render() })
    }
    let chart = BarChartView(); chart.accessibilityIdentifier = "plan.expenses.chart"
    chart.legend.enabled = false; chart.rightAxis.enabled = false
    chart.leftAxis.labelTextColor = QFUI.secondary; chart.leftAxis.labelFont = .systemFont(ofSize: 10)
    chart.leftAxis.drawGridLinesEnabled = true; chart.leftAxis.gridColor = QFUI.border; chart.leftAxis.drawAxisLineEnabled = false
    chart.xAxis.labelPosition = .bottom; chart.xAxis.drawGridLinesEnabled = false; chart.xAxis.drawAxisLineEnabled = false
    chart.xAxis.labelTextColor = QFUI.secondary; chart.xAxis.labelFont = .systemFont(ofSize: 10)
    chart.xAxis.granularity = 1; chart.xAxis.valueFormatter = IndexAxisValueFormatter(values: days.map { String($0.suffix(5)) })
    chart.xAxis.setLabelCount(max(1, min(7, days.count)), force: false)
    chart.pinchZoomEnabled = false; chart.doubleTapToZoomEnabled = false; chart.setScaleEnabled(false); chart.dragEnabled = false
    chart.noDataText = app.text("暂无支出", "No spending yet"); chart.noDataTextColor = QFUI.secondary
    if let currency {
      let entries = days.enumerated().map { index, day in
        BarChartDataEntry(x: Double(index), y: Double(points[day]?.first { $0.currency == currency }?.total ?? "0") ?? 0)
      }
      chart.leftAxis.axisMinimum = min(0, (entries.map(\.y).min() ?? 0) * 1.1)
      chart.leftAxis.axisMaximum = max(0, (entries.map(\.y).max() ?? 0) * 1.1)
      if chart.leftAxis.axisMinimum == chart.leftAxis.axisMaximum { chart.leftAxis.axisMaximum = 1 }
      chart.leftAxis.drawZeroLineEnabled = true; chart.leftAxis.zeroLineColor = QFUI.secondary
      let data = BarChartDataSet(entries: entries, label: currency); data.colors = entries.map { $0.y < 0 ? QFUI.green : QFUI.orange }; data.drawValuesEnabled = false
      let chartData = BarChartData(dataSet: data); chartData.barWidth = 0.50; chart.data = chartData
      chart.xAxis.axisMinimum = -0.5; chart.xAxis.axisMaximum = Double(max(1, days.count)) - 0.5
      chart.accessibilityLabel = app.text("每日支出", "Daily spending") + " · " + currency
    }
    chart.snp.makeConstraints { $0.height.equalTo(QFPurchaseLayout.chartHeight) }; views.append(chart)
    return QFTabUI.card(QFTabUI.stack(views, spacing: 12), padding: 16, border: true)
  }
  private func receiptCard(_ item: QFPurchaseReceipt) -> UIView {
    let icon = QFTabUI.symbol("basket", size: 24, color: QFUI.green); icon.snp.makeConstraints { $0.width.equalTo(40) }
    let title = item.merchant.isEmpty ? app.text("采购账单", "Purchase receipt") : item.merchant
    let description = item.date + " · " + app.format("%d 项食材", "%d ingredients", item.items.count)
    let amount = (item.netPaidAmount ?? item.paidAmount).map { QFPurchaseNumber.money($0, currency: item.currency, locale: locale) } ?? app.text("价格待补全", "Price needed")
    let row = QFTabUI.stack([icon, QFTabUI.stack([QFTabUI.label(title, size: 16, weight: .semibold, lines: 0), QFTabUI.label(description, size: 12, color: QFUI.secondary)], spacing: 6), UIView(), QFTabUI.label(amount, size: 17, weight: .semibold, lines: 0), QFTabUI.symbol("chevron.right", size: 14, color: QFUI.secondary)], axis: .horizontal, spacing: 10)
    let button = QFTabUI.button("", background: QFUI.surface) { [weak self] in self?.openReceipt(item) }
    row.isUserInteractionEnabled = false; button.addSubview(row); row.snp.makeConstraints { $0.edges.equalToSuperview().inset(16) }
    button.accessibilityLabel = title + ", " + description + ", " + amount
    return button
  }
}

@MainActor
final class QFExpenseDateRangeController: QFProfileContentController {
  private var range: QFExpenseRange
  private let selected: (QFExpenseRange) -> Void
  override var reloadsOnAppearance: Bool { false }
  init(app: QFAppSession, range: QFExpenseRange, selected: @escaping (QFExpenseRange) -> Void) {
    self.range = range; self.selected = selected; super.init(app: app, title: app.text("选择日期范围", "Choose date range"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    for isStart in [true, false] {
      let picker = UIDatePicker(); picker.datePickerMode = .date; picker.preferredDatePickerStyle = .inline
      picker.calendar = QFManualPlanDraft.calendar; picker.timeZone = QFManualPlanDraft.calendar.timeZone
      picker.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
      picker.date = QFManualPlanDraft.date(isStart ? range.startDate : range.endDate) ?? Date()
      picker.addAction(UIAction { [weak self, weak picker] _ in
        guard let self, let picker else { return }; if isStart { self.range.startDate = QFManualPlanDraft.string(picker.date) } else { self.range.endDate = QFManualPlanDraft.string(picker.date) }
      }, for: .valueChanged)
      bodyStack.addArrangedSubview(QFTabUI.label(isStart ? app.text("开始日期", "Start date") : app.text("结束日期", "End date"), size: 16, weight: .semibold))
      bodyStack.addArrangedSubview(picker)
    }
    _ = addFooter(app.text("确定", "Confirm")) { [weak self] in
      guard let self else { return }
      guard self.range.startDate <= self.range.endDate else { self.message(self.app.text("结束日期不能早于开始日期", "End date cannot precede start date"), error: true); return }
      self.selected(self.range); self.close()
    }
  }
}
