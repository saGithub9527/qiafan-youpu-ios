import Foundation
import SnapKit
import UIKit

@MainActor
final class QFPlanViewController: QFPageViewController {
  private let calendar: Calendar
  private var displayedMonth: Date
  private var selectedDate: Date
  private let monthLabel = QFTabUI.label("", size: 20, weight: .semibold)
  private let dayLabel = QFTabUI.label("", size: 12, color: QFUI.secondary, lines: 0)
  private let calendarRows = QFTabUI.stack([], spacing: 0)
  private let meals = QFTabUI.stack([], spacing: 12)
  private let summary = QFTabUI.stack([], axis: .horizontal, spacing: 10)
  private var legend: UIStackView!
  private var compact = false

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

  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "plan.screen"
    let heading = QFTabUI.label("饮食计划", size: 29, weight: .semibold, lines: 0)
    heading.accessibilityTraits.insert(.header)
    let records = QFTabUI.button("做菜记录", size: 14, weight: .medium, color: QFUI.orange) {
      [weak self] in self?.showUnavailable("做菜记录")
    }
    records.setContentCompressionResistancePriority(.required, for: .horizontal)
    records.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
    let header = QFTabUI.stack([heading, UIView(), records], axis: .horizontal, spacing: 8)
    header.alignment = .center
    contentStack.addArrangedSubview(header)
    contentStack.addArrangedSubview(makeCalendar())
    summary.distribution = .fillEqually
    contentStack.addArrangedSubview(QFTabUI.card(summary, padding: 14, background: QFUI.paleGreen))
    let dayTitle = QFTabUI.label("当日计划", size: 21, weight: .semibold)
    dayTitle.accessibilityTraits.insert(.header)
    dayLabel.textAlignment = .right
    let dayHeading = QFTabUI.stack([dayTitle, UIView(), dayLabel], axis: .horizontal, spacing: 8)
    dayHeading.alignment = .firstBaseline
    contentStack.addArrangedSubview(dayHeading)
    contentStack.addArrangedSubview(meals)
    installActions()
    refreshCalendar()
    refreshMeals()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let next = view.bounds.width < 360
    guard next != compact else { return }
    compact = next
    legend.axis = compact ? .vertical : .horizontal
  }

  private func makeCalendar() -> UIView {
    let previous = QFTabUI.iconButton("chevron.left", label: "上个月", size: 19) { [weak self] in
      self?.moveMonth(-1)
    }
    let next = QFTabUI.iconButton("chevron.right", label: "下个月", size: 19) { [weak self] in
      self?.moveMonth(1)
    }
    monthLabel.textAlignment = .center
    monthLabel.adjustsFontSizeToFitWidth = true
    monthLabel.minimumScaleFactor = 0.8
    monthLabel.accessibilityTraits.insert(.header)
    let monthHeader = QFTabUI.stack([previous, monthLabel, next], axis: .horizontal, spacing: 0)
    let weekdays = QFTabUI.stack(
      ["一", "二", "三", "四", "五", "六", "日"].map { value -> UILabel in
        let label = QFTabUI.label(value, size: 14, color: QFUI.secondary)
        label.textAlignment = .center
        return label
      }, axis: .horizontal, spacing: 0)
    weekdays.distribution = .fillEqually
    calendarRows.accessibilityIdentifier = "plan.calendar"
    let legendText = QFTabUI.label("• 有做菜记录     ◦ 有待做计划", size: 11, color: QFUI.secondary, lines: 0)
    let today = QFTabUI.button("回到今天", size: 12, weight: .medium, color: QFUI.orange) {
      [weak self] in self?.returnToToday()
    }
    today.contentHorizontalAlignment = .right
    today.setContentCompressionResistancePriority(.required, for: .horizontal)
    today.snp.makeConstraints { $0.height.greaterThanOrEqualTo(36) }
    legend = QFTabUI.stack([legendText, today], axis: .horizontal, spacing: 8)
    return QFTabUI.card(
      QFTabUI.stack([monthHeader, weekdays, calendarRows, legend], spacing: 8), padding: 12,
      border: true)
  }

  private func refreshCalendar() {
    monthLabel.text =
      "\(calendar.component(.year, from: displayedMonth))年\(calendar.component(.month, from: displayedMonth))月"
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
          }
          button.contentEdgeInsets = .zero
          button.layer.cornerRadius = 10
          button.isSelected = selected
          button.setTitleColor(selected ? QFUI.onPrimary : QFUI.text, for: .selected)
          button.titleLabel?.adjustsFontSizeToFitWidth = true
          button.titleLabel?.minimumScaleFactor = 0.8
          button.accessibilityLabel = "\(month)月\(day)日"
          cell.addSubview(button)
          button.snp.makeConstraints {
            $0.leading.trailing.equalToSuperview().inset(3)
            $0.top.bottom.equalToSuperview().inset(1)
          }
        }
        row.addArrangedSubview(cell)
      }
      row.snp.makeConstraints { $0.height.equalTo(32) }
      calendarRows.addArrangedSubview(row)
    }
  }

  private func refreshMeals() {
    let fixture = calendar.isDateInToday(selectedDate)
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "M月d日 · EEEE"
    dayLabel.text = formatter.string(from: selectedDate)
    QFTabUI.clear(summary)
    let values = fixture ? ["3 / 4 道", "¥36.60", "¥54.20"] : ["0 / 0 道", "¥0.00", "¥0.00"]
    for (index, title) in ["已完成", "消耗成本", "采购支出"].enumerated() {
      let value = QFTabUI.label(values[index], size: 22, weight: .semibold)
      value.adjustsFontSizeToFitWidth = true
      value.minimumScaleFactor = 0.7
      summary.addArrangedSubview(
        QFTabUI.stack([QFTabUI.label(title, size: 12, color: QFUI.green), value], spacing: 4))
    }
    QFTabUI.clear(meals)
    if fixture {
      QFPlanFixtures.meals.forEach { meals.addArrangedSubview(makeMeal($0)) }
    } else {
      meals.addArrangedSubview(QFTabUI.empty("当天还没有安排", detail: "留一点期待，给下一餐"))
    }
  }

  private func makeMeal(_ meal: QFPlanMeal) -> UIView {
    let more = QFTabUI.iconButton("ellipsis", label: "调整\(meal.title)计划", size: 18) { [weak self] in
      self?.showUnavailable("调整当餐计划")
    }
    let heading = QFTabUI.stack(
      [
        QFTabUI.label(meal.title, size: 19, weight: .semibold), UIView(),
        QFTabUI.label(
          meal.detail, size: 12, color: meal.title == "午餐" ? QFUI.orange : QFUI.secondary), more,
      ], axis: .horizontal, spacing: 8)
    heading.alignment = .center
    let body = QFTabUI.stack([heading], spacing: 12)
    for dish in meal.dishes {
      let image = UIImageView(image: UIImage(named: dish.asset))
      image.contentMode = .scaleAspectFill
      image.clipsToBounds = true
      image.layer.cornerRadius = 12
      image.snp.makeConstraints { $0.size.equalTo(48) }
      let details = QFTabUI.stack(
        [
          QFTabUI.label(dish.title, size: 16, weight: .semibold, lines: 0),
          QFTabUI.label(dish.detail, size: 12, color: QFUI.secondary, lines: 0),
        ], spacing: 5)
      let done = QFTabUI.button(
        dish.done ? "✓ 已做" : "做菜打卡", size: 12, weight: .medium,
        color: dish.done ? QFUI.green : QFUI.orange,
        background: dish.done ? QFUI.successBackground : QFUI.tint
      ) { [weak self] in self?.showUnavailable("做菜打卡") }
      done.contentEdgeInsets = .zero
      done.layer.cornerRadius = 15
      done.snp.makeConstraints {
        $0.width.equalTo(64)
        $0.height.equalTo(30)
      }
      let row = QFTabUI.stack([image, details, done], axis: .horizontal, spacing: 10)
      row.alignment = .center
      body.addArrangedSubview(row)
    }
    return QFTabUI.card(body, padding: 14, border: true)
  }

  private func installActions() {
    let create = QFTabUI.button(
      "制定计划", size: 18, weight: .medium, color: QFUI.onPrimary, background: QFUI.primary
    ) { [weak self] in self?.showUnavailable("制定计划") }
    create.accessibilityIdentifier = "plan.create"
    let prepare = QFTabUI.button("备菜", size: 18, weight: .medium, background: QFUI.surface) {
      [weak self] in self?.showUnavailable("备菜")
    }
    prepare.layer.borderWidth = 1
    prepare.layer.borderColor = QFUI.border.cgColor
    let bar = QFTabUI.stack([create, prepare], axis: .horizontal, spacing: 10)
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

  private func moveMonth(_ offset: Int) {
    if let month = calendar.date(byAdding: .month, value: offset, to: displayedMonth) {
      displayedMonth = month
      refreshCalendar()
    }
  }
  private func returnToToday() {
    selectedDate = calendar.startOfDay(for: Date())
    displayedMonth =
      calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate))
      ?? selectedDate
    refreshCalendar()
    refreshMeals()
  }
}

private struct QFPlanMeal: Identifiable, Sendable {
  let title: String
  let detail: String
  let dishes: [QFPlanDish]
  var id: String { title }
}

private struct QFPlanDish: Identifiable, Sendable {
  let title: String
  let asset: String
  let detail: String
  let done: Bool
  var id: String { title }
}

private enum QFPlanFixtures {
  static let meals = [
    QFPlanMeal(
      title: "早餐", detail: "1道 · 已完成",
      dishes: [
        QFPlanDish(title: "鲜肉小笼包", asset: "dish-dimsum", detail: "消耗 ¥6.20", done: true)
      ]),
    QFPlanMeal(
      title: "午餐", detail: "3道 · 整餐打卡",
      dishes: [
        QFPlanDish(title: "番茄炖牛腩", asset: "dish-stew", detail: "消耗 ¥26.80", done: true),
        QFPlanDish(title: "清炒西兰花", asset: "dish-vegetables", detail: "消耗 ¥3.60", done: true),
        QFPlanDish(title: "番茄鸡蛋汤", asset: "dish-soup", detail: "待完成", done: false),
      ]),
  ]
}
