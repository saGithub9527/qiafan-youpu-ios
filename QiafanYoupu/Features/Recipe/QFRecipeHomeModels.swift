import Foundation

// DESIGN_BASELINE: recipe-home-r7
// Source: 全球菜谱APP-设计档案/01-当前设计/01-菜谱与筛选/页面与交互.json
// Server data may change content and state, but not this approved page geometry.
enum QFRecipeHomeLayout {
  static let pageHorizontalInset: CGFloat = 20
  static let categoryControlLeading: CGFloat = 12
  static let categoryTopOffset: CGFloat = 5
  static let categoryHeight: CGFloat = 44
  static let categorySpacing: CGFloat = 8
  static let filterTopGap: CGFloat = 12
  static let filterHeight: CGFloat = 47
  static let filterSpacing: CGFloat = 6
  static let sectionHeight: CGFloat = 39
  static let listTopGap: CGFloat = 1
  static let cardMinimumHeight: CGFloat = 128
  static let cardImageSize: CGFloat = 108
  static let cardGap: CGFloat = 12
  static let cardCornerRadius: CGFloat = 18
}

struct QFRecipeOption: Codable, Hashable {
  let id: String
  let name: String
  let countryIds: [String]?
}

struct QFRecipeHomeOptions: Codable {
  let categories: [QFRecipeOption]
  let countries: [QFRecipeOption]
  let cuisines: [QFRecipeOption]
  let tastes: [QFRecipeOption]
  let ratingPresets: [Double]
}

struct QFRecipeEngagement: Codable, Equatable {
  let favoriteCount: Int
  let ratingAverage: Double?
  let ratingCount: Int
  let isFavorite: Bool
  let myRating: Int?
}

struct QFRecipeHomeItem: Codable, Equatable {
  let id: String
  let title: String
  let subtitle: String
  let mediaId: String?
  let minutes: Int?
  let servings: Int?
  var favoriteCount: Int
  var ratingAverage: Double?
  var ratingCount: Int
  var isFavorite: Bool
  var myRating: Int?
  let categoryIds: [String]
  let cuisineIds: [String]
  let tasteIds: [String]
  let countryCodes: [String]

  mutating func apply(_ engagement: QFRecipeEngagement) {
    favoriteCount = engagement.favoriteCount
    ratingAverage = engagement.ratingAverage
    ratingCount = engagement.ratingCount
    isFavorite = engagement.isFavorite
    myRating = engagement.myRating
  }
}

struct QFRecipeHomeDetail: Codable {
  let id: String
  let title: String
  let subtitle: String
  let mediaId: String?
  let minutes: Int?
  let servings: Int?
  var favoriteCount: Int
  var ratingAverage: Double?
  var ratingCount: Int
  var isFavorite: Bool
  var myRating: Int?
  let categoryIds: [String]
  let cuisineIds: [String]
  let tasteIds: [String]
  let countryCodes: [String]
  let contentLanguage: String?
  let contentAvailable: Bool?
  let materials: [QFWorkMaterial]
  let steps: [QFWorkStep]
  let sourceName: String?
  let sourceUrl: String?
  let license: String?
  let licenseUrl: String?
  let attribution: String?
  var directions: QFRecipeDirections.Projection {
    QFRecipeDirections.project(steps.map { .init(title: $0.title, body: $0.body) })
  }
  var cookingSteps: [QFWorkStep] { directions.actions.map { .init(title: $0.title, body: $0.body) } }

  var listItem: QFRecipeHomeItem {
    QFRecipeHomeItem(
      id: id, title: title, subtitle: subtitle, mediaId: mediaId, minutes: minutes,
      servings: servings, favoriteCount: favoriteCount, ratingAverage: ratingAverage,
      ratingCount: ratingCount, isFavorite: isFavorite, myRating: myRating,
      categoryIds: categoryIds, cuisineIds: cuisineIds, tasteIds: tasteIds,
      countryCodes: countryCodes)
  }

  mutating func apply(_ engagement: QFRecipeEngagement) {
    favoriteCount = engagement.favoriteCount
    ratingAverage = engagement.ratingAverage
    ratingCount = engagement.ratingCount
    isFavorite = engagement.isFavorite
    myRating = engagement.myRating
  }
}

struct QFRecipeRatingRequest: Encodable { let rating: Int }

struct QFRecipeFilterState: Equatable {
  var categoryID: String?
  var countryID: String?
  var tasteID: String?
  var cuisineID: String?
  var minimumRating: Double?

  mutating func clearSecondaryFilters() {
    countryID = nil
    tasteID = nil
    cuisineID = nil
    minimumRating = nil
  }

  func query(page: Int, search: String? = nil) -> [String: String] {
    var result = ["page": String(page)]
    if let categoryID, !Self.representsAll(categoryID) { result["category"] = categoryID }
    if let countryID, !Self.representsAll(countryID) { result["country"] = countryID }
    if let tasteID, !Self.representsAll(tasteID) { result["taste"] = tasteID }
    if let cuisineID, !Self.representsAll(cuisineID) { result["cuisine"] = cuisineID }
    if let minimumRating { result["minRating"] = Self.ratingString(minimumRating) }
    if let search {
      let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { result["q"] = text }
    }
    return result
  }

  static func representsAll(_ id: String) -> Bool {
    ["ALL", "GLOBAL", "RECOMMENDED", "UNLIMITED", "NONE"].contains(id.uppercased())
  }

  static func ratingString(_ value: Double) -> String {
    String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
  }

  static func ratingDisplayString(_ value: Double, language: QFInterfaceLanguage) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: language.localeIdentifier)
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 1
    formatter.maximumFractionDigits = 1
    formatter.usesGroupingSeparator = false
    return formatter.string(from: NSNumber(value: value)) ?? ratingString(value)
  }
}

enum QFRecipeArtwork {
  static func asset(for item: QFRecipeHomeItem) -> String {
    // A category or keyword cannot identify the pictured dish. Use the neutral recipe artwork
    // until this recipe has its own mediaId, so the fallback never depicts another dish.
    "dish-generic"
  }

  static func asset(for detail: QFRecipeHomeDetail) -> String { asset(for: detail.listItem) }
}
