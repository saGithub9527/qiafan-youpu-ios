import Foundation
import Combine
import SnapKit
import UIKit

@MainActor
final class QFPlanViewController: QFPageViewController {
#if DEBUG
  var debugDisplayedPlanIDs: [String] { daySnapshot?.slots.flatMap(\.items).map(\.id) ?? [] }
  var debugDisplayedPlanDate: String? { daySnapshot?.date }
#endif
  private let calendar: Calendar
  private var displayedMonth: Date
  private var selectedDate: Date
  private let monthLabel = QFTabUI.label("", size: 20, weight: .semibold)
  private let dayLabel = QFTabUI.label("", size: 12, color: QFUI.secondary, lines: 0)
  private let calendarRows = QFTabUI.stack([], spacing: 0)
  private let meals = QFTabUI.stack([], spacing: 12)
  private let summary = QFTabUI.stack([], axis: .horizontal, spacing: 10)
  private let headingLabel = QFTabUI.label("", size: 29, weight: .semibold, lines: 0)
  private let recordsButton = QFTabUI.button("", size: 14, weight: .medium, color: QFUI.orange) {}
  private let dayTitleLabel = QFTabUI.label("", size: 21, weight: .semibold)
  private let previousButton = QFTabUI.iconButton("chevron.left", label: "", size: 19) {}
  private let nextButton = QFTabUI.iconButton("chevron.right", label: "", size: 19) {}
  private let weekdayLabels = (0..<7).map { _ in QFTabUI.label("", size: 14, color: QFUI.secondary) }
  private let legendText = QFTabUI.label("", size: 11, color: QFUI.secondary, lines: 0)
  private let todayButton = QFTabUI.button("", size: 12, weight: .medium, color: QFUI.orange) {}
  private let createButton = QFTabUI.button("", size: 18, weight: .medium, color: QFUI.onPrimary, background: QFUI.primary) {}
  private let prepareButton = QFTabUI.button("", size: 18, weight: .medium, background: QFUI.surface) {}
  private let refreshControl = UIRefreshControl()
  private var calendarSnapshot: QFPlanCalendar?
  private var daySnapshot: QFPlanDay?
  private var availabilitySnapshot: QFPlanAvailability?
  private var availabilityLabels: [String: UILabel] = [:]
  private var availabilityTask: Task<Void, Never>?
  private var availabilityRequestID = UUID()
  private var expenseSnapshot: QFPreparationExpenses?
  private var expenseTask: Task<Void, Never>?
  private var expenseRequestID = UUID()
  private var loadTask: Task<Void, Never>?
  private var loadRequestID = UUID()
  private var firstAppearance = true
  private var assistantDayRoute: (day: String, binding: QFAgentScope)?
  private var remoteRouteTask: Task<Void, Never>?
  private var legend: UIStackView!
  private var compact = false
  private var expandedMeals = Set<String>()
  private var mealMutationTask: Task<Void, Never>?
  private let mutationHUD = QFOperationHUD()

  override init(app: QFAppSession) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "zh_CN")
    calendar.timeZone = .current
    calendar.firstWeekday = 2
    let today = calendar.startOfDay(for: Date())
    self.calendar = calendar
    selectedDate = today
    displayedMonth =
      calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
    super.init(app: app)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit {
    loadTask?.cancel()
    expenseTask?.cancel()
    remoteRouteTask?.cancel()
    mealMutationTask?.cancel()
    availabilityTask?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "plan.screen"
    headingLabel.accessibilityTraits.insert(.header)
    recordsButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      guard self.app.user != nil else {
        QFOperationHUD.toast(self.app.text("请先登录。", "Sign in first."), in: self.view)
        return
      }
      self.qfPush(QFPlanCookingHistoryViewController(app: self.app))
    }, for: .touchUpInside)
    recordsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    recordsButton.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
    let header = QFTabUI.stack([headingLabel, UIView(), recordsButton], axis: .horizontal, spacing: 8)
    header.alignment = .center
    contentStack.addArrangedSubview(header)
    contentStack.addArrangedSubview(makeCalendar())
    summary.distribution = .fillEqually
    contentStack.addArrangedSubview(QFTabUI.card(summary, padding: 14, background: QFUI.paleGreen))
    dayTitleLabel.accessibilityTraits.insert(.header)
    dayLabel.textAlignment = .right
    let dayHeading = QFTabUI.stack([dayTitleLabel, UIView(), dayLabel], axis: .horizontal, spacing: 8)
    dayHeading.alignment = .firstBaseline
    contentStack.addArrangedSubview(dayHeading)
    contentStack.addArrangedSubview(meals)
    refreshControl.addAction(UIAction { [weak self] _ in self?.loadPlan(force: true) }, for: .valueChanged)
    scrollView.refreshControl = refreshControl
    installActions()
    applyLanguage()
    refreshCalendar()
    refreshMeals()
    loadPlan()
    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] _ in
      guard let self else { return }
      self.calendarSnapshot = nil
      self.daySnapshot = nil
      self.expenseSnapshot = nil
      self.applyLanguage()
      self.refreshCalendar()
      self.refreshMeals()
      self.loadPlan(force: true)
    }.store(in: &cancellables)
    app.$user.dropFirst().map { $0?.userId }.removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] _ in
      self?.calendarSnapshot = nil
      self?.daySnapshot = nil
      self?.refreshCalendar()
      self?.refreshMeals()
      self?.loadPlan(force: true)
    }.store(in: &cancellables)
    app.$planningScope.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] _ in
      guard let self else { return }
      self.calendarSnapshot = nil
      self.daySnapshot = nil
      self.expenseSnapshot = nil
      self.applyLanguage()
      self.refreshCalendar()
      self.refreshMeals()
      self.loadPlan(force: true)
    }.store(in: &cancellables)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if let route = assistantDayRoute {
      assistantDayRoute = nil
      if route.binding == QFAssistantAgent.scope(app) { _ = openAssistantDay(route.day) }
    }
    if firstAppearance {
      firstAppearance = false
    } else if loadTask == nil {
      // Mutations invalidate the affected cache; ordinary returns reuse valid responses.
      loadPlan()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let next = view.bounds.width < 360
    guard next != compact else { return }
    compact = next
    legend.axis = compact ? .vertical : .horizontal
  }

  @discardableResult
  func openAssistantDay(_ day: String) -> Bool {
    guard let date = planDate(day) else { return false }
    if let navigationController, navigationController.topViewController !== self {
      assistantDayRoute = (day, QFAssistantAgent.scope(app)); return false
    }
    loadViewIfNeeded()
    selectedDate = date
    displayedMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    refreshCalendar(); refreshMeals(); loadPlan(force: true)
    return true
  }

  func openRemoteReminder(plannedMealID: String) {
    remoteRouteTask?.cancel()
    let userID = app.user?.userId
    remoteRouteTask = Task { [weak self] in
      guard let self else { return }
      do {
        let meal = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
          try await self.app.plannedMeal(plannedMealID)
        }
        try Task.checkCancellation()
        guard self.app.user?.userId == userID else { return }
        let householdName: String?
        if let householdID = meal.householdId {
          let households = try? await self.app.households()
          householdName = households?.first { $0.id == householdID }?.name
        } else {
          householdName = nil
        }
        try Task.checkCancellation()
        guard self.app.user?.userId == userID, let date = self.planDate(meal.date) else { return }
        let scopeChanged = self.app.planningHouseholdID != meal.householdId
        self.selectedDate = date
        self.displayedMonth =
          self.calendar.date(
            from: self.calendar.dateComponents([.year, .month], from: date)) ?? date
        self.refreshCalendar()
        self.refreshMeals()
        if scopeChanged {
          self.app.setPlanningScope(
            householdID: meal.householdId, householdName: householdName)
        } else {
          self.loadPlan(force: true)
        }
      } catch is CancellationError {
      } catch {
        QFOperationHUD.toast(
          self.app.text("未能打开这条计划提醒。", "Could not open this plan reminder."), in: self.view)
      }
    }
  }

  private func makeCalendar() -> UIView {
    previousButton.addAction(UIAction { [weak self] _ in self?.moveMonth(-1) }, for: .touchUpInside)
    nextButton.addAction(UIAction { [weak self] _ in self?.moveMonth(1) }, for: .touchUpInside)
    monthLabel.textAlignment = .center
    monthLabel.adjustsFontSizeToFitWidth = true
    monthLabel.minimumScaleFactor = 0.8
    monthLabel.accessibilityTraits.insert(.header)
    let monthHeader = QFTabUI.stack([previousButton, monthLabel, nextButton], axis: .horizontal, spacing: 0)
    let weekdays = QFTabUI.stack(
      weekdayLabels.map { label -> UILabel in
        label.textAlignment = .center
        return label
      }, axis: .horizontal, spacing: 0)
    weekdays.distribution = .fillEqually
    calendarRows.accessibilityIdentifier = "plan.calendar"
    todayButton.addAction(UIAction { [weak self] _ in self?.returnToToday() }, for: .touchUpInside)
    todayButton.contentHorizontalAlignment = .right
    todayButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    todayButton.snp.makeConstraints { $0.height.greaterThanOrEqualTo(36) }
    legend = QFTabUI.stack([legendText, todayButton], axis: .horizontal, spacing: 8)
    return QFTabUI.card(
      QFTabUI.stack([monthHeader, weekdays, calendarRows, legend], spacing: 8), padding: 12,
      border: true)
  }

  private func refreshCalendar() {
    let monthFormatter = DateFormatter()
    monthFormatter.calendar = calendar
    monthFormatter.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    monthFormatter.timeZone = calendar.timeZone
    monthFormatter.setLocalizedDateFormatFromTemplate("yMMMM")
    monthLabel.text = monthFormatter.string(from: displayedMonth)
    QFTabUI.clear(calendarRows)
    let weekday = calendar.component(.weekday, from: displayedMonth)
    let leading = (weekday - calendar.firstWeekday + 7) % 7
    let count = calendar.range(of: .day, in: .month, for: displayedMonth)?.count ?? 0
    let slots = ((leading + count + 6) / 7) * 7
    for week in stride(from: 0, to: slots, by: 7) {
      let row = QFTabUI.stack([], axis: .horizontal, spacing: 0)
      row.distribution = .fillEqually
      for slot in week..<(week + 7) {
        let offset = slot - leading
        let cell = UIView()
        if (0..<count).contains(offset),
          let date = calendar.date(byAdding: .day, value: offset, to: displayedMonth)
        {
          let selected = calendar.isDate(date, inSameDayAs: selectedDate)
          let day = calendar.component(.day, from: date)
          let month = calendar.component(.month, from: date)
          let button = QFTabUI.button(
            "\(day)", size: 16, weight: .medium, color: selected ? QFUI.onPrimary : QFUI.text,
            background: selected ? QFUI.orange : .clear
          ) { [weak self] in
            self?.selectedDate = date
            self?.refreshCalendar()
            self?.refreshMeals()
            self?.loadPlan()
          }
          button.contentEdgeInsets = .zero
          button.layer.cornerRadius = 10
          button.isSelected = selected
          button.setTitleColor(selected ? QFUI.onPrimary : QFUI.text, for: .selected)
          button.titleLabel?.adjustsFontSizeToFitWidth = true
          button.titleLabel?.minimumScaleFactor = 0.8
          button.accessibilityLabel = app.format("%d月%d日", "%d/%d", month, day)
          cell.addSubview(button)
          button.snp.makeConstraints {
            $0.leading.trailing.equalToSuperview().inset(3)
            $0.top.bottom.equalToSuperview().inset(1)
          }
          if let state = calendarState(for: date), state.total > 0 {
            let marker = UIView()
            marker.backgroundColor = state.completed == state.total ? QFUI.green : QFUI.primary
            marker.layer.cornerRadius = 2
            marker.isUserInteractionEnabled = false
            cell.addSubview(marker)
            marker.snp.makeConstraints {
              $0.centerX.equalToSuperview()
              $0.bottom.equalToSuperview().inset(2)
              $0.size.equalTo(4)
            }
          }
        }
        row.addArrangedSubview(cell)
      }
      row.snp.makeConstraints { $0.height.equalTo(32) }
      calendarRows.addArrangedSubview(row)
    }
  }

  private func refreshMeals() {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("MMMMdEEEE")
    let scope = app.planningScope.householdName ?? app.text("个人", "Personal")
    dayLabel.text = "\(scope) · \(formatter.string(from: selectedDate))"
    refreshSummary()
    let slots = daySnapshot?.date == dayKey(selectedDate) ? daySnapshot?.slots ?? [] : []
    QFTabUI.clear(meals)
    availabilityLabels = [:]
    if app.user != nil, daySnapshot?.date == dayKey(selectedDate) {
      for meal in ["BREAKFAST", "LUNCH", "DINNER"] {
        let slot = slots.first { $0.meal == meal } ?? QFPlanSlot(meal: meal, revision: 0, items: [])
        meals.addArrangedSubview(makeMeal(slot))
      }
      slots.filter { !["BREAKFAST", "LUNCH", "DINNER"].contains($0.meal) && !$0.items.isEmpty }.forEach { meals.addArrangedSubview(makeMeal($0)) }
    } else {
      let detail = app.user == nil
        ? app.text("登录后查看和制定饮食计划", "Sign in to view and create meal plans.")
        : app.text("留一点期待，给下一餐", "Leave something to look forward to at your next meal.")
      meals.addArrangedSubview(
        QFTabUI.empty(app.text("当天还没有安排", "Nothing planned for this day"), detail: detail))
    }
  }

  private func refreshSummary() {
    QFTabUI.clear(summary)
    let slots = daySnapshot?.date == dayKey(selectedDate) ? daySnapshot?.slots ?? [] : []
    let total = slots.reduce(0) { $0 + $1.items.filter { !$0.skipped }.count }
    let completed = slots.reduce(0) { result, slot in
      result + slot.items.filter(\.completed).count
    }
    let values = [
      app.format("%d / %d 道", "%d / %d dishes", completed, total),
      expenseText(expenseSnapshot?.consumptionTotals, date: dayKey(selectedDate)),
      expenseText(expenseSnapshot?.purchaseTotals, date: dayKey(selectedDate)),
    ]
    for (index, title) in [app.text("已完成", "Completed"), app.text("消耗成本", "Cooking cost"), app.text("采购支出", "Shopping spend")].enumerated() {
      let value = QFTabUI.label(values[index], size: 22, weight: .semibold)
      value.adjustsFontSizeToFitWidth = true
      value.minimumScaleFactor = 0.7
      let content = QFTabUI.stack([QFTabUI.label(title, size: 12, color: QFUI.green, lines: 0), value], spacing: 4)
      if index == 0 { summary.addArrangedSubview(content) }
      else {
        let button = QFTabUI.button("") { [weak self] in self?.openExpenses(costOnly: index == 1) }
        content.isUserInteractionEnabled = false; button.addSubview(content)
        content.snp.makeConstraints { $0.edges.equalToSuperview() }
        button.accessibilityLabel = title + " " + values[index]
        button.accessibilityIdentifier = index == 1 ? "plan.summary.cost" : "plan.summary.purchase"
        summary.addArrangedSubview(button)
      }
    }
  }

  private func makeMeal(_ slot: QFPlanSlot) -> UIView {
    let mealTitle = QFCookingMeal(rawValue: slot.meal)?.title(app: app) ?? slot.meal
    let more = QFTabUI.iconButton(
      "ellipsis", label: app.format("调整%@计划", "Edit %@ plan", mealTitle), size: 18
    ) { [weak self] in
      self?.showMealActions(slot)
    }
    more.isHidden = slot.items.isEmpty
    let doneCount = slot.items.filter(\.completed).count
    let heading = QFTabUI.stack(
      [
        QFTabUI.label(mealTitle, size: 19, weight: .semibold), UIView(),
        QFTabUI.label(
          app.format("%d 道 · %d 道已完成", "%d dishes · %d completed", slot.items.count, doneCount),
          size: 12, color: doneCount == slot.items.count ? QFUI.green : QFUI.secondary), more,
      ], axis: .horizontal, spacing: 8)
    heading.alignment = .center
    let body = QFTabUI.stack([heading], spacing: 12)
    let expansionKey = (app.user?.userId ?? "") + "|" + (app.planningHouseholdID ?? "personal") + "|" + dayKey(selectedDate) + "|" + slot.meal
    if slot.items.isEmpty {
      let arrange = QFTabUI.button(app.text("去安排", "Plan this meal"), size: 14, color: QFUI.orange, background: QFUI.tint) { [weak self] in
        guard let self else { return }; self.qfPush(QFCreatePlanViewController(app: self.app, initialDate: self.selectedDate) { [weak self] in self?.loadPlan(force: true) })
      }
      arrange.accessibilityIdentifier = "plan.empty." + slot.meal
      arrange.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
      body.addArrangedSubview(arrange)
    }
    let visibleDishes = expandedMeals.contains(expansionKey) ? slot.items : Array(slot.items.prefix(3))
    for dish in visibleDishes {
      let image = QFContentImageView()
      image.contentMode = .scaleAspectFill
      image.clipsToBounds = true
      image.layer.cornerRadius = 12
      image.snp.makeConstraints { $0.size.equalTo(48) }
      image.load(dish.mediaId, app: app)
      let availableTitle = dish.title?.trimmingCharacters(in: .whitespacesAndNewlines)
      let title = dish.contentAvailable
        ? (availableTitle?.isEmpty == false
          ? availableTitle! : app.text("未命名菜谱", "Untitled recipe"))
        : app.text("当前语言内容不可用", "Content unavailable in this language")
      let details = QFTabUI.stack(
        [
          QFTabUI.label(title, size: 16, weight: .semibold, lines: 0),
          QFTabUI.label(
            app.format("%d 份", "%d servings", dish.servings), size: 12,
            color: QFUI.secondary, lines: 0),
        ], spacing: 5)
      if !dish.completed && !dish.skipped && dish.contentAvailable {
        let shortage = QFTabUI.label("", size: 12, color: QFUI.orange, lines: 0)
        shortage.accessibilityIdentifier = "plan.dish.shortage.\(dish.id)"
        details.addArrangedSubview(shortage)
        availabilityLabels[dish.id] = shortage
        updateAvailabilityLabel(shortage, for: dish)
      }
      let done = QFTabUI.button(
        dish.completed ? app.text("✓ 已做", "✓ Done") : dish.skipped ? app.text("已跳过", "Skipped") : app.text("做菜打卡", "Mark cooked"), size: 12, weight: .medium,
        color: dish.completed ? QFUI.green : QFUI.orange,
        background: dish.completed ? QFUI.successBackground : QFUI.tint
      ) { [weak self] in
        guard let self else { return }
        if dish.completed {
          self.qfPush(QFPlanCookingHistoryViewController(app: self.app, date: self.selectedDate))
        } else if dish.skipped {
          self.showDishActions([dish])
        } else {
          self.markCooked(dish)
        }
      }
      done.contentEdgeInsets = .zero
      done.layer.cornerRadius = 15
      done.snp.makeConstraints {
        $0.width.equalTo(64)
        $0.height.equalTo(30)
      }
      let row = QFTabUI.stack([image, details, done], axis: .horizontal, spacing: 10)
      row.alignment = .center
      let tap = UITapGestureRecognizer(target: self, action: #selector(dishActionsTapped(_:)))
      details.isUserInteractionEnabled = true
      details.accessibilityIdentifier = "plan.dish.\(dish.id)"
      details.addGestureRecognizer(tap)
      body.addArrangedSubview(row)
    }
    if slot.items.count > 3 {
      let expanded = expandedMeals.contains(expansionKey)
      let toggle = QFTabUI.button(expanded ? app.text("收起", "Collapse") : app.format("展开剩余 %d 道", "Show %d more dishes", slot.items.count - 3), size: 14, color: QFUI.orange) { [weak self] in
        guard let self else { return }
        if expanded { self.expandedMeals.remove(expansionKey) } else { self.expandedMeals.insert(expansionKey) }
        self.refreshMeals()
      }
      toggle.accessibilityIdentifier = "plan.expand." + slot.meal
      toggle.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }; body.addArrangedSubview(toggle)
    }
    return QFTabUI.card(body, padding: 14, border: true)
  }

  private func markCooked(_ meal: QFPlannedMeal) {
    guard meal.date <= QFContentDate.day(Date()) else {
      QFOperationHUD.toast(
        app.text("未来计划还不能打卡。", "A future meal cannot be marked as cooked yet."), in: view)
      return
    }
    qfPush(QFCompleteMealViewController(app: app, plan: meal) { [weak self] in
      self?.loadPlan(force: true)
    })
  }

  private func installActions() {
    createButton.addAction(UIAction { [weak self] _ in
      self?.showCreatePlanOptions()
    }, for: .touchUpInside)
    createButton.accessibilityIdentifier = "plan.create"
    prepareButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      guard self.app.user != nil else {
        QFOperationHUD.toast(
          self.app.text("请先登录。", "Sign in first."), in: self.view)
        return
      }
      self.qfPush(
        QFIngredientViewController(
          app: self.app, preparationDates: (self.dayKey(self.selectedDate), self.dayKey(self.selectedDate))))
    }, for: .touchUpInside)
    prepareButton.layer.borderWidth = 1
    prepareButton.layer.borderColor = QFUI.border.cgColor
    let bar = QFTabUI.stack([createButton, prepareButton], axis: .horizontal, spacing: 10)
    bar.distribution = .fillEqually
    view.addSubview(bar)
    bar.snp.makeConstraints {
      $0.centerX.equalTo(view.safeAreaLayoutGuide)
      $0.leading.greaterThanOrEqualTo(view.safeAreaLayoutGuide).offset(20)
      $0.trailing.lessThanOrEqualTo(view.safeAreaLayoutGuide).inset(20)
      $0.width.lessThanOrEqualTo(720)
      $0.width.equalTo(view.safeAreaLayoutGuide).offset(-40).priority(750)
      $0.bottom.equalTo(view.safeAreaLayoutGuide).inset(7)
      $0.height.equalTo(49)
    }
    scrollView.snp.remakeConstraints {
      $0.top.leading.trailing.equalTo(view.safeAreaLayoutGuide)
      $0.bottom.equalTo(bar.snp.top).offset(-6)
    }
  }

  private func applyLanguage() {
    headingLabel.text = app.text("饮食计划", "Meal plan")
    recordsButton.setTitle(app.text("做菜记录", "Cooking history"), for: .normal)
    dayTitleLabel.text = app.text("当日计划", "Plan for the day")
    previousButton.accessibilityLabel = app.text("上个月", "Previous month")
    nextButton.accessibilityLabel = app.text("下个月", "Next month")
    let formatter = DateFormatter()
    formatter.locale = Locale(
      identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    let sundayFirst = formatter.shortStandaloneWeekdaySymbols ?? formatter.shortWeekdaySymbols ?? []
    let weekdayNames = sundayFirst.count == 7
      ? Array(sundayFirst[1...]) + [sundayFirst[0]]
      : ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    for (label, value) in zip(weekdayLabels, weekdayNames) { label.text = value }
    legendText.text = app.text("• 有做菜记录     ◦ 有待做计划", "• Cooking history     ◦ Planned")
    todayButton.setTitle(app.text("回到今天", "Today"), for: .normal)
    createButton.setTitle(app.text("制定计划", "Create plan"), for: .normal)
    prepareButton.setTitle(app.text("备菜", "Prep"), for: .normal)
  }

  private func moveMonth(_ offset: Int) {
    if let month = calendar.date(byAdding: .month, value: offset, to: displayedMonth) {
      displayedMonth = month
      selectedDate = month
      refreshCalendar()
      refreshMeals()
      loadPlan()
    }
  }
  private func returnToToday() {
    selectedDate = calendar.startOfDay(for: Date())
    displayedMonth =
      calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate))
      ?? selectedDate
    refreshCalendar()
    refreshMeals()
    loadPlan()
  }

  private func chooseRecipeForPlan() {
    guard app.user != nil else {
      QFOperationHUD.toast(app.text("请先登录。", "Sign in first."), in: view)
      return
    }
    qfPush(QFCreatePlanViewController(app: app, initialDate: selectedDate) { [weak self] in
      self?.loadPlan(force: true)
    })
  }

  private func showCreatePlanOptions() {
    guard app.user != nil else {
      QFOperationHUD.toast(app.text("请先登录。", "Sign in first."), in: view)
      return
    }
    let sheet = UIAlertController(
      title: app.text("制定计划", "Create plan"), message: nil,
      preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: app.text("手动添加菜谱", "Add recipe manually"), style: .default) {
      [weak self] _ in self?.chooseRecipeForPlan()
    })
    sheet.addAction(UIAlertAction(title: app.text("AI 生成周计划", "Generate weekly plan with AI"), style: .default) {
      [weak self] _ in
      guard let self else { return }
      self.qfPush(
        QFWeeklyPlanViewController(app: self.app, initialDate: self.selectedDate) { [weak self] in
          self?.loadPlan(force: true)
        })
    })
    sheet.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = createButton
      popover.sourceRect = createButton.bounds
    }
    present(sheet, animated: true)
  }

  @objc private func dishActionsTapped(_ gesture: UITapGestureRecognizer) {
    guard let id = gesture.view?.accessibilityIdentifier?.replacingOccurrences(of: "plan.dish.", with: ""),
      let dish = daySnapshot?.slots.flatMap(\.items).first(where: { $0.id == id }) else { return }
    showDishActions([dish])
  }

  private func showMealActions(_ slot: QFPlanSlot) { showDishActions(slot.items) }

  private func showDishActions(_ items: [QFPlannedMeal]) {
    guard !items.isEmpty, mealMutationTask == nil, presentedViewController == nil else { return }
    let userID = app.user?.userId, householdID = app.planningHouseholdID
    present(QFMealActionsViewController(app: app, items: items) { [weak self] item, action in
      guard let self, self.app.user?.userId == userID,
        self.app.planningHouseholdID == householdID else { return }
      switch action {
      case .replace:
        guard !item.completed else { return }
        let existing = Set(self.daySnapshot?.slots.first { $0.meal == item.meal }?.items.map(\.recipeId) ?? [])
        self.qfPush(QFPlanRecipePickerViewController(app: self.app, meal: item.meal,
          context: item.date, date: nil, householdID: item.householdId, existing: existing,
          capacity: 1, replacing: true) { [weak self] values in
            guard let self, let recipe = values.first else { return }
            var draft = item.editDraft; draft.recipeId = recipe.id
            self.mutateDish(item, draft: draft)
          })
      case .move:
        self.qfPush(QFMovePlanViewController(app: self.app, item: item) { [weak self] in self?.loadPlan(force: true) })
      case .toggleSkipped:
        guard !item.completed else { return }
        var draft = item.editDraft; draft.skipped = !item.skipped
        self.mutateDish(item, draft: draft)
      case .remove:
        let alert = UIAlertController(title: self.app.text("移出计划", "Remove from plan"),
          message: self.app.text("移出后会保留已经发生的做菜记录。", "Existing cooking records will be kept."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.app.text("取消", "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: self.app.text("移出计划", "Remove from plan"), style: .destructive) { [weak self] _ in
          self?.mutateDish(item, draft: nil)
        })
        self.present(alert, animated: true)
      }
    }, animated: true)
  }

  private func mutateDish(_ item: QFPlannedMeal, draft: QFPlannedMealDraft?) {
    guard mealMutationTask == nil else { return }
    let userID = app.user?.userId
    mutationHUD.show(in: view, text: app.text("保存中", "Saving"))
    mealMutationTask = Task { [weak self] in
      guard let self else { return }
      defer { self.mutationHUD.hide(); self.mealMutationTask = nil }
      do {
        if let draft { _ = try await self.app.adjustPlannedMeal(item.id, draft: draft) }
        else { try await self.app.deletePlannedMeal(item.id, expectedRevision: item.revision) }
        try Task.checkCancellation()
        guard self.app.user?.userId == userID else { return }
        self.loadPlan(force: true)
      } catch is CancellationError {
      } catch {
        guard self.app.user?.userId == userID else { return }
        QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self.view)
        if (error as? QFAPIError)?.code == 40900 { self.loadPlan(force: true) }
      }
    }
  }

  private func expenseText(_ totals: [QFCurrencyTotal]?, date: String) -> String {
    guard expenseSnapshot?.startDate == date, let totals, !totals.isEmpty else { return "—" }
    let locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    return totals.map { QFPurchaseNumber.money($0.total, currency: $0.currency, locale: locale) }.joined(separator: " · ")
  }
  private func openExpenses(costOnly: Bool) {
    guard app.user != nil else { QFOperationHUD.toast(app.text("请先登录。", "Sign in first."), in: view); return }
    if costOnly {
      let date = dayKey(selectedDate)
      qfPush(QFCookingCostsViewController(app: app, range: .init(startDate: date, endDate: date), householdID: app.planningHouseholdID))
    } else { qfPush(QFPreparationExpensesViewController(app: app, date: selectedDate, householdID: app.planningHouseholdID)) }
  }
  private func loadExpenses(force: Bool) {
    expenseTask?.cancel(); expenseRequestID = UUID()
    let requestID = expenseRequestID; let date = dayKey(selectedDate); let owner = app.user?.userId; let householdID = app.planningHouseholdID
    guard owner != nil else { expenseSnapshot = nil; return }
    var query = ["startDate": date, "endDate": date]; query["householdId"] = householdID
    expenseTask = Task { [weak self] in
      guard let self else { return }
      do {
        let response: QFPreparationExpenses = try await QFContentLoadingContext.$forceRefresh.withValue(force) { try await self.app.contentRequest(path: "me/preparation-expenses", query: query) }
        try Task.checkCancellation()
        guard self.expenseRequestID == requestID, self.app.user?.userId == owner, self.app.planningHouseholdID == householdID else { return }
        self.expenseSnapshot = response; self.refreshSummary()
      } catch { /* The expense page owns retry; a failed optional summary never replaces the plan. */ }
    }
  }
  private func loadPlan(force: Bool = false) {
    loadExpenses(force: force)
    loadTask?.cancel()
    availabilityTask?.cancel()
    availabilityRequestID = UUID()
    loadTask = nil
    loadRequestID = UUID()
    let requestID = loadRequestID
    let userID = app.user?.userId
    let language = app.interfaceLanguage
    guard app.user != nil else {
      refreshControl.endRefreshing()
      calendarSnapshot = nil
      daySnapshot = nil
      availabilitySnapshot = nil
      refreshCalendar()
      refreshMeals()
      return
    }
    let month = monthKey(displayedMonth)
    let date = dayKey(selectedDate)
    let householdID = app.planningHouseholdID
    loadTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.loadRequestID == requestID {
          self.loadTask = nil
          self.refreshControl.endRefreshing()
        }
      }
      do {
        async let calendarRequest: QFPlanCalendar = QFContentLoadingContext.$forceRefresh.withValue(force) {
          try await self.app.planCalendar(month: month, householdID: householdID)
        }
        async let dayRequest: QFPlanDay = QFContentLoadingContext.$forceRefresh.withValue(force) {
          try await self.app.planDay(date: date, householdID: householdID)
        }
        let (calendarValue, dayValue) = try await (calendarRequest, dayRequest)
        try Task.checkCancellation()
        guard self.loadRequestID == requestID, self.app.user?.userId == userID,
          self.app.interfaceLanguage == language,
          self.monthKey(self.displayedMonth) == month,
          self.dayKey(self.selectedDate) == date,
          self.app.planningHouseholdID == householdID
        else { return }
        if self.calendarSnapshot != calendarValue {
          self.calendarSnapshot = calendarValue
          self.refreshCalendar()
        }
        if self.daySnapshot != dayValue {
          self.daySnapshot = dayValue
          self.refreshMeals()
        }
        self.loadAvailability(date: date, householdID: householdID, userID: userID, language: language)
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, self.loadRequestID == requestID else { return }
        QFOperationHUD.toast(
          QFProfileContentController.errorText(error, app: self.app), in: self.view)
      }
    }
  }

  private func updateAvailabilityLabel(_ label: UILabel, for dish: QFPlannedMeal) {
    guard let snapshot = availabilitySnapshot, snapshot.date == dish.date,
      snapshot.householdId == dish.householdId,
      let item = snapshot.items.first(where: { $0.planId == dish.id && $0.planRevision == dish.revision })
    else { label.text = nil; label.isHidden = true; return }
    let missing = item.materials.filter { $0.status == "SHORT" }.map(\.name)
    let unlinked = item.materials.filter { $0.ingredientId == nil }.map(\.name)
    let shown = missing.isEmpty ? unlinked : missing
    guard !shown.isEmpty else { label.text = nil; label.isHidden = true; return }
    let list = ListFormatter()
    list.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    let names = list.string(from: Array(shown.prefix(2))) ?? shown.prefix(2).joined(separator: ", ")
    if !missing.isEmpty {
      label.text = missing.count <= 2
        ? app.format("缺少：%@", "Missing: %@", names)
        : app.format("缺少：%@ 等 %d 项", "Missing: %@ and %d more", names, missing.count - 2)
    } else {
      label.text = unlinked.count <= 2
        ? app.format("食材未关联：%@", "Ingredients not linked: %@", names)
        : app.format("食材未关联：%@ 等 %d 项", "Ingredients not linked: %@ and %d more", names, unlinked.count - 2)
    }
    label.isHidden = false
  }

  private func loadAvailability(date: String, householdID: String?, userID: String?, language: String) {
    availabilityTask?.cancel()
    availabilityRequestID = UUID()
    let requestID = availabilityRequestID
    availabilityTask = Task { [weak self] in
      guard let self else { return }
      do {
        let response: QFPlanAvailability = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
          try await self.app.planAvailability(date: date, householdID: householdID)
        }
        try Task.checkCancellation()
        guard self.availabilityRequestID == requestID, response.date == date,
          response.householdId == householdID, self.app.user?.userId == userID,
          self.app.interfaceLanguage == language, self.dayKey(self.selectedDate) == date else { return }
        self.availabilitySnapshot = response
        for dish in self.daySnapshot?.slots.flatMap(\.items) ?? [] {
          if let label = self.availabilityLabels[dish.id] { self.updateAvailabilityLabel(label, for: dish) }
        }
      } catch is CancellationError {
      } catch { /* Do not display a false 'stock available' status on a failed read. */ }
    }
  }

  private func calendarState(for date: Date) -> QFPlanCalendarDay? {
    let key = dayKey(date)
    return calendarSnapshot?.days.first { $0.date == key }
  }

  private func dayKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  private func planDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)
  }

  private func monthKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM"
    return formatter.string(from: date)
  }
}

@MainActor
final class QFPreparationViewController: QFProfileContentController {
  private let startDate: String
  private let endDate: String
  private let householdID: String?
  private var summary: QFPreparationSummary?
  private var units: [String: QFMeasurementUnit] = [:]

  init(app: QFAppSession, startDate: String, endDate: String) {
    self.startDate = startDate
    self.endDate = endDate
    householdID = app.planningHouseholdID
    let scopeName = app.planningScope.householdName ?? app.text("个人", "Personal")
    super.init(app: app, title: "\(app.text("备菜", "Prep")) · \(scopeName)")
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    setReloadAction { [weak self] in self?.load() }
    _ = addFooter(app.text("生成采购单", "Create shopping list")) { [weak self] in
      self?.generateShoppingList()
    }
    load()
  }

  private func load() {
    execute(reloadOnFailure: true, showReadProgress: summary == nil) { [self] in
      async let summaryRequest = app.planPreparation(
        startDate: startDate, endDate: endDate, householdID: householdID)
      async let unitsRequest = app.measurementUnits()
      let (nextSummary, nextUnits) = try await (summaryRequest, unitsRequest)
      try Task.checkCancellation()
      summary = nextSummary
      units = Dictionary(uniqueKeysWithValues: nextUnits.map { ($0.code, $0) })
      render()
    }
  }

  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row("range", version: startDate + endDate) { [app, startDate, endDate] in
      let value = startDate == endDate ? startDate : "\(startDate) – \(endDate)"
      return QFTabUI.card(
        QFTabUI.stack([
          QFTabUI.label(app.text("计划日期", "Plan dates"), size: 12, color: QFUI.secondary),
          QFTabUI.label(value, size: 18, weight: .semibold),
        ], spacing: 6), padding: 14, border: true)
    }
    guard let summary else {
      bodyStack.endUpdates()
      return
    }
    if summary.items.isEmpty {
      bodyStack.row("empty", version: app.interfaceLanguage) { [app] in
        QFTabUI.empty(
          app.text("没有可汇总的材料", "No ingredients to prepare"),
          detail: app.text("请先为当天添加含材料的菜谱", "Add recipes with ingredient details first."))
      }
    } else {
      for (index, item) in summary.items.enumerated() {
        bodyStack.row(
          "item.\(index)",
          version: "\(item)|\(app.interfaceLanguage)|\(item.unitCode.flatMap { units[$0]?.symbol } ?? "")"
        ) { [weak self] in
          guard let self else { return UIView() }
          let amount = QFTabUI.label(
            self.quantityText(item), size: 13,
            color: item.requiresConfirmation ? QFUI.warning : QFUI.secondary, lines: 0)
          amount.textAlignment = .right
          amount.setContentCompressionResistancePriority(.required, for: .horizontal)
          let row = QFTabUI.stack(
            [QFTabUI.label(item.name, size: 16, weight: .semibold, lines: 0), UIView(), amount],
            axis: .horizontal, spacing: 10)
          row.alignment = .firstBaseline
          return QFTabUI.card(row, padding: 14, border: true)
        }
      }
    }
    if !summary.warnings.isEmpty {
      bodyStack.row("warnings", version: summary.warnings.joined(separator: "|") + app.interfaceLanguage) {
        [app, summary] in
        QFTabUI.card(
          QFTabUI.label(
            app.format(
              "有 %d 项计划缺少可用材料，未计入汇总。",
              "%d planned items have no usable ingredient content and were not included.",
              summary.warnings.count),
            size: 13, color: QFUI.warning, lines: 0),
          padding: 14, background: QFUI.warningBackground)
      }
    }
    bodyStack.endUpdates()
  }

  private func quantityText(_ item: QFPreparationItem) -> String {
    if item.quantityKind == "TEXT" {
      return item.quantityText ?? app.text("待确认", "Needs review")
    }
    let symbol = item.unitCode.flatMap { units[$0]?.symbol } ?? item.unitCode ?? ""
    if item.quantityKind == "RANGE", let maximum = item.quantityMax {
      return ["\(item.quantityMin ?? "")–\(maximum)", symbol].filter { !$0.isEmpty }.joined(separator: " ")
    }
    return [item.quantityMin ?? "", symbol].filter { !$0.isEmpty }.joined(separator: " ")
  }

  private func generateShoppingList() {
    execute(label: app.text("正在生成采购单", "Creating shopping list")) { [self] in
      let value = try await app.generateShoppingList(
        QFShoppingListGenerateDraft(
          startDate: startDate, endDate: endDate, householdId: householdID,
          subtractInventory: true))
      closeWithSuccess(
        app.format(
          "采购单已生成，共 %d 项", "Shopping list created with %d items", value.items.count))
    }
  }
}

@MainActor
private final class QFWeeklyPlanViewController: QFProfileContentController {
  private let initialDate: Date
  private let onAccepted: () -> Void
  private let householdID: String?
  private let scopeName: String
  private var proposals: [QFWeeklyPlanProposal] = []
  private var total = 0
  private var nextPage = 0
  private var hasMore = false
  private var loaded = false

  init(app: QFAppSession, initialDate: Date, onAccepted: @escaping () -> Void) {
    self.initialDate = initialDate
    self.onAccepted = onAccepted
    householdID = app.planningHouseholdID
    scopeName = app.planningScope.householdName ?? app.text("个人", "Personal")
    super.init(app: app, title: "\(app.text("AI 周计划", "AI weekly plans")) · \(scopeName)")
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    setReloadAction { [weak self] in self?.load(reset: true) }
    _ = addFooter(app.text("生成新的周计划", "Generate a weekly plan")) { [weak self] in
      self?.createProposal()
    }
    load(reset: true)
  }

  private func load(reset: Bool) {
    let page = reset ? 0 : nextPage
    execute(reloadOnFailure: true, loadingMore: !reset, showReadProgress: !loaded) { [self] in
      let response = try await app.weeklyPlanProposals(householdID: householdID, page: page)
      try Task.checkCancellation()
      if reset {
        proposals = response.items
      } else {
        var positions = Dictionary(
          uniqueKeysWithValues: proposals.enumerated().map { ($0.element.id, $0.offset) })
        for item in response.items {
          if let index = positions[item.id] { proposals[index] = item }
          else {
            positions[item.id] = proposals.count
            proposals.append(item)
          }
        }
      }
      total = response.total
      nextPage = page + 1
      hasMore = !response.items.isEmpty && proposals.count < response.total
      loaded = true
      render()
    }
  }

  private func render() {
    bodyStack.beginUpdates()
    if proposals.isEmpty {
      bodyStack.row("empty", version: app.interfaceLanguage) { [app] in
        QFTabUI.empty(
          app.text("还没有 AI 周计划", "No AI weekly plans yet"),
          detail: app.text(
            "生成后可在这里查看状态并确认加入计划",
            "Generated plans appear here for review and confirmation."))
      }
    }
    for proposal in proposals {
      let version = [
        proposal.status, String(proposal.revision), proposal.weekStart,
        String(proposal.items.count), proposal.updatedAt, app.interfaceLanguage,
      ].joined(separator: "|")
      bodyStack.row("proposal.\(proposal.id)", version: version) { [weak self] in
        self?.proposalCard(proposal) ?? UIView()
      }
    }
    bodyStack.endUpdates()
    setLoadMoreAction(hasMore ? { [weak self] in self?.load(reset: false) } : nil)
  }

  private func proposalCard(_ proposal: QFWeeklyPlanProposal) -> UIView {
    let button = UIButton(type: .system)
    button.backgroundColor = QFUI.surface
    button.layer.cornerRadius = 17
    button.layer.borderWidth = 1
    button.layer.borderColor = QFUI.border.cgColor
    let status = statusTitle(proposal.status)
    let statusColor = proposal.status == "READY" || proposal.status == "ACCEPTED"
      ? QFUI.green : proposal.status == "FAILED" ? QFUI.danger : QFUI.orange
    let labels = QFTabUI.stack(
      [
        QFTabUI.label(
          app.format("%@ 起始周", "Week of %@", proposal.weekStart), size: 17,
          weight: .semibold, lines: 0),
        QFTabUI.label(
          app.format("%d 个餐次", "%d meal slots", proposal.items.count), size: 12,
          color: QFUI.secondary),
      ], spacing: 5)
    let badge = QFTabUI.label(status, size: 12, weight: .medium, color: statusColor)
    badge.textAlignment = .right
    badge.setContentCompressionResistancePriority(.required, for: .horizontal)
    let row = QFTabUI.stack(
      [labels, UIView(), badge, QFTabUI.symbol("chevron.right", size: 14, color: QFUI.secondary)],
      axis: .horizontal, spacing: 9)
    row.alignment = .center
    row.isUserInteractionEnabled = false
    button.addSubview(row)
    row.snp.makeConstraints { $0.edges.equalToSuperview().inset(14) }
    button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(76) }
    button.accessibilityLabel = app.format("%@ 起始周", "Week of %@", proposal.weekStart)
    button.accessibilityValue = status
    button.addAction(UIAction { [weak self] _ in self?.openProposal(proposal) }, for: .touchUpInside)
    return button
  }

  private func createProposal() {
    let editor = QFWeeklyPlanEditorViewController(
      app: app, initialDate: initialDate, householdID: householdID, scopeName: scopeName
    ) {
      [weak self] created in
      guard let self else { return }
      self.proposals.removeAll { $0.id == created.id }
      self.proposals.insert(created, at: 0)
      self.total = max(self.total + 1, self.proposals.count)
      self.render()
    }
    open(editor)
  }

  private func openProposal(_ proposal: QFWeeklyPlanProposal) {
    open(
      QFWeeklyPlanProposalViewController(
        app: app, proposal: proposal,
        onUpdate: { [weak self] updated in
          guard let self else { return }
          if let index = self.proposals.firstIndex(where: { $0.id == updated.id }) {
            self.proposals[index] = updated
          } else {
            self.proposals.insert(updated, at: 0)
          }
          self.render()
        }, onAccepted: { [weak self] in
          self?.onAccepted()
        }))
  }

  private func statusTitle(_ status: String) -> String {
    switch status {
    case "QUEUED": return app.text("等待生成", "Queued")
    case "PROCESSING": return app.text("正在生成", "Generating")
    case "RETRY": return app.text("等待重试", "Waiting to retry")
    case "READY": return app.text("待确认", "Ready to review")
    case "ACCEPTED": return app.text("已加入计划", "Added to plan")
    case "CANCELLED": return app.text("已取消", "Cancelled")
    case "FAILED": return app.text("生成失败", "Generation failed")
    default: return status
    }
  }
}

@MainActor
final class QFWeeklyPlanProposalViewController: QFProfileContentController {
  private var proposal: QFWeeklyPlanProposal
  private let onUpdate: (QFWeeklyPlanProposal) -> Void
  private let onAccepted: () -> Void
  private var secondaryButton: UIButton!
  private var primaryButton: UIButton!
  private let appendAndShop: Bool
  private let scopeBinding: QFAgentScope
  private var refreshTask: Task<Void, Never>?
  private var shoppingReceipt: QFShoppingList?

  init(
    app: QFAppSession, proposal: QFWeeklyPlanProposal, appendAndShop: Bool = false,
    onUpdate: @escaping (QFWeeklyPlanProposal) -> Void, onAccepted: @escaping () -> Void
  ) {
    self.proposal = proposal
    self.appendAndShop = appendAndShop || QFAssistantWeeklyPlanIntent.requiresAppendAndShopping(generationMode: proposal.generationMode, goal: proposal.goal)
    self.scopeBinding = QFAssistantAgent.scope(app)
    self.onUpdate = onUpdate
    self.onAccepted = onAccepted
    super.init(app: app, title: app.text("周计划详情", "Weekly plan details"))
  }

  required init?(coder: NSCoder) { nil }

  deinit { refreshTask?.cancel() }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated); scheduleRefresh()
    if proposal.status == "ACCEPTED", shoppingReceipt == nil, proposal.shoppingListId != nil { load() }
  }
  override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); refreshTask?.cancel(); refreshTask = nil }

  private func scheduleRefresh() {
    guard refreshTask == nil, ["QUEUED", "PROCESSING", "RETRY"].contains(proposal.status) else { return }
    refreshTask = Task { [weak self] in
      // Bounded polling only while this visible proposal is being generated.
      for _ in 0..<8 {
        do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
        guard let self, self.viewIfLoaded?.window != nil,
          QFAssistantAgent.scope(self.app) == self.scopeBinding else { return }
        do {
          let current = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await self.app.weeklyPlanProposal(self.proposal.id) }
          try Task.checkCancellation()
          guard QFAssistantAgent.scope(self.app) == self.scopeBinding else { return }
          self.proposal = current; self.onUpdate(current); self.render()
          if !["QUEUED", "PROCESSING", "RETRY"].contains(current.status) { break }
        } catch { break }
      }
      self?.refreshTask = nil
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setReloadAction { [weak self] in self?.load() }
    secondaryButton = addFooter("", primary: false) { [weak self] in self?.secondaryAction() }
    primaryButton = addFooter("") { [weak self] in self?.confirmAccept() }
    render()
  }

  private func load() {
    execute(reloadOnFailure: true) { [self] in
      proposal = try await QFContentLoadingContext.$forceRefresh.withValue(true) { try await app.weeklyPlanProposal(proposal.id) }
      try Task.checkCancellation()
      guard QFAssistantAgent.scope(app) == scopeBinding else { throw CancellationError() }
      if let id = proposal.shoppingListId { shoppingReceipt = try? await app.shoppingList(id) }
      guard QFAssistantAgent.scope(app) == scopeBinding else { throw CancellationError() }
      onUpdate(proposal)
      render()
    }
  }

  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row(
      "summary",
      version: "\(proposal.status)|\(proposal.revision)|\(proposal.weekStart)|\(app.interfaceLanguage)"
    ) { [weak self] in
      guard let self else { return UIView() }
      return QFTabUI.card(
        QFTabUI.stack(
          [
            QFTabUI.label(
              self.app.format("%@ 起始周", "Week of %@", self.proposal.weekStart),
              size: 19, weight: .semibold),
            QFTabUI.label(
              self.statusTitle(self.proposal.status), size: 13,
              color: self.proposal.status == "FAILED" ? QFUI.danger : QFUI.secondary),
          ], spacing: 6), padding: 14, background: QFUI.paleGreen)
    }
    if proposal.items.isEmpty {
      bodyStack.row("empty", version: proposal.status + app.interfaceLanguage) { [app] in
        QFTabUI.empty(
          app.text("计划内容尚未生成", "Plan content is not ready"),
          detail: app.text("下拉刷新可获取最新状态", "Pull down to refresh the latest status."))
      }
    } else {
      if appendAndShop {
        bodyStack.row("shopping-explanation", version: app.interfaceLanguage + proposal.status) { [app] in
          QFTabUI.card(QFTabUI.label(app.text("优先利用库存，缺少的食材可补购。默认每餐 1 份；这是一般饮食安排，不含个人热量处方。确认后将保留已有餐次，并生成扣除库存后的补购清单。", "Existing stock is preferred and missing ingredients can be purchased. Meals default to one serving. This is a general menu, without a personal calorie prescription. Confirmation preserves existing meals and creates a shopping list after subtracting stock."), size: 14, color: QFUI.secondary, lines: 0), padding: 14)
        }
      }
      for (index, item) in proposal.items.enumerated() {
        let version = [
          item.date, item.meal, item.recipeId, item.title ?? "", String(item.servings),
          String(item.contentAvailable), app.interfaceLanguage,
        ].joined(separator: "|")
        bodyStack.row("item.\(index).\(item.date).\(item.meal)", version: version) { [weak self] in
          self?.itemCard(item) ?? UIView()
        }
      }
    }
    if let shoppingReceipt, shoppingReceipt.householdId == scopeBinding.household, shoppingReceipt.language == scopeBinding.language {
      bodyStack.row("shopping-receipt", version: shoppingReceipt.id + String(shoppingReceipt.revision) + app.interfaceLanguage) { [app] in
        let text = shoppingReceipt.items.map { item in
          let quantity = item.quantityText ?? [item.quantityMax ?? item.quantityMin, item.unitCode].compactMap { $0 }.joined(separator: " ")
          return "• " + item.name + (quantity.isEmpty ? "" : " · " + quantity)
        }.joined(separator: "\n")
        return QFTabUI.card(QFTabUI.stack([
          QFTabUI.label(app.text("补购清单", "Shopping list"), size: 18, weight: .semibold),
          QFTabUI.label(text.isEmpty ? app.text("没有需要补购的食材", "No additional ingredients to buy") : text, size: 15, lines: 0),
          QFTabUI.label(app.text("数量不明确的食材请在食材页核对。", "Review ingredients with uncertain quantities on the Ingredients page."), size: 12, color: QFUI.secondary, lines: 0)
        ], spacing: 8), padding: 14, background: QFUI.paleGreen)
      }
    }
    bodyStack.endUpdates()
    renderActions()
  }

  private func itemCard(_ item: QFWeeklyPlanProposalItem) -> UIView {
    let title = item.contentAvailable
      ? (item.title?.isEmpty == false ? item.title! : app.text("未命名菜谱", "Untitled recipe"))
      : app.text("当前语言内容不可用", "Content unavailable in this language")
    let detail = app.format(
      "%@ · %@ · %d 份", "%@ · %@ · %d servings", item.date, mealTitle(item.meal), item.servings)
    let recipe = QFTabUI.button(title, size: 16, weight: .semibold, color: QFUI.primary) { [weak self] in
      guard let self, QFAssistantAgent.scope(self.app) == self.scopeBinding,
        item.contentAvailable, UUID(uuidString: item.recipeId) != nil else { return }
      self.qfPush(QFHomeRecipeDetailViewController(app: self.app, recipeID: item.recipeId))
    }
    recipe.titleLabel?.numberOfLines = 2; recipe.contentHorizontalAlignment = .leading
    recipe.isEnabled = item.contentAvailable
    return QFTabUI.card(
      QFTabUI.stack(
        [
          recipe,
          QFTabUI.label(detail, size: 12, color: QFUI.secondary, lines: 0),
        ], spacing: 5), padding: 14, border: true)
  }

  private func renderActions() {
    let ready = proposal.status == "READY"
    let generating = ["QUEUED", "PROCESSING", "RETRY"].contains(proposal.status)
    secondaryButton.isHidden = !(ready || generating)
    secondaryButton.setTitle(
      ready ? app.text("取消提案", "Cancel proposal") : app.text("取消生成", "Cancel generation"),
      for: .normal)
    primaryButton.isHidden = !ready
    primaryButton.setTitle(appendAndShop ? app.text("保存七天计划与补购清单", "Save seven-day plan and shopping list") : app.text("加入计划", "Add to plan"), for: .normal)
  }

  private func secondaryAction() {
    guard proposal.status == "READY"
      || ["QUEUED", "PROCESSING", "RETRY"].contains(proposal.status)
    else { return }
    confirmCancel()
  }

  private func confirmAccept() {
    guard QFAssistantAgent.scope(app) == scopeBinding else { return }
    confirm(
      app.text("将这份周计划加入日历？", "Add this weekly plan to your calendar?"),
      detail: appendAndShop ? app.text("确认当前日期、餐次和份数后，一次加入计划并生成补购清单。不会替换已有餐次；库存不足部分列入补购，不会自动下单。", "Confirm the dates, meals and servings to save the plan and generate its shopping list. Existing meals are preserved. Missing stock is listed for purchase; no order is placed.") : app.text(
        "若相关餐次已被修改，系统会要求刷新后重新确认。",
        "If a related meal slot changed, refresh and review the proposal again."),
      actionTitle: app.text("加入计划", "Add to plan")
    ) { [weak self] in self?.accept() }
  }

  private func accept() {
    guard QFAssistantAgent.scope(app) == scopeBinding else { return }
    execute(label: app.text("正在加入计划", "Adding to plan")) { [self] in
      proposal = try await app.acceptWeeklyPlanProposal(
        proposal.id, expectedRevision: proposal.revision, mode: appendAndShop ? "APPEND" : "REPLACE", createShoppingList: appendAndShop)
      try Task.checkCancellation()
      guard QFAssistantAgent.scope(app) == scopeBinding, proposal.status == "ACCEPTED",
        !appendAndShop || proposal.shoppingListId != nil else { throw CancellationError() }
      onUpdate(proposal)
      onAccepted()
      render()
      message(app.text("已加入计划", "Added to plan"))
      if let id = proposal.shoppingListId {
        shoppingReceipt = try? await app.shoppingList(id)
        guard QFAssistantAgent.scope(app) == scopeBinding else { return }
        render()
      }
    }
  }

  private func confirmCancel() {
    guard QFAssistantAgent.scope(app) == scopeBinding else { return }
    confirm(
      app.text("取消这份提案？", "Cancel this proposal?"),
      detail: app.text("取消后不会写入饮食计划。", "The proposal will not be added to your meal plan."),
      actionTitle: app.text("取消提案", "Cancel proposal"), destructive: true
    ) { [weak self] in self?.cancel() }
  }

  private func cancel() {
    execute(label: app.text("正在取消", "Cancelling")) { [self] in
      try await app.cancelWeeklyPlanProposal(proposal.id, expectedRevision: proposal.revision)
      proposal = try await app.weeklyPlanProposal(proposal.id)
      try Task.checkCancellation()
      onUpdate(proposal)
      render()
    }
  }

  private func statusTitle(_ status: String) -> String {
    switch status {
    case "QUEUED": return app.text("等待生成", "Queued")
    case "PROCESSING": return app.text("正在生成", "Generating")
    case "RETRY": return app.text("等待重试", "Waiting to retry")
    case "READY": return app.text("待确认", "Ready to review")
    case "ACCEPTED": return app.text("已加入计划", "Added to plan")
    case "CANCELLED": return app.text("已取消", "Cancelled")
    case "FAILED": return app.text("生成失败", "Generation failed")
    default: return status
    }
  }

  private func mealTitle(_ meal: String) -> String {
    switch meal {
    case "BREAKFAST": return app.text("早餐", "Breakfast")
    case "LUNCH": return app.text("午餐", "Lunch")
    case "DINNER": return app.text("晚餐", "Dinner")
    case "SNACK": return app.text("加餐", "Snack")
    default: return meal
    }
  }
}

@MainActor
private final class QFWeeklyPlanEditorViewController: QFProfileContentController, UITextViewDelegate {
  private struct Draft: Equatable {
    var weekStart: Date
    var meals: Set<String>
    var servings: String
    var budget: String
    var currency: String
    var maxMinutes: String
    var mustUseInventory: Bool
    var preference: String
  }

  private let onCreated: (QFWeeklyPlanProposal) -> Void
  private let householdID: String?
  private let idempotencyKey = UUID().uuidString.lowercased()
  private var original: Draft
  private var draft: Draft

  init(
    app: QFAppSession, initialDate: Date, householdID: String?, scopeName: String,
    onCreated: @escaping (QFWeeklyPlanProposal) -> Void
  ) {
    self.onCreated = onCreated
    self.householdID = householdID
    let monday = Self.monday(for: max(initialDate, Date()))
    let value = Draft(
      weekStart: monday, meals: ["BREAKFAST", "LUNCH", "DINNER"], servings: "2",
      budget: "", currency: Locale.current.currencyCode ?? "CNY", maxMinutes: "",
      mustUseInventory: false, preference: "")
    original = value
    draft = value
    super.init(
      app: app,
      title: "\(app.text("生成 AI 周计划", "Generate AI weekly plan")) · \(scopeName)")
  }

  required init?(coder: NSCoder) { nil }
  override var reloadsOnAppearance: Bool { false }
  override var hasUnsavedChanges: Bool { draft != original }

  override func viewDidLoad() {
    super.viewDidLoad()
    buildForm()
    _ = addFooter(app.text("开始生成", "Start generating")) { [weak self] in self?.create() }
  }

  override func close() {
    guard hasUnsavedChanges else {
      super.close()
      return
    }
    confirm(
      app.text("放弃当前设置？", "Discard these settings?"),
      detail: app.text("尚未提交生成请求。", "The generation request has not been submitted."),
      actionTitle: app.text("放弃", "Discard"), destructive: true
    ) { [weak self] in self?.qfClose() }
  }

  private func buildForm() {
    let date = UIDatePicker()
    date.datePickerMode = .date
    date.preferredDatePickerStyle = .compact
    date.locale = Locale(
      identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    date.minimumDate = Self.monday(for: Date())
    date.maximumDate = Calendar.current.date(byAdding: .weekOfYear, value: 52, to: date.minimumDate!)
    date.date = draft.weekStart
    date.addAction(UIAction { [weak self, weak date] _ in
      guard let selected = date?.date else { return }
      self?.draft.weekStart = Self.monday(for: selected)
      date?.date = Self.monday(for: selected)
    }, for: .valueChanged)
    let dateRow = QFTabUI.stack(
      [QFTabUI.label(app.text("计划起始周", "Week starts"), size: 16), UIView(), date],
      axis: .horizontal, spacing: 10)
    dateRow.alignment = .center
    bodyStack.addArrangedSubview(QFTabUI.card(dateRow, padding: 12, border: true))

    let meals = QFTabUI.stack([], spacing: 10)
    for meal in ["BREAKFAST", "LUNCH", "DINNER", "SNACK"] {
      let toggle = UISwitch()
      toggle.isOn = draft.meals.contains(meal)
      toggle.addAction(UIAction { [weak self, weak toggle] _ in
        guard let self else { return }
        if toggle?.isOn == true { self.draft.meals.insert(meal) }
        else { self.draft.meals.remove(meal) }
      }, for: .valueChanged)
      let row = QFTabUI.stack(
        [QFTabUI.label(mealTitle(meal), size: 16), UIView(), toggle],
        axis: .horizontal, spacing: 10)
      row.alignment = .center
      meals.addArrangedSubview(row)
    }
    bodyStack.addArrangedSubview(
      QFTabUI.card(
        QFTabUI.stack(
          [QFTabUI.label(app.text("餐次", "Meals"), size: 13, color: QFUI.secondary), meals],
          spacing: 10), padding: 14, border: true))

    bodyStack.addArrangedSubview(
      labeledField(
        app.text("每餐人数", "Servings per meal"), placeholder: app.text("1–30", "1–30"),
        text: draft.servings, keyboard: .numberPad, limit: 2
      ) { [weak self] in self?.draft.servings = $0 })
    bodyStack.addArrangedSubview(
      labeledField(
        app.text("每周预算（可选）", "Weekly budget (optional)"),
        placeholder: app.text("金额", "Amount"), text: draft.budget, keyboard: .decimalPad,
        limit: 12
      ) { [weak self] in self?.draft.budget = $0 })
    bodyStack.addArrangedSubview(
      labeledField(
        app.text("预算币种", "Budget currency"), placeholder: "CNY / USD",
        text: draft.currency, keyboard: .asciiCapable, limit: 3
      ) { [weak self] in self?.draft.currency = $0.uppercased() })
    bodyStack.addArrangedSubview(
      labeledField(
        app.text("每天最长烹饪时间（分钟，可选）", "Maximum cooking time per day (minutes, optional)"),
        placeholder: app.text("1–1440", "1–1440"), text: draft.maxMinutes,
        keyboard: .numberPad, limit: 4
      ) { [weak self] in self?.draft.maxMinutes = $0 })

    let inventory = UISwitch()
    inventory.isOn = draft.mustUseInventory
    inventory.addAction(UIAction { [weak self, weak inventory] _ in
      self?.draft.mustUseInventory = inventory?.isOn == true
    }, for: .valueChanged)
    let inventoryRow = QFTabUI.stack(
      [
        QFTabUI.stack(
          [
            QFTabUI.label(app.text("优先使用现有库存", "Prioritize current inventory"), size: 16),
            QFTabUI.label(
              app.text("优先利用已有食材，也允许为合理搭配补购", "Prefer ingredients in stock and allow purchases for a suitable menu."),
              size: 12, color: QFUI.secondary, lines: 0),
          ], spacing: 4),
        UIView(), inventory,
      ], axis: .horizontal, spacing: 10)
    inventoryRow.alignment = .center
    bodyStack.addArrangedSubview(QFTabUI.card(inventoryRow, padding: 14, border: true))

    let preference = UITextView()
    preference.delegate = self
    preference.text = draft.preference
    preference.font = UIFont.preferredFont(forTextStyle: .body)
    preference.adjustsFontForContentSizeCategory = true
    preference.textColor = QFUI.text
    preference.backgroundColor = QFUI.surface
    preference.layer.cornerRadius = 12
    preference.layer.borderWidth = 1
    preference.layer.borderColor = QFUI.border.cgColor
    preference.textContainerInset = UIEdgeInsets(top: 11, left: 8, bottom: 11, right: 8)
    preference.snp.makeConstraints { $0.height.equalTo(112) }
    bodyStack.addArrangedSubview(
      QFTabUI.stack(
        [
          QFTabUI.label(app.text("其他偏好（可选）", "Other preferences (optional)"), size: 13, color: QFUI.secondary),
          preference,
          QFTabUI.label(
            app.text(
              "偏好文本会发送给 AI 服务用于生成计划，请勿填写联系方式等个人信息。",
              "Preference text is sent to the AI service to generate the plan. Do not include contact or other personal information."),
            size: 11, color: QFUI.secondary, lines: 0),
        ], spacing: 7))
  }

  func textViewDidChange(_ textView: UITextView) {
    if textView.text.count > 500 { textView.text = String(textView.text.prefix(500)) }
    draft.preference = textView.text
  }

  private func labeledField(
    _ title: String, placeholder: String, text: String, keyboard: UIKeyboardType, limit: Int,
    changed: @escaping (String) -> Void
  ) -> UIView {
    QFTabUI.stack(
      [
        QFTabUI.label(title, size: 13, color: QFUI.secondary),
        QFContentUI.field(
          placeholder, text: text, keyboard: keyboard, limit: limit, changed: changed),
      ], spacing: 7)
  }

  private func create() {
    guard !draft.meals.isEmpty else {
      message(app.text("请至少选择一个餐次。", "Choose at least one meal."), error: true)
      return
    }
    guard let servings = Int(draft.servings), (1...30).contains(servings) else {
      message(app.text("每餐人数需为 1–30。", "Servings must be between 1 and 30."), error: true)
      return
    }
    let budget = draft.budget.trimmingCharacters(in: .whitespacesAndNewlines)
    if !budget.isEmpty {
      guard let amount = Decimal(string: budget), amount >= 0,
        draft.currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil
      else {
        message(app.text("请输入有效预算和三位币种代码。", "Enter a valid budget and three-letter currency code."), error: true)
        return
      }
    }
    let maxMinutesText = draft.maxMinutes.trimmingCharacters(in: .whitespacesAndNewlines)
    let maxMinutes: Int?
    if maxMinutesText.isEmpty {
      maxMinutes = nil
    } else if let value = Int(maxMinutesText), (1...1440).contains(value) {
      maxMinutes = value
    } else {
      message(app.text("最长烹饪时间需为 1–1440 分钟。", "Maximum cooking time must be 1–1440 minutes."), error: true)
      return
    }
    let requested = draft
    execute(label: app.text("正在提交生成任务", "Submitting generation request")) { [self] in
      let created = try await app.createWeeklyPlanProposal(
        QFWeeklyPlanProposalDraft(
          weekStart: Self.dayFormatter.string(from: requested.weekStart), householdId: householdID,
          meals: ["BREAKFAST", "LUNCH", "DINNER", "SNACK"].filter(requested.meals.contains),
          servings: servings, budget: budget.isEmpty ? nil : budget,
          currency: budget.isEmpty ? nil : requested.currency, maxMinutesPerDay: maxMinutes,
          excludedIngredientIds: [], mustUseInventory: requested.mustUseInventory,
          preference: requested.preference.trimmingCharacters(in: .whitespacesAndNewlines),
          idempotencyKey: idempotencyKey))
      try Task.checkCancellation()
      original = requested
      onCreated(created)
      onChanged?()
      closeWithSuccess(app.text("生成任务已提交", "Generation request submitted"))
    }
  }

  private func mealTitle(_ meal: String) -> String {
    switch meal {
    case "BREAKFAST": return app.text("早餐", "Breakfast")
    case "LUNCH": return app.text("午餐", "Lunch")
    case "DINNER": return app.text("晚餐", "Dinner")
    case "SNACK": return app.text("加餐", "Snack")
    default: return meal
    }
  }

  private static func monday(for value: Date) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 2
    calendar.timeZone = .current
    let start = calendar.startOfDay(for: value)
    let weekday = calendar.component(.weekday, from: start)
    let distance = (weekday + 5) % 7
    return calendar.date(byAdding: .day, value: -distance, to: start) ?? start
  }

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}
