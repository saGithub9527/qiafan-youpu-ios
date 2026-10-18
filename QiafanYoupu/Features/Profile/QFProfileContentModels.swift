import Foundation

struct QFCurrencyTotal: Codable { let currency: String; let total: String }
struct QFContentPage<Item: Decodable>: Decodable {
  let items: [Item]
  let total: Int
  var totals: [QFCurrencyTotal]? = nil
  var nearExpiryIngredientCount: Int? = nil
  var expiredIngredientCount: Int? = nil
}
struct QFContentSummary: Codable, Equatable { let favorites: Int; let cookingDays: Int; let publishedWorks: Int; let contributions: Int; var avatarMediaId: String? }
struct QFContentMedia: Codable, Equatable { let id: String; let kind: String; let mimeType: String }
struct QFInterestOption: Codable { let id: String; let name: String; let countryIds: [String]? }
struct QFInterestOptions: Codable {
  let countries: [QFInterestOption]; let cuisines: [QFInterestOption]
  let tastes: [QFInterestOption]; let spiceLevels: [QFInterestOption]
}
struct QFInterests: Codable, Equatable {
  var countryIds: [String] = []; var cuisineIds: [String] = []; var tasteIds: [String] = []
  var spiceLevel: String?; var excludedIngredientIds: [String] = []
}
struct QFWorkMaterial: Codable, Equatable {
  var name = ""; var amount = ""; var unit = "克"; var ingredientId: String?; var usageStatus: String? = nil
  var hasNumericAmount: Bool {
    amount.range(of: "^(?:0|[1-9][0-9]{0,6})(?:\\.[0-9]{1,3})?$", options: .regularExpression) != nil
      && (Decimal(string: amount) ?? 0) > 0
  }
  var cookingValidation: String? {
    if let usageStatus, !["USED", "HAS_REMAINDER"].contains(usageStatus) { return "请核对食材使用状态。" }
    if hasNumericAmount { return validation }
    if Decimal(string: amount) != nil || usageStatus == nil
      || amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || amount.unicodeScalars.count > 100 { return "请核对食材、实际用量和单位。" }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedName.isEmpty || trimmedName.unicodeScalars.count > 100 || unit.unicodeScalars.count > 20 {
      return "请核对食材、实际用量和单位。"
    }
    return nil
  }
  var validation: String? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty || name.unicodeScalars.count > 100 || unit.isEmpty || unit.unicodeScalars.count > 20 { return "材料名称需为1–100字，单位需为1–20字。" }
    if amount.range(of: "^(?:0|[1-9][0-9]{0,6})(?:\\.[0-9]{1,3})?$", options: .regularExpression) == nil || (Decimal(string: amount) ?? 0) <= 0 { return "材料用量需为正数，最多7位整数和3位小数。" }
    return nil
  }
  @MainActor
  func validation(app: QFAppSession) -> String? {
    guard let validation else { return nil }
    switch validation {
    case "材料名称需为1–100字，单位需为1–20字。":
      return app.text(
        "材料名称需为1–100字，单位需为1–20字。",
        "Material name must be 1–100 characters and unit 1–20 characters.")
    case "材料用量需为正数，最多7位整数和3位小数。":
      return app.text(
        "材料用量需为正数，最多7位整数和3位小数。",
        "Amount must be positive, with up to 7 integer and 3 decimal digits.")
    default: return validation
    }
  }
}
struct QFWorkStep: Codable, Equatable { var title = ""; var body = "" }
struct QFWorkDraft: Codable, Equatable {
  var title = ""; var body = ""; var photoIds: [String] = []; var coverMediaId: String?; var videoId: String?
  var materials: [QFWorkMaterial] = []; var steps: [QFWorkStep] = []; var linkedRecipeId: String?
  var validation: String? {
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写菜品名称。" }
    if title.count > 80 { return "菜品名称最多80字。" }
    if photoIds.isEmpty { return "请添加至少一张菜品实拍图。" }
    if materials.isEmpty { return "请添加至少一种材料。" }
    if photoIds.count > 9 || materials.count > 40 || steps.count > 30 { return "最多9张照片、40种材料和30个步骤。" }
    if let error = materials.compactMap(\.validation).first { return error }
    if steps.isEmpty || steps.contains(where: { $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return "请填写完整的做法步骤。" }
    return nil
  }
  @MainActor
  func validation(app: QFAppSession) -> String? {
    guard let validation else { return nil }
    switch validation {
    case "请填写菜品名称。": return app.text("请填写菜品名称。", "Enter a dish name.")
    case "菜品名称最多80字。": return app.text("菜品名称最多80字。", "Dish name must be 80 characters or fewer.")
    case "请添加至少一张菜品实拍图。": return app.text("请添加至少一张菜品实拍图。", "Add at least one photo of the dish.")
    case "请添加至少一种材料。": return app.text("请添加至少一种材料。", "Add at least one material.")
    case "最多9张照片、40种材料和30个步骤。": return app.text("最多9张照片、40种材料和30个步骤。", "Use at most 9 photos, 40 materials, and 30 steps.")
    case "请填写完整的做法步骤。": return app.text("请填写完整的做法步骤。", "Complete every cooking step.")
    default:
      return materials.compactMap { $0.validation(app: app) }.first ?? validation
    }
  }
}

/// A review-only handoff for an assistant recipe proposal.  It is intentionally
/// not a server recipe contract: until a recipe editor page is approved, the
/// handoff can only be recovered from this device and cannot be published.
struct QFAssistantRecipeDraft: Codable, Equatable {
  let id: String
  var title: String
  var body: String
  var materials: [QFWorkMaterial]
  var steps: [QFWorkStep]
  var updatedAt: String?

  init(assistant: QFAssistantPreview, id: String = UUID().uuidString.lowercased()) {
    self.id = id
    title = assistant.title
    body = assistant.body
    materials = assistant.ingredients.map {
      QFWorkMaterial(name: $0.name, amount: $0.quantity, unit: $0.unit, ingredientId: nil)
    }
    steps = assistant.steps.map { QFWorkStep(title: "", body: $0) }
    updatedAt = nil
  }
}

struct QFUserWork: Codable {
  let id: String; let title: String; let body: String; let status: String
  let photoIds: [String]; let coverMediaId: String?; let videoId: String?; let materials: [QFWorkMaterial]; let steps: [QFWorkStep]
  let linkedRecipeId: String?; let authorId: String; let authorName: String; let createdAt: String; let updatedAt: String
  let authorCountryCode: String?; let authorRegionCode: String?; let authorAvatarMediaId: String?
  var reviewNote: String?; var revision: Int?
  var statusTitle: String { ["PUBLISHED": "已发布", "PENDING": "审核中", "REJECTED": "未通过", "DRAFT": "草稿"][status] ?? status }
  @MainActor func statusTitle(app: QFAppSession) -> String {
    switch status {
    case "PUBLISHED": return app.text("已发布", "Published")
    case "PENDING": return app.text("审核中", "In review")
    case "REJECTED": return app.text("未通过", "Not approved")
    case "DRAFT": return app.text("草稿", "Draft")
    default: return status
    }
  }
  var draft: QFWorkDraft { QFWorkDraft(title: title, body: body, photoIds: photoIds, coverMediaId: coverMediaId, videoId: videoId, materials: materials, steps: steps, linkedRecipeId: linkedRecipeId) }
}
struct QFCatalogItem: Codable {
  let id: String; let type: String; let title: String; let subtitle: String
  let mediaId: String?; let materials: [QFWorkMaterial]; let steps: [QFWorkStep]; let minutes: Int?
  let sourceName: String?; let sourceUrl: String?; let license: String?; let licenseUrl: String?; let attribution: String?
  var categoryCode: String? = nil; var iconKey: String? = nil; var inStock: Bool? = nil
}
struct QFFavoriteItem: Codable { let id: String; let type: String; let title: String; let subtitle: String; let mediaId: String? }
struct QFContribution: Codable {
  let id: String; let targetType: String; let targetId: String; let targetTitle: String; let mediaId: String
  let status: String; let reason: String?; let withdrawalRequested: Bool; let createdAt: String
  var statusTitle: String {
    if withdrawalRequested { return "撤回申请处理中" }
    return ["PENDING": "审核中", "ACCEPTED": "已采用", "REJECTED": "未采用", "WITHDRAWN": "已撤回"][status] ?? status
  }
  @MainActor func statusTitle(app: QFAppSession) -> String {
    if withdrawalRequested { return app.text("撤回申请处理中", "Withdrawal requested") }
    switch status {
    case "PENDING": return app.text("审核中", "In review")
    case "ACCEPTED": return app.text("已采用", "Accepted")
    case "REJECTED": return app.text("未采用", "Not accepted")
    case "WITHDRAWN": return app.text("已撤回", "Withdrawn")
    default: return status
    }
  }
}
struct QFContributionDraft: Codable, Equatable {
  var id = UUID().uuidString.lowercased(); var targetType = "INGREDIENT"; var targetId: String?
  var targetTitle = ""; var mediaId: String?; var rightsAccepted = false
}
enum QFCookingMeal: String, CaseIterable {
  case breakfast = "BREAKFAST", lunch = "LUNCH", dinner = "DINNER", snack = "SNACK", other = "OTHER"
  var title: String {
    switch self {
    case .breakfast: return "早餐"
    case .lunch: return "午餐"
    case .dinner: return "晚餐"
    case .snack: return "加餐"
    case .other: return "其他"
    }
  }
  @MainActor func title(app: QFAppSession) -> String {
    switch self {
    case .breakfast: return app.text("早餐", "Breakfast")
    case .lunch: return app.text("午餐", "Lunch")
    case .dinner: return app.text("晚餐", "Dinner")
    case .snack: return app.text("加餐", "Snack")
    case .other: return app.text("其他", "Other")
    }
  }
}
struct QFCookingRecord: Codable, Equatable {
  var id = UUID().uuidString.lowercased(); var date = QFContentDate.day(Date()); var title = ""; var meal = "LUNCH"
  var currency = "CNY"; var cost: String?; var materials: [QFWorkMaterial] = []; var note = ""
  var plannedMealId: String?
  var expectedPlanRevision: Int?
  var inventoryMode: String?
  var revision: Int?
  var mealTitle: String { QFCookingMeal(rawValue: meal)?.title ?? "未选择餐次" }
  var validation: String? {
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 80 { return "请填写80字以内的菜品名称。" }
    if date > QFContentDate.day(Date()) || !Locale.isoCurrencyCodes.contains(currency) { return "请检查日期和币种。" }
    if QFCookingMeal(rawValue: meal) == nil { return "请选择餐次。" }
    if let cost, cost.range(of: "^(?:0|[1-9][0-9]{0,7})(?:\\.[0-9]{1,2})?$", options: .regularExpression) == nil { return "成本最多8位整数和2位小数，未知时请留空。" }
    if materials.isEmpty || materials.count > 40 { return "请添加1–40种材料。" }
    if let error = materials.compactMap({ plannedMealId == nil ? $0.validation : $0.cookingValidation }).first { return error }
    return nil
  }
  @MainActor
  func mealTitle(app: QFAppSession) -> String {
    QFCookingMeal(rawValue: meal)?.title(app: app) ?? app.text("未选择餐次", "No meal selected")
  }
  @MainActor
  func validation(app: QFAppSession) -> String? {
    guard let validation else { return nil }
    switch validation {
    case "请填写80字以内的菜品名称。": return app.text("请填写80字以内的菜品名称。", "Enter a dish name of up to 80 characters.")
    case "请检查日期和币种。": return app.text("请检查日期和币种。", "Check the date and currency.")
    case "请选择餐次。": return app.text("请选择餐次。", "Choose a meal.")
    case "成本最多8位整数和2位小数，未知时请留空。": return app.text(
      "成本最多8位整数和2位小数，未知时请留空。",
      "Cost may have up to 8 integer and 2 decimal digits. Leave it blank if unknown.")
    case "请添加1–40种材料。": return app.text("请添加1–40种材料。", "Add 1–40 materials.")
    case "请核对食材使用状态。": return app.text("请核对食材使用状态。", "Check ingredient usage status.")
    case "请核对食材、实际用量和单位。": return app.text("请核对食材、实际用量和单位。", "Confirm each ingredient, actual quantity and unit.")
    default: return materials.compactMap { $0.validation(app: app) }.first ?? validation
    }
  }
  var requestBody: QFCookingDraft {
    QFCookingDraft(
      date: date, title: title, meal: meal, currency: currency, cost: cost,
      materials: materials, note: note, plannedMealId: plannedMealId,
      expectedPlanRevision: expectedPlanRevision)
  }
}
struct QFCookingDraft: Codable {
  let date: String; let title: String; let meal: String; let currency: String
  let cost: String?; let materials: [QFWorkMaterial]; let note: String; let plannedMealId: String?
  var expectedPlanRevision: Int? = nil
  var expectedRevision: Int? = nil
  var requestId: String? = nil
}
struct QFRightsClaim: Codable {
  var id = UUID().uuidString.lowercased(); var target = ""; var description = ""; var contact = ""
  var signature = ""; var statementAccepted = false; var status: String?; var createdAt: String?; var reviewNote: String?
}
enum QFContentDate {
  static func format(_ date: Date, _ pattern: String) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = pattern
    return formatter.string(from: date)
  }
  static func day(_ date: Date) -> String { format(date, "yyyy-MM-dd") }
  static func month(_ date: Date) -> String { format(date, "yyyy-MM") }
}

/// User-scoped small local drafts; media bytes stay in the protected local draft directory.
@MainActor
enum QFContentDraftStore {
  private static func key(_ app: QFAppSession, _ kind: String) -> String? {
    guard let user = app.user else { return nil }
    return "qf.profile.draft.\(app.api.environment.name).\(user.userId).\(kind)"
  }
  @discardableResult
  static func save<T: Encodable>(_ value: T, app: QFAppSession, kind: String) -> Bool {
    guard let key = key(app, kind), let data = try? JSONEncoder().encode(value),
      data.count <= 2 * 1024 * 1024
    else { return false }
    UserDefaults.standard.set(data, forKey: key)
    return UserDefaults.standard.data(forKey: key) == data
  }
  static func load<T: Decodable>(_ type: T.Type, app: QFAppSession, kind: String) -> T? {
    guard let key = key(app, kind), let data = UserDefaults.standard.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }
  static func all<T: Decodable>(_ type: T.Type, app: QFAppSession, prefix: String) -> [T] {
    guard let prefix = key(app, prefix) else { return [] }
    return UserDefaults.standard.dictionaryRepresentation().compactMap { key, value in
      guard key.hasPrefix(prefix), let data = value as? Data else { return nil }
      return try? JSONDecoder().decode(type, from: data)
    }
  }
  static func remove(app: QFAppSession, kind: String) { if let key = key(app, kind) { UserDefaults.standard.removeObject(forKey: key) } }
  static func removeAll(environment: String, userID: String) {
    let prefix = "qf.profile.draft.\(environment).\(userID)."
    for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
}

extension QFContentPage: Encodable where Item: Encodable {}
