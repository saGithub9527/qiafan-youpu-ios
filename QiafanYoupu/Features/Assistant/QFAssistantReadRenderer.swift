import Foundation

/// Business facts are rendered from actual tool records. A model cannot mint a write receipt.
@MainActor
enum QFAssistantReadRenderer {
  enum Failure: Error { case invalidResult }
  static func render(_ results: [QFAgentToolResult], app: QFAppSession) throws -> String {
    var sections: [String] = []
    for result in results where result.name != "knowledge.search" {
      guard result.status == "SUCCEEDED", let data = result.evidence.data(using: .utf8),
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidResult }
      var lines: [String] = []
      switch result.name {
      case "recipe.search":
        guard let items = root["items"] as? [[String: Any]] else { throw Failure.invalidResult }
        lines.append(app.text("菜谱", "Recipes"))
        lines += items.enumerated().map { "\($0.offset + 1). \($0.element["title"] as? String ?? "")" }
        if items.isEmpty { lines.append(app.text("没有符合条件的结果。", "No matching results.")) }
      case "recipe.detail":
        guard let materials = root["materials"] as? [[String: Any]], let steps = root["steps"] as? [[String: Any]] else { throw Failure.invalidResult }
        lines.append(root["title"] as? String ?? "")
        lines.append(app.text("食材", "Ingredients"))
        lines += materials.map { row in ["name", "amount", "unit"].compactMap { row[$0] as? String }.filter { !$0.isEmpty }.joined(separator: " ") }
        lines.append(app.text("步骤", "Steps"))
        lines += steps.enumerated().map { "\($0.offset + 1). \($0.element["body"] as? String ?? "")" }
      case "plan.read":
        guard let slots = root["slots"] as? [[String: Any]] else { throw Failure.invalidResult }
        lines.append((root["date"] as? String ?? "") + " · " + app.text("计划", "Plan"))
        for slot in slots {
          let meal = slot["meal"] as? String ?? ""
          lines.append(meal == "BREAKFAST" ? app.text("早餐", "Breakfast") : (meal == "LUNCH" ? app.text("午餐", "Lunch") : app.text("晚餐", "Dinner")))
          guard let items = slot["items"] as? [[String: Any]] else { throw Failure.invalidResult }
          if items.isEmpty { lines.append(app.text("没有符合条件的结果。", "No matching results.")) }
          for item in items {
            guard let title = item["title"] as? String, let servings = item["servings"] as? Int, servings > 0 else { throw Failure.invalidResult }
            let state = item["skipped"] as? Bool == true ? app.text("已跳过", "Skipped") : (item["completed"] as? Bool == true ? app.text("已完成", "Completed") : "")
            lines.append([app.format("%@ · %d份", "%@ · %d servings", title, servings), state].filter { !$0.isEmpty }.joined(separator: " · "))
          }
        }
      case "inventory.read":
        guard let items = root["items"] as? [[String: Any]] else { throw Failure.invalidResult }
        lines.append(app.text("库存", "Inventory"))
        if items.isEmpty { lines.append(app.text("没有符合条件的结果。", "No matching results.")) }
        for item in items {
          guard let name = item["ingredientName"] as? String, let quantity = item["quantity"] as? String,
            let unit = item["unitCode"] as? String else { throw Failure.invalidResult }
          var line = "\(name): \(quantity) \(unit)"
          if let expiry = item["expiresOn"] as? String { line += " · " + app.text("到期日", "Expiry date") + ": " + expiry }
          if let reasons = item["excludedFromPlanningReasons"] as? [String], !reasons.isEmpty { line += " · " + app.text("需核对", "Needs review") }
          lines.append(line)
        }
      default: throw Failure.invalidResult
      }
      if root["truncated"] as? Bool == true || root["hasMore"] as? Bool == true {
        lines.append(app.text("仅显示部分记录，请打开来源查看完整内容。", "Only part of the records is shown. Open the source for the full content."))
      }
      sections.append(lines.joined(separator: "\n"))
    }
    return sections.joined(separator: "\n\n")
  }
}
