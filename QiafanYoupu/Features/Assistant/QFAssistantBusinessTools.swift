import Foundation

/// Read-only adapters over the same authenticated, localized APIs used by the pages.
/// Evidence is data, never an instruction or a receipt for a business mutation.
@MainActor
enum QFAssistantBusinessTools {
  private static let evidenceLimit = 3_500

  static func execute(_ call: QFAgentToolCall, app: QFAppSession) async throws -> QFAgentToolResult {
    let context = ReadContext(app: app)
    try context.check(app)
    do {
      guard context.networkAllowed else {
        throw ReadFailure("NETWORK_DISABLED", status: "DENIED")
      }
      switch call.name {
      case "recipe.search":
        try validateKeys(call.arguments, allowed: ["query"])
        let query = try searchQuery(call.arguments["query"], required: true)
        let page: QFContentPage<QFRecipeHomeItem> = try await app.publicContentRequest(
          path: "home/recipes", query: ["q": query, "page": "0"])
        try context.check(app)
        guard page.total >= page.items.count, page.total == 0 || !page.items.isEmpty else {
          throw ReadFailure("INCONSISTENT_PAGE")
        }
        var items = Array(page.items.prefix(3))
        func payload() -> [String: Any] {
          base(context, fields: [
            "query": query, "total": page.total, "returned": items.count,
            "hasMore": page.total > items.count,
            "truncated": page.items.count > items.count,
            "items": items.map { item in
              ["id": item.id, "title": item.title, "subtitle": item.subtitle,
               "minutes": json(item.minutes), "servings": json(item.servings)] as [String: Any]
            }
          ])
        }
        while try byteCount(payload()) > evidenceLimit, !items.isEmpty { items.removeLast() }
        guard page.items.isEmpty || !items.isEmpty else { throw ReadFailure("EVIDENCE_LIMIT_EXCEEDED") }
        let sources = items.map { source(id: "recipe:\($0.id)", title: $0.title) }
        return try result(call, context: context, app: app, payload: payload(), sources: sources)

      case "recipe.detail":
        try validateKeys(call.arguments, allowed: ["recipe_id"])
        guard let id = call.arguments["recipe_id"], let uuid = UUID(uuidString: id) else {
          throw ReadFailure("INVALID_RECIPE_ID", status: "DENIED")
        }
        let detail: QFRecipeHomeDetail = try await app.publicContentRequest(
          path: "home/recipes/\(uuid.uuidString.lowercased())")
        try context.check(app)
        guard UUID(uuidString: detail.id) == uuid else { throw ReadFailure("RESPONSE_ID_MISMATCH") }
        guard detail.contentAvailable == true, detail.contentLanguage == context.language else {
          return try result(
            call, context: context, app: app, status: "UNAVAILABLE",
            payload: base(context, fields: ["id": detail.id, "contentAvailable": false,
              "contentLanguage": json(detail.contentLanguage), "error": "CONTENT_LANGUAGE_UNAVAILABLE"]),
            sources: [source(id: "recipe:\(detail.id)", title: detail.id)])
        }
        let citation = source(
          id: "recipe:\(detail.id)", title: detail.title, url: sourceURL(detail.sourceUrl))
        var materials = detail.materials
        let originalSteps = detail.cookingSteps
        var steps = originalSteps
        func payload() -> [String: Any] {
          base(context, fields: [
            "id": detail.id, "title": detail.title, "subtitle": detail.subtitle,
            "minutes": json(detail.minutes), "servings": json(detail.servings),
            "contentLanguage": json(detail.contentLanguage), "contentAvailable": true,
            "sourceName": json(detail.sourceName), "sourceURL": json(sourceURL(detail.sourceUrl)),
            "license": json(detail.license), "licenseURL": json(sourceURL(detail.licenseUrl)),
            "attribution": json(detail.attribution),
            "materialCount": detail.materials.count, "stepCount": originalSteps.count,
            "omittedMaterials": detail.materials.count - materials.count,
            "omittedSteps": originalSteps.count - steps.count,
            "truncated": materials.count != detail.materials.count || steps.count != originalSteps.count,
            "materials": materials.map { material in
              ["name": material.name, "amount": material.amount, "unit": material.unit,
               "ingredientId": json(material.ingredientId), "usageStatus": json(material.usageStatus)]
            },
            "steps": steps.enumerated().map { index, step in
              ["number": index + 1, "title": step.title, "body": step.body] as [String: Any]
            }
          ])
        }
        // Keep complete original entries in their original order; omissions remain explicit.
        while try byteCount(payload()) > evidenceLimit {
          if !steps.isEmpty { steps.removeLast() }
          else if !materials.isEmpty { materials.removeLast() }
          else { throw ReadFailure("EVIDENCE_LIMIT_EXCEEDED") }
        }
        return try result(call, context: context, app: app, payload: payload(), sources: [citation])

      case "plan.read":
        try validateKeys(call.arguments, allowed: ["date"])
        try requireSignIn(context)
        guard let date = call.arguments["date"], validDate(date) else {
          throw ReadFailure("INVALID_DATE", status: "DENIED")
        }
        let day = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
          try await app.planDay(date: date, householdID: context.householdID)
        }
        try context.check(app)
        guard day.date == date, day.slots.allSatisfy({ slot in
          slot.items.allSatisfy {
            $0.date == date && $0.meal == slot.meal && sameHousehold($0.householdId, context.householdID)
          }
        }) else { throw ReadFailure("RESPONSE_SCOPE_MISMATCH", status: "DENIED") }
        var includedCounts = day.slots.map { $0.items.count }
        let unavailableCount = day.slots.reduce(0) { $0 + $1.items.filter { !$0.contentAvailable }.count }
        func payload() -> [String: Any] {
          base(context, fields: [
            "date": day.date, "slotIdentifierKind": "DATE_AND_MEAL",
            "unavailableContentCount": unavailableCount,
            "truncated": day.slots.enumerated().contains { includedCounts[$0.offset] < $0.element.items.count },
            "slots": day.slots.enumerated().map { index, slot in
              ["date": day.date, "meal": slot.meal, "revision": slot.revision,
               "itemCount": slot.items.count, "omittedItems": slot.items.count - includedCounts[index],
               "items": slot.items.prefix(includedCounts[index]).map { item in
                 ["id": item.id, "recipeId": item.recipeId,
                  "title": item.contentAvailable ? json(item.title) : NSNull(),
                  "date": item.date, "meal": item.meal, "servings": item.servings,
                  "revision": item.revision, "completed": item.completed, "skipped": item.skipped,
                  "contentAvailable": item.contentAvailable] as [String: Any]
               }] as [String: Any]
            }
          ])
        }
        while try byteCount(payload()) > evidenceLimit {
          guard let index = includedCounts.lastIndex(where: { $0 > 0 }) else {
            throw ReadFailure("EVIDENCE_LIMIT_EXCEEDED")
          }
          includedCounts[index] -= 1
        }
        guard day.slots.allSatisfy({ $0.items.isEmpty }) || includedCounts.contains(where: { $0 > 0 }) else {
          throw ReadFailure("EVIDENCE_LIMIT_EXCEEDED")
        }
        let sources = day.slots.map { slot in
          let meal = slot.meal == "BREAKFAST" ? app.text("早餐", "Breakfast") : (slot.meal == "LUNCH" ? app.text("午餐", "Lunch") : app.text("晚餐", "Dinner"))
          return source(id: "plan-slot:\(context.householdID ?? "personal"):\(date):\(slot.meal)",
                 title: "\(date) / \(meal)", revision: String(slot.revision))
        }
        return try result(call, context: context, app: app,
          status: unavailableCount > 0 ? "UNAVAILABLE" : "SUCCEEDED", payload: payload(), sources: sources)

      case "inventory.read":
        try validateKeys(call.arguments, allowed: ["query"])
        try requireSignIn(context)
        let query = try searchQuery(call.arguments["query"], required: false)
        let first = try await inventoryPage(0, query: query, context: context, app: app)
        var lots = first.items
        var total = first.total
        var pagesRead = 1
        var paginationUnstable = false
        if !first.items.isEmpty, first.items.count < first.total {
          let second = try await inventoryPage(1, query: query, context: context, app: app)
          pagesRead = 2
          var seen = Set(lots.map(\.id))
          paginationUnstable = second.total != first.total || second.items.isEmpty
          for lot in second.items {
            if seen.insert(lot.id).inserted { lots.append(lot) }
            else { paginationUnstable = true }
          }
          total = second.total
        }
        try context.check(app)
        guard lots.allSatisfy({ sameHousehold($0.householdId, context.householdID) }) else {
          throw ReadFailure("RESPONSE_SCOPE_MISMATCH", status: "DENIED")
        }
        let unavailableCount = lots.filter { !$0.contentAvailable }.count
        var included = lots
        let today = dateFormatter(timeZone: context.timeZone).string(from: Date())
        func payload() -> [String: Any] {
          base(context, fields: [
            "query": query, "total": total, "pagesRead": pagesRead, "fetchedCount": lots.count,
            "returned": included.count, "omittedFetchedItems": lots.count - included.count,
            "hasMore": total > included.count || paginationUnstable,
            "truncated": included.count < lots.count || total > included.count || paginationUnstable,
            "paginationUnstable": paginationUnstable, "unavailableContentCount": unavailableCount,
            "availabilityAssessment": "NOT_PERFORMED", "unitConversionPerformed": false,
            "asOfDate": today, "timeZone": context.timeZone,
            "items": included.map { lot in
              ["id": lot.id, "ingredientId": lot.ingredientId,
               "ingredientName": lot.contentAvailable ? json(lot.ingredientName) : NSNull(),
               "unitCode": lot.unitCode, "quantity": lot.currentQuantity, "status": lot.status,
               "expiresOn": json(lot.expiresOn), "revision": lot.revision,
               "contentAvailable": lot.contentAvailable,
               "excludedFromPlanningReasons": exclusionReasons(lot, today: today)] as [String: Any]
            }
          ])
        }
        while try byteCount(payload()) > evidenceLimit, !included.isEmpty { included.removeLast() }
        guard lots.isEmpty || !included.isEmpty else { throw ReadFailure("EVIDENCE_LIMIT_EXCEEDED") }
        let sources = included.map {
          source(id: "inventory-lot:\($0.id)",
                 title: $0.contentAvailable ? ($0.ingredientName ?? $0.id) : $0.id,
                 revision: String($0.revision))
        }
        return try result(call, context: context, app: app,
          status: unavailableCount > 0 ? "UNAVAILABLE" : "SUCCEEDED", payload: payload(), sources: sources)

      default:
        throw ReadFailure("UNKNOWN_TOOL", status: "DENIED")
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      try context.check(app)
      let failure = error as? ReadFailure
      let apiError = error as? QFAPIError
      let status = failure?.status ?? (apiError?.code == 40100 || apiError?.code == 40300 ? "DENIED" : "FAILED")
      var fields: [String: Any] = ["error": failure?.code ?? "BUSINESS_READ_FAILED"]
      if let apiError { fields["apiCode"] = apiError.code }
      return try result(call, context: context, app: app, status: status,
                        payload: base(context, fields: fields), sources: [])
    }
  }

  @MainActor
  private struct ReadContext {
    let scope: String
    let householdID: String?
    let language: String
    let userID: String?
    let timeZone: String
    let networkAllowed: Bool

    init(app: QFAppSession) {
      scope = app.contentScope
      householdID = app.planningHouseholdID
      language = app.interfaceLanguage
      userID = app.user?.userId
      timeZone = TimeZone.current.identifier
      networkAllowed = QFLocalModelViewController.networkEnabled(app)
    }

    func check(_ app: QFAppSession) throws {
      try Task.checkCancellation()
      guard scope == app.contentScope, householdID == app.planningHouseholdID,
            language == app.interfaceLanguage, userID == app.user?.userId,
            timeZone == TimeZone.current.identifier,
            networkAllowed == QFLocalModelViewController.networkEnabled(app) else { throw CancellationError() }
    }
  }

  private struct ReadFailure: Error {
    let code: String
    let status: String
    init(_ code: String, status: String = "FAILED") { self.code = code; self.status = status }
  }

  private static func validateKeys(_ arguments: [String: String], allowed: Set<String>) throws {
    guard Set(arguments.keys).isSubset(of: allowed) else {
      throw ReadFailure("UNSUPPORTED_ARGUMENT", status: "DENIED")
    }
  }

  private static func searchQuery(_ value: String?, required: Bool) throws -> String {
    let query = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.unicodeScalars.count <= 100, !query.unicodeScalars.contains(where: { $0.value == 0 }),
          !required || !query.isEmpty else { throw ReadFailure("INVALID_QUERY", status: "DENIED") }
    return query
  }

  private static func requireSignIn(_ context: ReadContext) throws {
    guard context.userID != nil else { throw ReadFailure("SIGN_IN_REQUIRED", status: "DENIED") }
  }

  private static func inventoryPage(
    _ page: Int, query: String, context: ReadContext, app: QFAppSession
  ) async throws -> QFContentPage<QFInventoryLot> {
    let result = try await QFContentLoadingContext.$forceRefresh.withValue(true) {
      try await app.inventoryLots(householdID: context.householdID, query: query, page: page)
    }
    try context.check(app)
    guard result.total >= result.items.count, Set(result.items.map(\.id)).count == result.items.count,
          page != 0 || result.total == 0 || !result.items.isEmpty else {
      throw ReadFailure("INCONSISTENT_PAGE")
    }
    return result
  }

  private static func exclusionReasons(_ lot: QFInventoryLot, today: String) -> [String] {
    var reasons: [String] = []
    if lot.status != "ACTIVE" { reasons.append("STATUS_\(lot.status)") }
    if !lot.contentAvailable { reasons.append("CONTENT_UNAVAILABLE") }
    if lot.currentQuantity.range(of: "^(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
       let quantity = Decimal(string: lot.currentQuantity, locale: Locale(identifier: "en_US_POSIX")), quantity > 0 {
      // Preserve the decimal string and unit; this is only a nonpositive-quantity check.
    } else { reasons.append("NO_POSITIVE_QUANTITY") }
    if let expiry = lot.expiresOn {
      if !validDate(expiry) { reasons.append("INVALID_EXPIRY_DATE") }
      else if expiry < today { reasons.append("EXPIRED") }
    }
    return reasons
  }

  private static func sameHousehold(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case let (left?, right?): return UUID(uuidString: left) != nil && UUID(uuidString: left) == UUID(uuidString: right)
    default: return false
    }
  }

  private static func dateFormatter(timeZone: String = "UTC") -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: timeZone)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    return formatter
  }

  private static func validDate(_ value: String) -> Bool {
    guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return false }
    let formatter = dateFormatter()
    guard let date = formatter.date(from: value) else { return false }
    return formatter.string(from: date) == value
  }

  private static func sourceURL(_ value: String?) -> String? {
    guard let value, value.utf8.count <= 2_048, let url = URLComponents(string: value),
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
          url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
    return value
  }

  private static func source(id: String, title: String, url: String? = nil, revision: String? = nil) -> QFAgentSource {
    QFAgentSource(id: id, title: title, url: url, revision: revision)
  }

  private static func json(_ value: Any?) -> Any { value ?? NSNull() }

  private static func base(_ context: ReadContext, fields: [String: Any]) -> [String: Any] {
    fields.merging(["readOnly": true, "contentTrust": "UNTRUSTED_CONTENT", "language": context.language]) { _, trusted in trusted }
  }

  private static func byteCount(_ payload: [String: Any]) throws -> Int {
    try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]).count
  }

  private static func result(
    _ call: QFAgentToolCall, context: ReadContext, app: QFAppSession, status: String = "SUCCEEDED",
    payload: [String: Any], sources: [QFAgentSource]
  ) throws -> QFAgentToolResult {
    try context.check(app)
    let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
    guard bytes.count <= evidenceLimit else { throw ReadFailure("EVIDENCE_LIMIT_EXCEEDED") }
    return QFAgentToolResult(name: call.name, status: status,
      evidence: String(decoding: bytes, as: UTF8.self), sources: sources, action: nil)
  }
}
