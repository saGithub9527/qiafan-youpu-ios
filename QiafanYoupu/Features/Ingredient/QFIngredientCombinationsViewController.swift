import Combine
import SnapKit
import UIKit

struct QFIngredientCombination: Codable, Equatable {
  struct Material: Codable, Equatable {
    let ingredientId: String?; let name: String; let categoryCode: String?; let iconKey: String?
    let quantityKind: String; let quantityMin: String?; let quantityMax: String?; let quantityText: String?; let unitCode: String?
    let availability: String; let availableQuantity: String?; let missingQuantity: String?
  }
  struct Plan: Codable, Equatable { let id: String; let date: String; let meal: String; let revision: Int }
  let recipeId: String; let title: String; let minutes: Int?; let servings: Int; let matchedCount: Int
  let materials: [Material]; var plans: [Plan]
}

// DESIGN_BASELINE: ingredient-discovery-r1. Selection/filter controls stay above the result scroll.
@MainActor final class QFIngredientCombinationsViewController: QFProfileContentController {
  private let resultScroll = UIScrollView()
  private let results = QFContentListStack()
  private let controls = QFTabUI.stack([], spacing: 16)
  private let chips = QFTabUI.stack([], spacing: 8)
  private let count = QFTabUI.label("", size: 15, weight: .semibold)
  private let resultCount = QFTabUI.label("", size: 12, color: QFUI.secondary)
  private let recommendationHeading = QFTabUI.label("", size: 20, weight: .semibold, lines: 2)
  private var addButton: UIButton!
  private var tabs: UISegmentedControl!
  private var tasteButton: UIButton!, timeButton: UIButton!
  private var options: QFRecipeHomeOptions?
  private var optionsTask: Task<Void, Never>?
  private var selections: [[QFCatalogItem]] = [[], []]
  private var selectedMode = 0
  private var taste: QFRecipeOption?
  private var maxMinutes: Int?
  private var items: [QFIngredientCombination] = []
  private var nextPage = 0
  private var total = 0
  private var hasMore = false
  private var loaded = false
  private var errorMessage: String?
  private var needsReload = false
  override var reloadsOnAppearance: Bool { false }
  init(app: QFAppSession) { super.init(app: app, title: app.text("食材组合推荐", "Ingredient combinations")) }
  required init?(coder: NSCoder) { nil }
  deinit { optionsTask?.cancel() }
  override func viewDidLoad() {
    super.viewDidLoad(); view.accessibilityIdentifier = "ingredient.combinations"
    tabs = categoryTabs([app.text("家里已有", "At home"), app.text("自由选择", "Choose freely")]) { [weak self] in self?.changeMode($0) }
    tabs.selectedSegmentTintColor = QFUI.paleGreen; tabs.backgroundColor = QFUI.surface
    let add = QFTabUI.button("＋ " + app.text("添加", "Add"), color: QFUI.orange) { [weak self] in self?.chooseIngredient() }; add.accessibilityIdentifier = "combination.add"
    addButton = add
    let selected = QFTabUI.stack([count, UIView(), add], axis: .horizontal, spacing: 8); selected.alignment = .center
    let chipScroll = UIScrollView(); chipScroll.showsVerticalScrollIndicator = true
    chipScroll.addSubview(chips); chips.snp.makeConstraints { $0.edges.equalTo(chipScroll.contentLayoutGuide); $0.width.equalTo(chipScroll.frameLayoutGuide) }
    chipScroll.snp.makeConstraints { $0.height.equalTo(44) }
    tasteButton = filterButton { [weak self] in self?.chooseTaste() }; timeButton = filterButton { [weak self] in self?.chooseTime() }
    let filters = QFTabUI.stack([tasteButton!, timeButton!], axis: .horizontal, spacing: 12); filters.distribution = .fillEqually
    let heading = QFTabUI.stack([recommendationHeading, UIView(), resultCount], axis: .horizontal, spacing: 8); heading.alignment = .center
    [tabs!, selected, chipScroll, filters, heading].forEach(controls.addArrangedSubview)
    installList(resultScroll, controls: controls)
    resultScroll.addSubview(results); results.axis = .vertical; results.spacing = 14
    results.snp.makeConstraints { $0.edges.equalTo(resultScroll.contentLayoutGuide).inset(UIEdgeInsets(top: 0, left: 20, bottom: 20, right: 20)); $0.width.equalTo(resultScroll.frameLayoutGuide).offset(-40) }
    setReloadAction { [weak self] in self?.load(force: true) }
    app.$planningScope.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.clearContext() }.store(in: &cancellables)
    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
      guard let self else { return }; self.optionsTask?.cancel(); self.options = nil; self.taste = nil
      self.updateHeading(self.app.text("食材组合推荐", "Ingredient combinations")); self.clearContext()
    }.store(in: &cancellables)
    renderControls(); render()
  }
  override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); if needsReload { needsReload = false; load(force: true) } }
  private var selectedIDs: [String] { selections[selectedMode].map(\.id).sorted() }
  private func clearContext() { selections = [[], []]; resetResults() }
  private func changeMode(_ mode: Int) { guard selectedMode != mode else { return }; selectedMode = mode; resetResults() }
  private func filterButton(_ action: @escaping () -> Void) -> UIButton {
    let button = QFTabUI.button("", size: 14, color: QFUI.text, background: QFUI.surface, action: action)
    button.titleLabel?.numberOfLines = 2; button.layer.borderWidth = 1; button.layer.borderColor = QFUI.border.cgColor; button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }; return button
  }
  private func renderControls() {
    addButton.setTitle("＋ " + app.text("添加", "Add"), for: .normal)
    recommendationHeading.text = app.text("推荐搭配", "Suggested combinations")
    tabs.setTitle(app.text("家里已有", "At home"), forSegmentAt: 0); tabs.setTitle(app.text("自由选择", "Choose freely"), forSegmentAt: 1)
    count.text = app.format("已选 %d 项", "%d selected", selections[selectedMode].count)
    tasteButton.setTitle(app.text("口味", "Taste") + "  " + (taste?.name ?? app.text("不限", "Any")) + "  ⌄", for: .normal)
    timeButton.setTitle(app.text("时间", "Time") + "  " + (maxMinutes.map { app.format("%d 分钟内", "Within %d min", $0) } ?? app.text("不限", "Any")) + "  ⌄", for: .normal)
    QFTabUI.clear(chips)
    let selected = selections[selectedMode]
    for start in stride(from: 0, to: selected.count, by: 3) {
      let row = QFTabUI.stack([], axis: .horizontal, spacing: 8); row.distribution = .fillEqually
      for item in selected[start..<min(start + 3, selected.count)] {
        let chip = QFTabUI.button(item.title + "  ×", size: 14, color: QFUI.green, background: QFUI.paleGreen) { [weak self] in
          guard let self else { return }; self.selections[self.selectedMode].removeAll { $0.id == item.id }; self.resetResults()
        }
        chip.titleLabel?.numberOfLines = 2; chip.accessibilityLabel = app.format("移除%@", "Remove %@", item.title); chip.snp.makeConstraints { $0.height.greaterThanOrEqualTo(40) }; row.addArrangedSubview(chip)
      }
      while row.arrangedSubviews.count < 3 { row.addArrangedSubview(UIView()) }; chips.addArrangedSubview(row)
    }
  }
  private func chooseIngredient() {
    guard selections[selectedMode].count < 40 else { message(app.text("最多选择 40 种食材", "Choose up to 40 ingredients"), error: true); return }
    let mode = selectedMode, household = app.planningHouseholdID
    open(QFIngredientCatalogViewController(app: app, inventoryOnly: mode == 0) { [weak self] item in
      guard let self, mode == self.selectedMode, household == self.app.planningHouseholdID else { return }
      if !self.selections[mode].contains(where: { $0.id == item.id }) { self.selections[mode].append(item) }; self.resetResults()
    })
  }
  private func chooseTime() {
    let sheet = UIAlertController(title: app.text("时间", "Time"), message: nil, preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: app.text("不限", "Any"), style: .default) { [weak self] _ in self?.maxMinutes = nil; self?.resetResults() })
    for value in [15, 30, 60] { sheet.addAction(UIAlertAction(title: app.format("%d 分钟内", "Within %d min", value), style: .default) { [weak self] _ in self?.maxMinutes = value; self?.resetResults() }) }
    showSheet(sheet, from: timeButton)
  }
  private func chooseTaste() {
    if let options { showTastes(options.tastes); return }
    guard optionsTask == nil else { return }; let language = app.interfaceLanguage
    optionsTask = Task { [weak self] in
      guard let self else { return }; defer { self.optionsTask = nil }
      do {
        let options: QFRecipeHomeOptions = try await self.app.publicContentRequest(path: "home/recipe-options")
        try Task.checkCancellation(); guard language == self.app.interfaceLanguage, self.view.window != nil, self.navigationController?.topViewController === self else { return }
        self.options = options; self.showTastes(options.tastes)
      } catch is CancellationError {} catch { self.message(Self.errorText(error, app: self.app), error: true) }
    }
  }
  private func showTastes(_ values: [QFRecipeOption]) {
    let sheet = UIAlertController(title: app.text("口味", "Taste"), message: nil, preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: app.text("不限", "Any"), style: .default) { [weak self] _ in self?.taste = nil; self?.resetResults() })
    for value in values { sheet.addAction(UIAlertAction(title: value.name, style: .default) { [weak self] _ in self?.taste = value; self?.resetResults() }) }; showSheet(sheet, from: tasteButton)
  }
  private func showSheet(_ sheet: UIAlertController, from button: UIView) {
    sheet.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel)); sheet.popoverPresentationController?.sourceView = button; sheet.popoverPresentationController?.sourceRect = button.bounds; present(sheet, animated: true)
  }
  private func resetResults() { items = []; total = 0; nextPage = 0; hasMore = false; loaded = false; errorMessage = nil; renderControls(); render(); load() }
  private func load(append: Bool = false, force: Bool = false) {
    let ids = selectedIDs, selectedTaste = taste?.id, minutes = maxMinutes, language = app.interfaceLanguage, household = app.planningHouseholdID
    let page = append ? nextPage : 0
    execute(reloadOnFailure: true, loadingMore: append, showsInitialReadProgress: false) { [self] in
      guard !ids.isEmpty else { loaded = false; render(); return }
      var query = ["ingredientIds": ids.joined(separator: ","), "page": String(page)]; query["householdId"] = household; query["taste"] = selectedTaste; query["maxMinutes"] = minutes.map(String.init)
      do {
        let response: QFContentPage<QFIngredientCombination> = try await QFContentLoadingContext.$forceRefresh.withValue(force) { try await app.contentRequest(path: "me/ingredient-combinations", query: query) }
        try Task.checkCancellation(); guard ids == selectedIDs, selectedTaste == taste?.id, minutes == maxMinutes, language == app.interfaceLanguage, household == app.planningHouseholdID else { throw CancellationError() }
        if !append { items = [] }; var known = Set(items.map(\.recipeId)); let fresh = response.items.filter { known.insert($0.recipeId).inserted }; items.append(contentsOf: fresh)
        total = response.total; hasMore = !fresh.isEmpty && items.count < total; nextPage = page + 1; loaded = true; errorMessage = nil; render()
      } catch is CancellationError { throw CancellationError() }
      catch { if append { throw error }; errorMessage = Self.errorText(error, app: app); render() }
    }
  }
  private func render() {
    resultCount.text = loaded ? app.format("%d 种搭配", "%d combinations", total) : ""
    results.beginUpdates()
    if items.isEmpty { results.row("state", version: "\(loaded)|\(selectedIDs)|\(errorMessage ?? "")|\(app.interfaceLanguage)") { [self] in
      QFTabUI.empty(errorMessage != nil ? app.text("暂时无法加载", "Unable to load") : selectedIDs.isEmpty ? app.text("先选择食材", "Choose ingredients first") : loaded ? app.text("暂无符合条件的搭配", "No matching combinations") : app.text("正在加载", "Loading"), detail: errorMessage ?? "")
    } }
    for item in items { results.row(item.recipeId, value: item) { [weak self] in self?.card(item) ?? UIView() } }
    results.endUpdates(); setLoadMoreAction(hasMore ? { [weak self] in self?.load(append: true) } : nil)
  }
  private func card(_ item: QFIngredientCombination) -> UIView {
    let icons = QFTabUI.stack([], axis: .horizontal, spacing: 6)
    for material in item.materials.filter({ $0.ingredientId.map(selectedIDs.contains) == true }).prefix(2) { icons.addArrangedSubview(QFInventoryArtwork.make(ingredientID: material.ingredientId ?? "", category: material.categoryCode, iconKey: material.iconKey)) }
    let time = item.minutes.map { app.format("%d分钟", "%d min", $0) } ?? app.text("时间未标注", "Time not specified")
    let heading = QFTabUI.stack([icons, QFTabUI.stack([QFTabUI.label(item.title, size: 20, weight: .semibold, lines: 0), QFTabUI.label(time, size: 13, color: QFUI.secondary)], spacing: 6)], axis: .horizontal, spacing: 12); heading.alignment = .center
    let body = QFTabUI.stack([heading], spacing: 12)
    for material in item.materials {
      let amount = material.quantityText ?? ([material.quantityMin, material.quantityMax != material.quantityMin ? material.quantityMax : nil].compactMap { $0 }.joined(separator: "–") + (material.unitCode.map { " " + $0 } ?? ""))
      let label: String, color: UIColor
      switch material.availability {
      case "AVAILABLE": label = app.text("已备", "Available"); color = QFUI.green
      case "SHORT": label = app.text("还需", "Still needed") + " " + (material.missingQuantity ?? "") + " " + (material.unitCode ?? ""); color = QFUI.orange
      default: label = app.text("用量待确认", "Quantity needs confirmation"); color = QFUI.secondary
      }
      body.addArrangedSubview(QFTabUI.label(material.name + " " + amount + " · " + label, size: 14, color: color, lines: 0))
    }
    let detail = QFTabUI.button(app.text("查看做法", "View recipe"), color: QFUI.text, background: QFUI.surface) { [weak self] in
      guard let self else { return }; self.open(QFCatalogDetailViewController.make(app: self.app, type: "RECIPE", id: item.recipeId))
    }; detail.layer.borderWidth = 1; detail.layer.borderColor = QFUI.border.cgColor
    let planned = !item.plans.isEmpty
    let plan = QFTabUI.button(planned ? app.text("已加入计划", "Planned") : app.text("加入计划", "Add to plan"), color: planned ? QFUI.green : QFUI.onPrimary, background: planned ? QFUI.paleGreen : QFUI.primary) { [weak self] in self?.changePlan(item) }; plan.accessibilityIdentifier = "combination.plan." + item.recipeId
    for button in [detail,plan] { button.titleLabel?.numberOfLines = 2; button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(48) } }
    let actions = QFTabUI.stack([detail, plan], axis: .horizontal, spacing: 12); actions.distribution = .fillEqually; body.addArrangedSubview(actions)
    return QFTabUI.card(body, padding: 16)
  }
  private func changePlan(_ item: QFIngredientCombination) {
    if item.plans.isEmpty { open(QFAddRecipePlanViewController(app: app, recipeID: item.recipeId) { [weak self] _ in self?.load(force: true); self?.onChanged?() }); return }
    let sheet = UIAlertController(title: app.text("选择要取消的计划", "Choose a plan to remove"), message: nil, preferredStyle: .actionSheet)
    for plan in item.plans {
      let meal = QFCookingMeal(rawValue: plan.meal)?.title(app: app) ?? plan.meal
      sheet.addAction(UIAlertAction(title: plan.date + " · " + meal, style: .destructive) { [weak self] _ in
        guard let self else { return }; self.execute { [self] in
          try await self.app.deletePlannedMeal(plan.id, expectedRevision: plan.revision)
          if let index = self.items.firstIndex(where: { $0.recipeId == item.recipeId }) { self.items[index].plans.removeAll { $0.id == plan.id } }; self.render(); self.onChanged?()
        }
      })
    }; showSheet(sheet, from: resultScroll)
  }
}
