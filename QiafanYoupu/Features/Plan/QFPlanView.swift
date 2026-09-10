import Foundation
import SwiftUI

struct QFPlanView: View {
  private let calendar: Calendar
  @State private var displayedMonth: Date
  @State private var selectedDate: Date
  @State private var unavailableFeature: QFPlanUnavailableFeature?

  init() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "zh_CN")
    calendar.timeZone = .current
    calendar.firstWeekday = 2
    let today = calendar.startOfDay(for: Date())
    let month = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
    self.calendar = calendar
    _selectedDate = State(initialValue: today)
    _displayedMonth = State(initialValue: month)
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 16) {
          header
          QFPlanCalendarCard(
            calendar: calendar,
            month: displayedMonth,
            selectedDate: selectedDate,
            onMoveMonth: moveMonth,
            onSelectDate: { selectedDate = $0 },
            onToday: returnToToday
          )
          QFPlanSummaryView(showsFixture: showsFixture)
          dayHeader
          meals
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 24)
      }
      QFPlanActionBar(onAction: showUnavailable)
    }
    .background(QFTheme.background)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("plan.screen")
    .alert(item: $unavailableFeature) { feature in
      Alert(
        title: Text(feature.title),
        message: Text("该功能暂未开放"),
        dismissButton: .default(Text("知道了"))
      )
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text("饮食计划")
        .font(.system(size: 29, weight: .semibold))
        .foregroundColor(QFTheme.text)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 8)
      Button("做菜记录") { showUnavailable("做菜记录") }
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(QFTheme.orange)
        .frame(minHeight: 44)
    }
  }

  private var dayHeader: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("当日计划")
        .font(.system(size: 21, weight: .semibold))
        .foregroundColor(QFTheme.text)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 0)
      Text(selectedDayTitle)
        .font(.system(size: 12))
        .foregroundColor(QFTheme.secondary)
        .multilineTextAlignment(.trailing)
    }
  }

  @ViewBuilder private var meals: some View {
    if showsFixture {
      VStack(spacing: 12) {
        ForEach(QFPlanFixtures.meals) { meal in
          QFPlanMealCard(meal: meal, onAction: showUnavailable)
        }
      }
    } else {
      Text("当天还没有安排\n留一点期待，给下一餐")
        .font(.system(size: 15))
        .foregroundColor(QFTheme.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 32)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
    }
  }

  private var showsFixture: Bool { calendar.isDateInToday(selectedDate) }

  private var selectedDayTitle: String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "M月d日 · EEEE"
    return formatter.string(from: selectedDate)
  }

  private func moveMonth(_ offset: Int) {
    if let month = calendar.date(byAdding: .month, value: offset, to: displayedMonth) {
      displayedMonth = month
    }
  }

  private func returnToToday() {
    let today = calendar.startOfDay(for: Date())
    selectedDate = today
    displayedMonth =
      calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
  }

  private func showUnavailable(_ title: String) {
    unavailableFeature = QFPlanUnavailableFeature(title: title)
  }
}

private struct QFPlanUnavailableFeature: Identifiable {
  let title: String
  var id: String { title }
}

private struct QFPlanCalendarCard: View {
  let calendar: Calendar
  let month: Date
  let selectedDate: Date
  let onMoveMonth: (Int) -> Void
  let onSelectDate: (Date) -> Void
  let onToday: () -> Void

  private let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 0), count: 7)
  private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

  var body: some View {
    VStack(spacing: 8) {
      monthHeader
      HStack(spacing: 0) {
        ForEach(weekdays, id: \.self) { weekday in
          Text(weekday)
            .font(.system(size: 14))
            .foregroundColor(QFTheme.secondary)
            .frame(maxWidth: .infinity)
        }
      }
      LazyVGrid(columns: columns, spacing: 0) {
        ForEach(days) { day in
          if let date = day.date {
            QFPlanDayButton(
              day: calendar.component(.day, from: date),
              month: calendar.component(.month, from: date),
              selected: calendar.isDate(date, inSameDayAs: selectedDate),
              onSelect: { onSelectDate(date) }
            )
          } else {
            Color.clear.frame(height: 32).accessibilityHidden(true)
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("plan.calendar")
      legend
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
    .overlay(RoundedRectangle(cornerRadius: 18).stroke(QFTheme.border, lineWidth: 0.7))
  }

  private var monthHeader: some View {
    HStack(spacing: 0) {
      Button {
        onMoveMonth(-1)
      } label: {
        Image(systemName: "chevron.left").frame(width: 44, height: 44)
      }
      .accessibilityLabel("上个月")
      Text(monthTitle)
        .font(.system(size: 20, weight: .semibold))
        .foregroundColor(QFTheme.text)
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(.isHeader)
      Button {
        onMoveMonth(1)
      } label: {
        Image(systemName: "chevron.right").frame(width: 44, height: 44)
      }
      .accessibilityLabel("下个月")
    }
    .font(.system(size: 19, weight: .medium))
    .foregroundColor(QFTheme.secondary)
    .buttonStyle(.plain)
  }

  private var monthTitle: String {
    "\(calendar.component(.year, from: month))年\(calendar.component(.month, from: month))月"
  }

  private var legend: some View {
    HStack(spacing: 8) {
      Text("• 有做菜记录     ◦ 有待做计划")
        .font(.system(size: 11))
        .foregroundColor(QFTheme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button("回到今天", action: onToday)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(QFTheme.orange)
        .frame(minHeight: 36)
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  private var days: [QFPlanCalendarDay] {
    let weekday = calendar.component(.weekday, from: month)
    let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
    let dayCount = calendar.range(of: .day, in: .month, for: month)?.count ?? 0
    let slotCount = ((leadingDays + dayCount + 6) / 7) * 7
    return (0..<slotCount).map { slot in
      let dayOffset = slot - leadingDays
      let date =
        (0..<dayCount).contains(dayOffset)
        ? calendar.date(byAdding: .day, value: dayOffset, to: month)
        : nil
      return QFPlanCalendarDay(id: slot, date: date)
    }
  }
}

private struct QFPlanCalendarDay: Identifiable {
  let id: Int
  let date: Date?
}

private struct QFPlanDayButton: View {
  let day: Int
  let month: Int
  let selected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      Text("\(day)")
        .font(.system(size: 16, weight: .medium))
        .foregroundColor(selected ? Color.white : QFTheme.text)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(
          RoundedRectangle(cornerRadius: 10).fill(selected ? QFTheme.orange : Color.clear))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 3)
    .frame(height: 32)
    .accessibilityLabel("\(month)月\(day)日")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct QFPlanSummaryView: View {
  let showsFixture: Bool
  private let titles = ["已完成", "消耗成本", "采购支出"]

  var body: some View {
    HStack(spacing: 10) {
      ForEach(0..<titles.count, id: \.self) { index in
        VStack(alignment: .leading, spacing: 4) {
          Text(titles[index])
            .font(.system(size: 12))
            .foregroundColor(QFTheme.green)
          Text(values[index])
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(QFTheme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 13)
    .background(RoundedRectangle(cornerRadius: 18).fill(QFTheme.paleGreen))
  }

  private var values: [String] {
    showsFixture ? ["3 / 4 道", "¥36.60", "¥54.20"] : ["0 / 0 道", "¥0.00", "¥0.00"]
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

private struct QFPlanMealCard: View {
  let meal: QFPlanMeal
  let onAction: (String) -> Void

  var body: some View {
    VStack(spacing: 12) {
      HStack(spacing: 8) {
        Text(meal.title)
          .font(.system(size: 19, weight: .semibold))
          .foregroundColor(QFTheme.text)
        Spacer(minLength: 0)
        Text(meal.detail)
          .font(.system(size: 12))
          .foregroundColor(meal.title == "午餐" ? QFTheme.orange : QFTheme.secondary)
        Button {
          onAction("调整当餐计划")
        } label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(QFTheme.secondary)
            .frame(width: 24, height: 32)
        }
        .accessibilityLabel("调整\(meal.title)计划")
      }
      ForEach(meal.dishes) { dish in
        QFPlanDishRow(dish: dish, onCheckIn: { onAction("做菜打卡") })
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
    .overlay(RoundedRectangle(cornerRadius: 18).stroke(QFTheme.border, lineWidth: 0.7))
  }
}

private struct QFPlanDishRow: View {
  let dish: QFPlanDish
  let onCheckIn: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(dish.asset)
        .resizable()
        .scaledToFill()
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 5) {
        Text(dish.title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(QFTheme.text)
        Text(dish.detail)
          .font(.system(size: 12))
          .foregroundColor(QFTheme.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(dish.done ? "✓ 已做" : "做菜打卡", action: onCheckIn)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(dish.done ? QFTheme.green : QFTheme.orange)
        .frame(width: 64, height: 30)
        .background(
          Capsule().fill(dish.done ? QFTheme.paleGreen : Color(hex: 0xFFF0E7))
        )
        .buttonStyle(.plain)
    }
  }
}

private struct QFPlanActionBar: View {
  let onAction: (String) -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button {
        onAction("制定计划")
      } label: {
        Text("制定计划")
          .font(.system(size: 18, weight: .medium))
          .foregroundColor(.white)
          .frame(maxWidth: .infinity)
          .frame(height: 49)
          .background(RoundedRectangle(cornerRadius: 17).fill(QFTheme.orange))
      }
      .accessibilityIdentifier("plan.create")
      Button {
        onAction("备菜")
      } label: {
        Text("备菜")
          .font(.system(size: 18, weight: .medium))
          .foregroundColor(QFTheme.text)
          .frame(maxWidth: .infinity)
          .frame(height: 49)
          .background(RoundedRectangle(cornerRadius: 17).fill(Color.white))
          .overlay(RoundedRectangle(cornerRadius: 17).stroke(QFTheme.border, lineWidth: 1))
      }
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 20)
    .padding(.top, 6)
    .padding(.bottom, 7)
    .background(QFTheme.background)
  }
}
