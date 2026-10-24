import SwiftUI
import WidgetKit

struct QFNextMealTimelineEntry: TimelineEntry {
  let date: Date
  let document: QFMealSurfaceDocument?
}

struct QFNextMealTimelineProvider: TimelineProvider {
  func placeholder(in context: Context) -> QFNextMealTimelineEntry {
    // Gallery previews do not invent meals or ingredient stock.
    QFNextMealTimelineEntry(date: Date(), document: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (QFNextMealTimelineEntry) -> Void) {
    completion(QFNextMealTimelineEntry(date: Date(), document: QFMealWidgetStore.read()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<QFNextMealTimelineEntry>) -> Void) {
    let now = Date()
    let document = QFMealWidgetStore.read()
    let expirations: [Date]
    if let document, QFMealSurfaceSelector.effectiveStatus(in: document, now: now) == .ready {
      let cacheExpiry = document.updatedAt.addingTimeInterval(QFMealSurfaceSelector.maximumSnapshotAge + 1)
      expirations = Array(Set(document.entries.filter { QFMealSurfaceSelector.isValid($0) && $0.expiresAt > now }
        .map(\.expiresAt) + [cacheExpiry])).filter { $0 > now }.sorted().prefix(64).map { $0 }
    } else {
      expirations = []
    }
    let dates = [now] + expirations
    let entries = dates.map { QFNextMealTimelineEntry(date: $0, document: document) }
    // Predictable expiry transitions are in the timeline. The app requests a reload on actual changes.
    let refresh = (dates.last ?? now).addingTimeInterval(30 * 60)
    completion(Timeline(entries: entries, policy: .after(refresh)))
  }
}

struct QFNextMealWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: QFMealSurfaceConfiguration.widgetKind, provider: QFNextMealTimelineProvider()) { entry in
      QFNextMealWidgetView(entry: entry)
    }
    .configurationDisplayName(Text("widget.name"))
    .description(Text("widget.description"))
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

private struct QFNextMealWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: QFNextMealTimelineEntry
  private var snapshot: QFMealWidgetSnapshot { .init(document: entry.document, now: max(entry.date, Date())) }

  var body: some View {
    styledContent
      .environment(\.locale, Locale(identifier: snapshot.strings.language))
      .environment(\.timeZone, snapshot.meal.flatMap { TimeZone(identifier: $0.timezone) } ?? .current)
      .widgetURL(snapshot.meal.flatMap { QFMealSurfaceSelector.deepLink(for: $0) })
      .privacySensitive()
  }

  @ViewBuilder private var styledContent: some View {
    if #available(iOS 17.0, *) {
      content.containerBackground(for: .widget) { Color(.systemBackground) }
    } else {
      content.padding(14).background(Color(.systemBackground))
    }
  }

  @ViewBuilder private var content: some View {
    if snapshot.status == .ready, let meal = snapshot.meal {
      mealContent(meal, strings: snapshot.strings)
    } else {
      QFMealSurfaceEmptyView(status: snapshot.status, strings: snapshot.strings)
    }
  }

  private func mealContent(_ meal: QFMealSurfaceEntry, strings: QFMealWidgetStrings) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 5) {
        Image(systemName: "fork.knife").foregroundStyle(QFMealWidgetStyle.accent).accessibilityHidden(true)
        Text(strings.meal(meal.meal)).foregroundStyle(.secondary)
        Spacer(minLength: 4)
        Text(meal.scheduledAt, style: .time).monospacedDigit()
      }
      .font(.caption)

      Text(meal.scheduledAt, style: .date).font(.caption2).foregroundStyle(.secondary)
      let titles = strings.summary(meal.recipeTitles, limit: 2)
      Text(titles.isEmpty ? strings["recipes.unknown"] : titles)
        .font(.headline).lineLimit(1)

      if family == .systemMedium {
        HStack(alignment: .top, spacing: 16) {
          required(meal, strings: strings, lines: 2).frame(maxWidth: .infinity, alignment: .leading)
          stock(meal, strings: strings).frame(maxWidth: .infinity, alignment: .leading)
        }
        if let updated = entry.document?.updatedAt {
          HStack(spacing: 4) {
            Text(strings["updated"])
            Text(updated, style: .time)
          }
          .font(.caption2).foregroundStyle(.secondary)
        }
      } else {
        required(meal, strings: strings, lines: 2)
        if !meal.stockKnown {
          Text(strings["stock.unknown"]).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .combine)
  }

  private func required(_ meal: QFMealSurfaceEntry, strings: QFMealWidgetStrings, lines: Int) -> some View {
    let summary = strings.summary(meal.requiredIngredients)
    return QFMealIngredientLine(title: strings["section.required"],
                               content: summary.isEmpty ? strings["ingredients.unknown"] : summary, lines: lines)
  }

  @ViewBuilder private func stock(_ meal: QFMealSurfaceEntry, strings: QFMealWidgetStrings) -> some View {
    if !meal.stockKnown {
      Text(strings["stock.unknown"]).font(.caption).foregroundStyle(.secondary).lineLimit(2)
    } else {
      VStack(alignment: .leading, spacing: 5) {
        let existing = strings.summary(meal.inStockIngredients)
        let missing = strings.summary(meal.missingIngredients)
        if !existing.isEmpty { QFMealIngredientLine(title: strings["section.in_stock"], content: existing) }
        if !missing.isEmpty { QFMealIngredientLine(title: strings["section.missing"], content: missing) }
        if existing.isEmpty && missing.isEmpty {
          Text(strings["stock.no_details"]).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
    }
  }
}
