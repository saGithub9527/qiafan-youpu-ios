import Foundation

/// Read-only projection of the legacy source chapters. The original published
/// content remains intact. Only explicit source list boundaries become actions;
/// normal structured recipes keep their original count and order.
enum QFRecipeDirections {
  struct Section: Equatable { let title: String; let body: String }
  struct Projection { let actions: [Section]; let ingredients: [Section]; let notes: [Section] }
  private static let methods: Set<String> = ["操作", "操作步骤", "操作方法", "做法", "做法步骤", "制作步骤", "烹饪步骤", "method", "directions", "instructions"]
  private static let materials: Set<String> = ["必备原料和工具", "必备原料", "原料", "材料", "配料", "计算", "用量", "ingredients", "equipment", "quantities"]
  private static let contexts: Set<String> = ["附加内容", "备注", "注意事项", "资料来源", "notes", "tips", "references", "source, attribution and license"]
  private static func title(_ raw: String) -> String {
    var result = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    for prefix in ["来源原文 · ", "来源原文·"] where result.hasPrefix(prefix) { result.removeFirst(prefix.count); break }
    return result
  }
  static func project(_ sections: [Section]) -> Projection {
    let titles = sections.map { title($0.title) }
    // Do not reinterpret an already edited action list or guess unknown sections.
    guard titles.contains(where: methods.contains), titles.contains(where: materials.contains),
      titles.allSatisfy({ methods.contains($0) || materials.contains($0) || contexts.contains($0) }) else {
      return .init(actions: sections, ingredients: [], notes: [])
    }
    var actions: [Section] = [], ingredients: [Section] = [], notes: [Section] = []
    for (index, section) in sections.enumerated() {
      if materials.contains(titles[index]) { ingredients.append(section) }
      else if methods.contains(titles[index]) {
        let extracted = splitActions(section.body)
        actions += extracted.actions; notes += extracted.notes
      } else { notes.append(section) }
    }
    guard !actions.isEmpty else { return .init(actions: sections, ingredients: [], notes: []) }
    return .init(actions: actions, ingredients: ingredients, notes: notes)
  }
  private static func splitActions(_ body: String) -> (actions: [Section], notes: [Section]) {
    // Bind source subheadings to subsequent actions. In particular an optional
    // variation must never silently become an unconditional cooking step.
    guard !body.contains("```") && !body.contains("<table") else { return ([.init(title: "", body: body)], []) }
    let heading = try! NSRegularExpression(pattern: "^\\s*#{1,6}\\s+(.+?)\\s*#*\\s*$")
    var groups: [Section] = [], label = "", lines: [String] = []
    for line in body.components(separatedBy: .newlines) {
      let value = line as NSString
      if let match = heading.firstMatch(in: line, range: NSRange(location: 0, length: value.length)) {
        if !lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { groups.append(.init(title: label, body: lines.joined(separator: "\n"))) }
        label = value.substring(with: match.range(at: 1)); lines = []
      } else { lines.append(line) }
    }
    if !lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { groups.append(.init(title: label, body: lines.joined(separator: "\n"))) }
    var actions: [Section] = [], notes: [Section] = []
    for group in groups {
      if materials.contains(title(group.title)) || contexts.contains(title(group.title)) { notes.append(group); continue }
      actions += listBlocks(group.body).map { .init(title: group.title, body: $0) }
    }
    return (actions, notes)
  }
  private static func listBlocks(_ body: String) -> [String] {
    // Same conservative list boundaries used by recipe_instruction_steps.py.
    // Nested list text stays attached; paragraphs are not split into sentences.
    let marker = try! NSRegularExpression(pattern: "^(\\s*)(?:[-*+]\\s+|[0-9]+[.)、]\\s+)(.*)$")
    let lines = body.components(separatedBy: .newlines)
    let matches = lines.compactMap { line -> (Int, String)? in
      let value = line as NSString
      guard let match = marker.firstMatch(in: line, range: NSRange(location: 0, length: value.length)) else { return nil }
      return (value.substring(with: match.range(at: 1)).replacingOccurrences(of: "\t", with: "    ").count, value.substring(with: match.range(at: 2)))
    }
    guard let depth = matches.map(\.0).min(), matches.filter({ $0.0 == depth }).count > 1 else { return [body] }
    var blocks: [String] = [], current: [String] = []
    for line in lines {
      let value = line as NSString
      if let match = marker.firstMatch(in: line, range: NSRange(location: 0, length: value.length)),
        value.substring(with: match.range(at: 1)).replacingOccurrences(of: "\t", with: "    ").count == depth {
        if !current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(current.joined(separator: "\n")) }
        current = [value.substring(with: match.range(at: 2))]
      } else { current.append(line) }
    }
    if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
    return blocks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }
}
