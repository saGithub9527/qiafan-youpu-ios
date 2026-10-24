import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
struct QFMealLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: QFMealActivityAttributes.self) { context in
      let snapshot = QFMealActivitySnapshot(context: context)
      QFMealActivityLockScreenView(snapshot: snapshot)
        .environment(\.locale, Locale(identifier: snapshot.strings.language))
        .environment(\.timeZone, snapshot.meal.flatMap { TimeZone(identifier: $0.timezone) } ?? .current)
        .activityBackgroundTint(Color(.systemBackground))
        .activitySystemActionForegroundColor(.primary)
        .widgetURL(snapshot.url)
        .privacySensitive()
    } dynamicIsland: { context in
      let snapshot = QFMealActivitySnapshot(context: context)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label(snapshot.meal.map { snapshot.strings.meal($0.meal) } ?? snapshot.strings["widget.name"], systemImage: "fork.knife")
            .font(.caption).foregroundStyle(QFMealWidgetStyle.accent).privacySensitive()
        }
        DynamicIslandExpandedRegion(.trailing) {
          if let meal = snapshot.meal {
            QFMealActivityTimeView(meal: meal, strings: snapshot.strings)
              .environment(\.timeZone, TimeZone(identifier: meal.timezone) ?? .current)
              .foregroundStyle(.white).privacySensitive()
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          QFMealActivityDetailsView(snapshot: snapshot, expanded: true)
            .foregroundStyle(.white)
            .environment(\.locale, Locale(identifier: snapshot.strings.language))
            .privacySensitive()
        }
      } compactLeading: {
        Image(systemName: snapshot.meal == nil ? "calendar.badge.exclamationmark" : "fork.knife")
          .foregroundStyle(QFMealWidgetStyle.accent).accessibilityLabel(snapshot.strings["widget.name"])
          .privacySensitive()
      } compactTrailing: {
        if let meal = snapshot.meal {
          QFMealActivityCountdown(meal: meal)
            .font(.caption2).monospacedDigit().frame(maxWidth: 58)
            .accessibilityLabel(snapshot.strings["live.countdown"])
            .privacySensitive()
        } else {
          Image(systemName: "arrow.clockwise").accessibilityLabel(snapshot.strings["status.unavailable.title"])
        }
      } minimal: {
        Image(systemName: snapshot.meal == nil ? "calendar.badge.exclamationmark" : "fork.knife")
          .foregroundStyle(QFMealWidgetStyle.accent)
          .accessibilityLabel(snapshot.strings["widget.name"])
          .privacySensitive()
      }
      .widgetURL(snapshot.url)
      .keylineTint(QFMealWidgetStyle.accent)
    }
  }
}

@available(iOS 16.1, *)
private struct QFMealActivitySnapshot {
  let strings: QFMealWidgetStrings
  let status: QFMealSurfaceStatus
  let meal: QFMealSurfaceEntry?
  var url: URL? { meal.flatMap { QFMealSurfaceSelector.deepLink(for: $0) } }

  init(context: ActivityViewContext<QFMealActivityAttributes>) {
    let now = Date()
    let document = QFMealWidgetStore.read()
    strings = QFMealWidgetStrings(language: document?.language)
    let cachedStatus = QFMealSurfaceSelector.effectiveStatus(in: document, now: now)
    let isStale: Bool
    if #available(iOS 16.2, *) { isStale = context.isStale }
    else { isStale = context.state.expiresAt <= now }
    guard let document, document.schemaVersion == 1,
          document.status != .signedOut, document.status != .disabled,
          document.scopeKey == context.attributes.scopeKey,
          QFMealSurfaceSelector.supportedLanguages.contains(document.language),
          context.state.id == context.attributes.entryID,
          QFMealSurfaceSelector.isValid(context.state), context.state.expiresAt > now,
          !isStale else {
      status = cachedStatus == .ready ? .unavailable : cachedStatus
      meal = nil
      return
    }
    // Remote ContentState is authoritative while the host is suspended. The shared scope is only
    // the privacy gate; requiring an old cached meal would discard remote starts and updates.
    status = .ready
    meal = context.state
  }
}

@available(iOS 16.1, *)
private struct QFMealActivityLockScreenView: View {
  let snapshot: QFMealActivitySnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      if let meal = snapshot.meal {
        HStack(spacing: 6) {
          Image(systemName: "fork.knife").foregroundStyle(QFMealWidgetStyle.accent).accessibilityHidden(true)
          Text(snapshot.strings.meal(meal.meal)).font(.caption.weight(.semibold))
          Spacer(minLength: 8)
          QFMealActivityTimeView(meal: meal, strings: snapshot.strings)
        }
        QFMealActivityDetailsView(snapshot: snapshot, expanded: false)
      } else {
        QFMealSurfaceEmptyView(status: snapshot.status, strings: snapshot.strings)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

@available(iOS 16.1, *)
private struct QFMealActivityTimeView: View {
  let meal: QFMealSurfaceEntry
  let strings: QFMealWidgetStrings

  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(strings["live.countdown"]).font(.caption2)
      QFMealActivityCountdown(meal: meal).font(.caption.weight(.semibold)).monospacedDigit()
    }
    .accessibilityElement(children: .combine)
  }
}

@available(iOS 16.1, *)
private struct QFMealActivityCountdown: View {
  let meal: QFMealSurfaceEntry

  var body: some View {
    // System-managed timer clamps at the meal time; it doesn't turn into a growing elapsed timer.
    Text(timerInterval: min(Date(), meal.scheduledAt)...meal.scheduledAt,
         countsDown: true, showsHours: true)
  }
}

@available(iOS 16.1, *)
private struct QFMealActivityDetailsView: View {
  let snapshot: QFMealActivitySnapshot
  let expanded: Bool

  var body: some View {
    if let meal = snapshot.meal {
      VStack(alignment: .leading, spacing: 7) {
        let titles = snapshot.strings.summary(meal.recipeTitles, limit: 2)
        Text(titles.isEmpty ? snapshot.strings["recipes.unknown"] : titles)
          .font(.headline).lineLimit(expanded ? 2 : 1)
        HStack(alignment: .top, spacing: 14) {
          let required = snapshot.strings.summary(meal.requiredIngredients)
          QFMealIngredientLine(title: snapshot.strings["section.required"],
                               content: required.isEmpty ? snapshot.strings["ingredients.unknown"] : required,
                               lines: expanded ? 2 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
          stock(meal).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
    } else {
      QFMealSurfaceEmptyView(status: snapshot.status, strings: snapshot.strings)
    }
  }

  @ViewBuilder private func stock(_ meal: QFMealSurfaceEntry) -> some View {
    if !meal.stockKnown {
      Text(snapshot.strings["stock.unknown"]).font(.caption).lineLimit(2)
    } else {
      VStack(alignment: .leading, spacing: 4) {
        let existing = snapshot.strings.summary(meal.inStockIngredients)
        let missing = snapshot.strings.summary(meal.missingIngredients)
        if !existing.isEmpty { QFMealIngredientLine(title: snapshot.strings["section.in_stock"], content: existing) }
        if !missing.isEmpty { QFMealIngredientLine(title: snapshot.strings["section.missing"], content: missing) }
        if existing.isEmpty && missing.isEmpty {
          Text(snapshot.strings["stock.no_details"]).font(.caption).lineLimit(2)
        }
      }
    }
  }
}
