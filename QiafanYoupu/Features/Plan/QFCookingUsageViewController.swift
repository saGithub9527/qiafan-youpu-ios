import Combine
import SnapKit
import UIKit

struct QFCookingUsagePage: Decodable {
  struct Summary: Decodable, Equatable { let cookingDays: Int; let completedCount: Int; let recipeCount: Int }
  struct Item: Decodable {
    let recipeId: String; let title: String?; let mediaId: String?; let contentAvailable: Bool
    let count: Int; let lastCookedOn: String; let totals: [QFCurrencyTotal]; let pendingCostCount: Int
  }
  let startDate: String; let endDate: String; let summary: Summary; let items: [Item]; let total: Int
}

// DESIGN_BASELINE: plan-cooking-usage-r1. Recipe identity and aggregate counts
// come from the server; a page of records must not be treated as the whole month.
@MainActor final class QFCookingUsageViewController: QFProfileContentController {
  private let reference: Date
  private var range: QFExpenseRange
  private var period = 1
  private var summary: QFCookingUsagePage.Summary?
  private var items: [QFCookingUsagePage.Item] = []
  private var total = 0
  private var nextPage = 0
  private var reachedEnd = false
  private var failure: String?
  private var needsReload = false
  override var reloadsOnAppearance: Bool { false }
  init(app: QFAppSession, date: Date = Date()) {
    reference = date; range = .month(containing: date)
    super.init(app: app, title: app.text("菜品使用统计", "Dish usage statistics"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); view.accessibilityIdentifier = "plan.cooking-usage"
    setReloadAction { [weak self] in self?.load(force: true) }
    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
      guard let self else { return }; self.updateHeading(self.app.text("菜品使用统计", "Dish usage statistics")); self.reset()
    }.store(in: &cancellables)
    render(); load()
  }
  override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); if needsReload { needsReload = false; load(force: true) } }
  private func reset() { summary = nil; items = []; total = 0; nextPage = 0; reachedEnd = false; failure = nil; render(); load() }
  private func load(append: Bool = false, force: Bool = false) {
    let context = range, language = app.interfaceLanguage, page = append ? nextPage : 0
    var query = range.query; query["page"] = String(page)
    execute(reloadOnFailure: true, loadingMore: append, showsInitialReadProgress: false) { [self] in
      do {
        let response: QFCookingUsagePage = try await QFContentLoadingContext.$forceRefresh.withValue(force) { try await app.contentRequest(path: "me/cooking-statistics", query: query) }
        try Task.checkCancellation(); guard context == range, language == app.interfaceLanguage else { throw CancellationError() }
        if !append { items = [] }
        var ids = Set(items.map(\.recipeId)); let fresh = response.items.filter { ids.insert($0.recipeId).inserted }
        items.append(contentsOf: fresh); reachedEnd = fresh.isEmpty; summary = response.summary; total = response.total; nextPage = page + 1; failure = nil; render()
      } catch is CancellationError { throw CancellationError() }
      catch { if append { throw error }; failure = Self.errorText(error, app: app); render() }
    }
  }
  private func select(_ index: Int) {
    if index == 2 {
      open(QFExpenseDateRangeController(app: app, range: range) { [weak self] in self?.range = $0; self?.period = 2; self?.reset() }); return
    }
    period = index; range = index == 0 ? .week(containing: reference) : .month(containing: reference); reset()
  }
  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row("filters", version: "\(range)|\(period)|\(app.interfaceLanguage)") { [weak self] in
      guard let self else { return UIView() }
      return QFContentUI.segments([self.app.text("本周", "This week"), self.app.text("本月", "This month"), self.app.text("自定义", "Custom")], selected: self.period) { [weak self] in self?.select($0) }
    }
    if let summary {
      bodyStack.row("summary", version: "\(summary)|\(app.interfaceLanguage)") { [app] in
        let titles = [app.text("做菜天数", "Cooking days"), app.text("完成菜品", "Completed dishes"), app.text("使用菜谱", "Recipes used")]
        let numbers = [summary.cookingDays, summary.completedCount, summary.recipeCount]
        let columns = zip(titles, numbers).map { title, value in
          let caption = QFTabUI.label(title, size: 13, color: QFUI.green, lines: 2)
          caption.snp.makeConstraints { $0.height.equalTo(34) }
          return QFTabUI.stack([caption, QFTabUI.label(String(value), size: 30, weight: .semibold)], spacing: 14)
        }
        let row = QFTabUI.stack(columns, axis: .horizontal, spacing: 14); row.distribution = .fillEqually
        return QFTabUI.card(row, padding: 18, background: QFUI.paleGreen)
      }
      bodyStack.row("heading", version: app.interfaceLanguage) { [app] in
        let row = QFTabUI.stack([QFTabUI.label(app.text("常做的菜", "Frequently cooked"), size: 20, weight: .semibold, lines: 2), UIView(), QFTabUI.label(app.text("按做菜次数", "By cooking frequency"), size: 12, color: QFUI.secondary, lines: 2)], axis: .horizontal, spacing: 10)
        row.alignment = .center; return row
      }
    }
    if items.isEmpty {
      bodyStack.row("state", version: "\(summary != nil)|\(failure ?? "")|\(app.interfaceLanguage)") { [app, summary, failure] in
        QFTabUI.empty(failure != nil ? app.text("暂时无法加载", "Unable to load") : summary == nil ? app.text("正在加载", "Loading") : app.text("暂无记录", "No records"), detail: failure ?? "")
      }
    }
    for item in items { bodyStack.row(item.recipeId, version: "\(item)|\(app.interfaceLanguage)") { [weak self] in self?.card(item) ?? UIView() } }
    bodyStack.endUpdates(); setLoadMoreAction(!reachedEnd && items.count < total ? { [weak self] in self?.load(append: true) } : nil)
  }
  private func card(_ item: QFCookingUsagePage.Item) -> UIView {
    let title = item.contentAvailable ? item.title ?? app.text("当前语言内容不可用", "Content unavailable in this language") : app.text("当前语言内容不可用", "Content unavailable in this language")
    let button = QFTabUI.button("", background: QFUI.surface) { [weak self] in
      guard let self else { return }
      let list = QFRecipeCookingRecordsViewController(app: self.app, recipeID: item.recipeId, title: title, range: self.range)
      list.onChanged = { [weak self] in self?.needsReload = true; self?.onChanged?() }; self.open(list)
    }
    button.accessibilityIdentifier = "cooking.usage." + item.recipeId
    let image = QFContentImageView(); image.load(item.mediaId, app: app); image.layer.cornerRadius = 14; image.clipsToBounds = true; image.backgroundColor = QFUI.paleGreen; image.snp.makeConstraints { $0.size.equalTo(48) }
    let name = QFTabUI.label(title, size: 17, weight: .semibold, lines: 2)
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let count = QFTabUI.label(app.format("%d 次", "%d times", item.count), size: 16, weight: .semibold, color: QFUI.green)
    count.accessibilityIdentifier = "cooking.usage.count." + item.recipeId
    count.setContentCompressionResistancePriority(.required, for: .horizontal)
    count.setContentHuggingPriority(.required, for: .horizontal)
    let top = QFTabUI.stack([name, count], axis: .horizontal, spacing: 8)
    let locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    let money = item.totals.map { QFPurchaseNumber.money($0.total, currency: $0.currency, locale: locale) }.joined(separator: " · ")
    var subtitle = item.lastCookedOn + (money.isEmpty ? "" : " · " + money)
    if item.pendingCostCount > 0 { subtitle += " · " + app.format("%d 次成本待补全", "Costs pending for %d sessions", item.pendingCostCount) }
    let progress = UIProgressView(progressViewStyle: .bar); progress.progressTintColor = QFUI.green; progress.trackTintColor = QFUI.surfaceAlt
    progress.progress = Float(item.count) / Float(max(items.first?.count ?? 1, 1)); progress.snp.makeConstraints { $0.height.equalTo(4) }
    let text = QFTabUI.stack([top, QFTabUI.label(subtitle, size: 12, color: QFUI.secondary, lines: 0), progress], spacing: 10)
    let row = QFTabUI.stack([image, text], axis: .horizontal, spacing: 12); row.alignment = .center; row.isUserInteractionEnabled = false
    button.addSubview(row); row.snp.makeConstraints { $0.edges.equalToSuperview().inset(16) }
    button.layer.cornerRadius = 18; button.layer.borderColor = QFUI.border.cgColor; button.layer.borderWidth = 1
    button.accessibilityLabel = title + ", " + String(item.count) + ", " + subtitle; return button
  }
}

@MainActor final class QFRecipeCookingRecordsViewController: QFProfileContentController {
  private let recipeID: String; private let range: QFExpenseRange
  private var records: [QFCookingRecord] = []; private var nextPage = 0; private var total = 0; private var loaded = false; private var failure: String?; private var needsReload = false
  override var reloadsOnAppearance: Bool { false }
  init(app: QFAppSession, recipeID: String, title: String, range: QFExpenseRange) { self.recipeID = recipeID; self.range = range; super.init(app: app, title: title) }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad(); setReloadAction { [weak self] in self?.load(force: true) }
    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
      guard let self else { return }; self.updateHeading(self.app.text("做菜记录", "Cooking history"))
      self.records = []; self.nextPage = 0; self.total = 0; self.loaded = false; self.failure = nil; self.render(); self.load()
    }.store(in: &cancellables)
    render(); load()
  }
  override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); if needsReload { needsReload = false; load(force: true) } }
  private func load(append: Bool = false, force: Bool = false) {
    let language = app.interfaceLanguage
    var query = range.query; query["recipeId"] = recipeID; query["page"] = String(append ? nextPage : 0)
    execute(reloadOnFailure: true, loadingMore: append, showsInitialReadProgress: false) { [self] in
      do {
        let response: QFContentPage<QFCookingRecord> = try await QFContentLoadingContext.$forceRefresh.withValue(force) { try await app.contentRequest(path: "me/cooking-records", query: query) }
        try Task.checkCancellation(); guard language == app.interfaceLanguage else { throw CancellationError() }
        if !append { records = []; nextPage = 0 }; var ids = Set(records.map(\.id)); records.append(contentsOf: response.items.filter { ids.insert($0.id).inserted }); total = response.items.isEmpty ? records.count : response.total
        nextPage += 1; loaded = true; failure = nil; render()
      } catch is CancellationError { throw CancellationError() } catch { if append { throw error }; failure = Self.errorText(error, app: app); render() }
    }
  }
  private func render() {
    bodyStack.beginUpdates()
    if records.isEmpty { bodyStack.row("state", version: "\(loaded)|\(failure ?? "")|\(app.interfaceLanguage)") { [app, loaded, failure] in QFTabUI.empty(failure != nil ? app.text("暂时无法加载", "Unable to load") : loaded ? app.text("暂无记录", "No records") : app.text("正在加载", "Loading"), detail: failure ?? "") } }
    for record in records {
      bodyStack.row(record.id, version: String(describing: record) + app.interfaceLanguage) { [weak self] in
        guard let self else { return UIView() }
        let title = record.date + " · " + (QFCookingMeal(rawValue: record.meal)?.title(app: self.app) ?? record.meal)
        let button = QFTabUI.button(title + "  ›", size: 17, background: QFUI.surface) { [weak self] in
          guard let self else { return }; let detail: QFProfileContentController = record.inventoryMode == "ACTUAL_MATERIALS" ? QFCookingRecordDetailViewController(app: self.app, record: record) : QFCookingRecordEditorViewController(app: self.app, record: record, existing: true)
          detail.onChanged = { [weak self] in self?.needsReload = true; self?.onChanged?() }; self.open(detail)
        }
        button.titleLabel?.numberOfLines = 0; button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(64) }; return button
      }
    }
    bodyStack.endUpdates(); setLoadMoreAction(records.count < total ? { [weak self] in self?.load(append: true) } : nil)
  }
}
