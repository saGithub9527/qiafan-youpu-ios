import Foundation
import SwiftUI

enum QFMealWidgetStore {
  static func read() -> QFMealSurfaceDocument? {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: QFMealSurfaceConfiguration.appGroupID) else { return nil }
    let url = container.appendingPathComponent(QFMealSurfaceConfiguration.fileName, isDirectory: false)
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard let size = attributes[.size] as? NSNumber, size.intValue <= 512 * 1024 else { return nil }
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      guard data.count <= 512 * 1024 else { return nil }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(QFMealSurfaceDocument.self, from: data)
    } catch {
      // Locked, absent or corrupt cache is unavailable, never sample business data.
      return nil
    }
  }
}

struct QFMealWidgetStrings {
  let language: String
  private let bundle: Bundle

  init(language: String?) {
    let selected = language.flatMap { QFMealSurfaceSelector.supportedLanguages.contains($0) ? $0 : nil }
      ?? Self.preferredLanguage()
    self.language = selected
    self.bundle = Bundle.main.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
  }

  subscript(_ key: String) -> String {
    bundle.localizedString(forKey: key, value: nil, table: "Localizable")
  }

  func meal(_ value: String) -> String {
    self["meal." + value.lowercased()]
  }

  func summary(_ values: [String], limit: Int = 3) -> String {
    let names = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    let visible = names.prefix(limit).joined(separator: " · ")
    return visible + (names.count > limit ? " …" : "")
  }

  private static func preferredLanguage() -> String {
    for candidate in Locale.preferredLanguages {
      if QFMealSurfaceSelector.supportedLanguages.contains(candidate) { return candidate }
      if candidate.hasPrefix("zh") {
        return candidate.contains("Hant") || candidate.hasPrefix("zh-TW") || candidate.hasPrefix("zh-HK") ? "zh-Hant" : "zh-Hans"
      }
      if candidate.hasPrefix("pt") { return "pt-BR" }
      if let match = ["en", "ja", "ko", "ru", "es", "fr", "de"].first(where: { candidate == $0 || candidate.hasPrefix($0 + "-") }) { return match }
    }
    return "en"
  }
}

struct QFMealWidgetSnapshot {
  let document: QFMealSurfaceDocument?
  let now: Date
  var strings: QFMealWidgetStrings { QFMealWidgetStrings(language: document?.language) }
  var status: QFMealSurfaceStatus { QFMealSurfaceSelector.effectiveStatus(in: document, now: now) }
  var meal: QFMealSurfaceEntry? {
    guard let document else { return nil }
    return QFMealSurfaceSelector.currentEntry(in: document, now: now)
  }
}

enum QFMealWidgetStyle {
  static let accent = Color(red: 196.0 / 255, green: 73.0 / 255, blue: 40.0 / 255)
}

struct QFMealSurfaceEmptyView: View {
  let status: QFMealSurfaceStatus
  let strings: QFMealWidgetStrings

  private var key: String { status == .ready ? "unavailable" : status.rawValue == "signedOut" ? "signed_out" : status.rawValue }
  private var symbol: String {
    switch status {
    case .signedOut: return "person.crop.circle"
    case .disabled: return "calendar.badge.minus"
    case .empty: return "calendar"
    case .ready, .unavailable: return "arrow.clockwise.circle"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Image(systemName: symbol).font(.title2).foregroundStyle(QFMealWidgetStyle.accent).accessibilityHidden(true)
      Text(strings["status.\(key).title"]).font(.headline).lineLimit(2)
      Text(strings["status.\(key).detail"]).font(.caption).foregroundStyle(.secondary).lineLimit(3)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

struct QFMealIngredientLine: View {
  let title: String
  let content: String
  var lines: Int = 1

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      Text(content).font(.caption).lineLimit(lines)
    }
    .accessibilityElement(children: .combine)
  }
}
