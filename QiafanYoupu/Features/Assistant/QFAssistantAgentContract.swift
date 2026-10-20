import Foundation

struct QFAgentSource: Codable, Equatable, Sendable {
  let id: String
  let title: String
  let url: String?
  let revision: String?
}

struct QFAgentAction: Codable, Equatable, Sendable {
  let type: String
  let recipeID: String?
  let date: String?
  var meal: String? = nil
  var proposalID: String? = nil
}

/// Recognizes an explicit week-planning request, never an instruction obtained
/// from a retrieved page. The server remains authoritative for scope and recipes.
enum QFAssistantWeeklyPlanIntent {
  struct ChatRequestPolicy {
    let generationMode: String
    let allowCloud: Bool
  }
  static func chatRequestPolicy(cloud: Bool, networkEnabled: Bool) -> ChatRequestPolicy? {
    guard cloud || networkEnabled else { return nil }
    // Chat mode only controls the existing network-consent gate. Weekly meals
    // use the synchronous business planner; ordinary model chat is unchanged.
    return .init(generationMode: "LOCAL_RULES", allowCloud: false)
  }
  static func requiresAppendAndShopping(generationMode: String?, goal: String?) -> Bool {
    generationMode == "LOCAL_RULES" || ["BALANCED", "BALANCED_FAT_LOSS"].contains(goal ?? "")
  }
  static func matches(_ text: String) -> Bool {
    let value = text.lowercased()
    let week = "一[个個]?星期|一[个個]?周|一週|一周|7[天日]|七[天日]|下[周週]|next week|(?:next|coming) (?:7|seven) days|week(?:ly)?"
    let food = "饮食|飲食|食[谱譜]|餐|减肥|減肥|减脂|減脂|meal|diet|menu|献立|식단|питани|menú|repas|speise|refei"
    let request = "制定|安排|规划|規劃|帮我|幫我|生成|做[一份个個]|create|make|plan|prepare|build|安排|作って|계획|состав|prépare|erstelle|planeje"
    let refusal = "(?:不要|不需要|别|別).{0,6}(?:制定|安排|规划|規劃|生成|帮|幫)|取消|停止|已经|已經|查[看询詢]|是否|有没有|有沒有|don't (?:create|make|plan)|do not (?:create|make|plan)|cancel|stop|already|show my"
    return [week, food, request].allSatisfy { value.range(of: $0, options: .regularExpression) != nil }
      && value.range(of: refusal, options: .regularExpression) == nil
  }

  static func startDate(for text: String, now: Date = Date(), calendar: Calendar = .current) -> String {
    let start = calendar.startOfDay(for: now)
    let offset: Int
    if text.range(of: "从今天|從今天|starting today|from today", options: [.regularExpression, .caseInsensitive]) != nil { offset = 0 }
    else if text.range(of: "下[周週]|next week", options: [.regularExpression, .caseInsensitive]) != nil {
      offset = (9 - calendar.component(.weekday, from: start)) % 7 == 0 ? 7 : (9 - calendar.component(.weekday, from: start)) % 7
    } else { offset = 1 }
    let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
    let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
}

struct QFAgentToolCall: Codable, Equatable, Sendable {
  let name: String
  let arguments: [String: String]
}

struct QFAgentToolResult: Sendable {
  let name: String
  let status: String
  let evidence: String
  let sources: [QFAgentSource]
  let action: QFAgentAction?
}

struct QFAgentScope: Codable, Equatable, Sendable {
  let account: String
  let household: String?
  let language: String
  var cacheKey: String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(self).base64EncodedString()) ?? "invalid"
  }
}

struct QFAgentKnowledgeLookup: Decodable {
  struct Item: Decodable {
    let id: String; let title: String; let text: String; let url: String?; let revision: String?
    let contentTrust: String; let instructionAuthority: Bool
  }
  let status: String; let language: String; let webAttempted: Bool; let items: [Item]
  func validatedSources(language expected: String) throws -> [QFAgentSource] {
    guard language == expected, items.count <= 3,
      ["LOCAL_HIT", "WEB_HIT", "NO_MATCH", "WEB_DISABLED", "WEB_NOT_CONFIGURED", "WEB_TIMEOUT", "WEB_UNAVAILABLE", "BUSY"].contains(status),
      ["LOCAL_HIT", "WEB_HIT"].contains(status) || items.isEmpty else { throw QFAgentPlan.Invalid.schema }
    return try items.map { item in
      guard !item.instructionAuthority, !item.title.isEmpty, !item.text.isEmpty,
        item.title.utf8.count <= 1024, item.text.utf8.count <= 4000 else { throw QFAgentPlan.Invalid.schema }
      if status == "WEB_HIT" {
        guard webAttempted, item.contentTrust == "UNTRUSTED_WEB_SNIPPET",
          item.id.range(of: "^web:[a-f0-9]{64}$", options: .regularExpression) != nil,
          let raw = item.url, let url = URL(string: raw), url.scheme == "https", url.host != nil,
          url.user == nil, url.password == nil else { throw QFAgentPlan.Invalid.schema }
      } else {
        guard status == "LOCAL_HIT", item.contentTrust == "PROJECT_REVIEWED_SUMMARY",
          item.id.range(of: "^knowledge:[a-z0-9][a-z0-9-]{0,79}$", options: .regularExpression) != nil,
          item.revision?.isEmpty == false else { throw QFAgentPlan.Invalid.schema }
      }
      return .init(id: item.id, title: item.title, url: item.url, revision: item.revision)
    }
  }
}

enum QFAgentText {
  static func limit(_ text: String, utf8 bytes: Int) -> String {
    var result = "", count = 0
    for character in text {
      let value = String(character), size = value.utf8.count
      if count + size > bytes { break }
      result += value; count += size
    }
    return result
  }
}

struct QFAgentPlan {
  enum Invalid: Error { case schema, arguments }
  let calls: [QFAgentToolCall]
  static func isGreetingOnly(_ text: String) -> Bool {
    let key = String(text.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars.filter {
      !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
    })
    return ["你好", "您好", "嗨", "哈喽", "哈囉", "你好呀", "hello", "hi", "hey", "goodmorning", "こんにちは", "おはよう", "こんばんは", "안녕하세요", "안녕", "привет", "здравствуйте", "hola", "bonjour", "salut", "hallo", "gutentag", "oi", "olá", "👋"].contains(key)
  }

  /// A planning hint only. Tool validation and network/account gates still apply.
  /// Ordinary chat and matched knowledge do not pay a native JSON-planning pass.
  static func mayNeedBusinessTools(_ text: String) -> Bool {
    if mayNeedRecipeLookup(text) { return true }
    let patterns = [
      "(打开|打開|开启|開啟).{0,12}(计划|計畫|库存|庫存|模型|记忆|記憶)",
      "\\b(open|show|ouvrir|öffne|abrir|открой)\\b.{0,24}\\b(plans?|inventory|stock|model|memory|programmes?|vorrat|inventario|estoque)\\b"
    ]
    return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
  }
  static func mayNeedRecipeLookup(_ text: String) -> Bool {
    let patterns = [
      "菜谱|菜譜|食谱|食譜|推荐.{0,16}(菜|晚餐|午餐|早餐)|推薦.{0,16}(菜|晚餐)|(今晚|今天|明天).{0,8}吃什么",
      "(?:炒|蒸|煮|炖|燉|烤|煎|焖|燜|拌|炸|卤|滷)[\\p{Han}]{0,8}(?:怎[么麼]做|的?做法)|(?:汤|湯|饭|飯|面|麵|饼|餅|粥|蛋糕|沙拉|鸡|雞|鸭|鴨|鱼|魚|肉|蛋|豆腐|土豆|白菜)(?:怎[么麼]做|的做法)",
      "\\b(recipe|recipes|recette|recettes|rezept|rezepte|receta|recetas|receita|receitas|рецепт[а-я]*)\\b",
      "レシピ|献立|レシピ検索|레시피|추천.{0,12}(요리|식사)"
    ]
    return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
  }
  /// Extract only an explicit recipe title, never infer an entity UUID or facts.
  static func explicitRecipeQuery(_ text: String) -> String? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard mayNeedRecipeLookup(text), !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    let patterns = [
      "\\A(?:请问|請問|请教|請教)?\\s*([^，,。？！?!；;：:\n\r]{2,30}?)(?:怎[么麼]做|的做法)[。？！?!]?\\z",
      "\\A(?:recipe for|recette de|rezept für|receta de|receita de)\\s+([^,.!?;；。？！\n\r]{2,40})[.!?。？！]?\\z"
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
        let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
        let range = Range(found.range(at: 1), in: text) else { continue }
      let query = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
      if !query.isEmpty { return query }
    }
    return nil
  }
  /// Complete read commands only; this selector grants no network or account authority.
  static func explicitReadCall(_ text: String, today: String) -> QFAgentToolCall? {
    var question = text.precomposedStringWithCanonicalMapping
      .replacingOccurrences(of: "’", with: "'")
      .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard question.utf8.count <= 300,
      !question.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    // Only terminal sentence punctuation is optional. Never strip a clause or a request prefix.
    while let last = question.last, ".!?。？！".contains(last) { question.removeLast() }
    question = question.trimmingCharacters(in: .whitespaces)
    let phrases: [(today: String, dated: String, inventory: String)] = [
      ("查看今天的用餐计划", "查看{date}的用餐计划", "查看全部库存"),
      ("查看今天的用餐計畫", "查看{date}的用餐計畫", "查看全部庫存"),
      ("show today's meal plan", "show the meal plan for {date}", "show all inventory"),
      ("今日の食事プランを表示", "{date}の食事プランを表示", "すべての在庫を表示"),
      ("오늘 식사 계획 보기", "{date} 식사 계획 보기", "전체 재고 보기"),
      ("покажи план питания на сегодня", "покажи план питания на {date}", "покажи все запасы"),
      ("mostrar el plan de comidas de hoy", "mostrar el plan de comidas para {date}", "mostrar todo el inventario"),
      ("afficher le planning des repas d'aujourd'hui", "afficher le planning des repas du {date}", "afficher tout le stock"),
      ("zeige den speiseplan für heute", "zeige den speiseplan für {date}", "zeige den gesamten vorrat"),
      ("mostrar o plano de refeições de hoje", "mostrar o plano de refeições para {date}", "mostrar todo o estoque")
    ]
    for phrase in phrases {
      if question == phrase.inventory { return .init(name: "inventory.read", arguments: ["query": ""]) }
      if question == phrase.today {
        return validDate(today) ? .init(name: "plan.read", arguments: ["date": today]) : nil
      }
      let parts = phrase.dated.components(separatedBy: "{date}")
      guard question.hasPrefix(parts[0]), question.hasSuffix(parts[1]),
        question.count >= parts[0].count + parts[1].count else { continue }
      let date = String(question.dropFirst(parts[0].count).dropLast(parts[1].count))
      if validDate(date) { return .init(name: "plan.read", arguments: ["date": date]) }
    }
    return nil
  }
  static func externalKnowledgeQuery(_ text: String) -> String? {
    // Strip only a request prefix, never facts in the remaining query. This
    // permits “帮我联网搜索黑洞” while still refusing “帮我搜索我的地址”.
    var query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    query = query.replacingOccurrences(of: #"^(?:(?:请|請)(?:你)?\s*)?(?:帮我|幫我|麻烦你|麻煩你)\s*|^(?:can you|could you|would you|please)\s+"#,
      with: "", options: [.regularExpression, .caseInsensitive])
    query = query.replacingOccurrences(of: #"^(?:请|請)(?:你)?\s*(?=联网|聯網|上网|上網|搜索|搜尋|查一查)"#,
      with: "", options: [.regularExpression, .caseInsensitive])
    let searchPrefix = #"^(?:(?:联网检索|聯網檢索|联网搜索|聯網搜索|上网查|上網查)(?:一下)?|搜索(?:一下)?|搜尋(?:一下)?|查一查|search(?:\s+(?:the web|online))?(?:\s+for)?|look up|(?:ネット|ウェブ)で(?:検索|調べ)|検索|(?:(?:인터넷|웹)(?:에서)?\s*)?검색|(?:найди|найти|поищи)(?:\s+в интернете)?|busca(?:r)?(?:\s+en internet)?|cherche(?:r|z)?(?:\s+sur internet)?|suche(?:n)?(?:\s+im internet)?|pesquis[ae](?:r)?(?:\s+na internet)?)[\s:：，,]*"#
    let explicitSearch = query.range(of: searchPrefix, options: [.regularExpression, .caseInsensitive]) != nil
    if explicitSearch { query = query.replacingOccurrences(of: searchPrefix, with: "", options: [.regularExpression, .caseInsensitive]) }
    guard !query.isEmpty, maySendReferenceQuery(query), !mayNeedBusinessTools(query),
      query.range(of: "我(刚才|剛才|家|的|对|對)|my |our |earlier|previous|@[a-zA-Z0-9]|[0-9]{6,}|https?://|[0-9].*(乘|加|减|除|[+*/×÷=])", options: [.regularExpression, .caseInsensitive]) == nil,
      explicitSearch || query.range(of: "是什么|是什麼|为什么|為什麼|何时|何時|原理|请解释|請解釋|\\b(what|why|when|explain|pourquoi|warum|qué|quién|porque|что|почему)\\b|とは|なぜ|무엇|왜", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
    return query
  }
  /// Conservative lexical screen, not a general PII detector. Never attach
  /// profile, household records or conversation history to a search request.
  static func maySendReferenceQuery(_ text: String) -> Bool {
    guard text.count <= 200, text.utf8.count <= 1200 else { return false }
    let personal = "我|咱|俺|私|わたし|僕|ぼく|うち|저는|제가|내|우리|\\b(i|me|my|mine|we|us|our|ours|je|moi|mon|ma|mes|nous|notre|ich|mich|mir|mein|meine|unser|yo|mi|mis|nuestro|eu|meu|minha|nosso|я|мне|меня|мой|моя|мы|наш)\\b"
    let history = "刚才|剛才|之前|先前|上文|前面|历史|歷史|earlier|previous|before|told you|histoire|précédent|vorhin|zuvor|antes|раньше|ранее|さっき|先ほど|아까|이전"
    let identifiers = "@[a-zA-Z0-9]|[0-9]{6,}|https?://"
    return [personal, history, identifiers].allSatisfy { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) == nil }
  }

  /// Closed business grammar using llama.cpp's official GBNF sampler (MIT).
  /// JSON string escaping follows upstream grammars/json.gbnf at the pinned revision.
  static let grammar = #"""
  root ::= "{" ws "\"calls\"" ws ":" ws "[" ws (call ("," ws call){0,2})? "]" ws "}" ws
  call ::= search | detail | plan | inventory | knowledge | navigate | draft
  search ::= "{" ws "\"name\"" ws ":" ws "\"recipe.search\"" ws "," ws "\"arguments\"" ws ":" ws query "}" ws
  knowledge ::= "{" ws "\"name\"" ws ":" ws "\"knowledge.search\"" ws "," ws "\"arguments\"" ws ":" ws query "}" ws
  query ::= "{" ws "\"query\"" ws ":" ws string "}" ws
  detail ::= "{" ws "\"name\"" ws ":" ws "\"recipe.detail\"" ws "," ws "\"arguments\"" ws ":" ws "{" ws "\"recipe_id\"" ws ":" ws string "}" ws "}" ws
  plan ::= "{" ws "\"name\"" ws ":" ws "\"plan.read\"" ws "," ws "\"arguments\"" ws ":" ws "{" ws "\"date\"" ws ":" ws string "}" ws "}" ws
  inventory ::= "{" ws "\"name\"" ws ":" ws "\"inventory.read\"" ws "," ws "\"arguments\"" ws ":" ws query "}" ws
  navigate ::= "{" ws "\"name\"" ws ":" ws "\"feature.navigate\"" ws "," ws "\"arguments\"" ws ":" ws "{" ws "\"destination\"" ws ":" ws ("\"recipes\"" | "\"plan\"" | "\"inventory\"" | "\"model_settings\"" | "\"memory\"") ws "}" ws "}" ws
  draft ::= "{" ws "\"name\"" ws ":" ws "\"plan.draft\"" ws "," ws "\"arguments\"" ws ":" ws "{" ws "\"date\"" ws ":" ws string "," ws "\"recipe_id\"" ws ":" ws string "," ws "\"meal\"" ws ":" ws ("\"BREAKFAST\"" | "\"LUNCH\"" | "\"DINNER\"") ws "}" ws "}" ws
  string ::= "\"" ([^"\\\x7F\x00-\x1F] | "\\" (["\\bfnrt] | "u" [0-9a-fA-F]{4}))* "\"" ws
  ws ::= [ \t\n\r]{0,4}
  """#

  /// Model text proposes only closed names and strings, never authority or success.
  static func parse(_ text: String) throws -> Self {
    guard text.utf8.count <= 8192, let data = text.data(using: .utf8),
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(root.keys) == ["calls"], let rows = root["calls"] as? [[String: Any]], rows.count <= 3
    else { throw Invalid.schema }
    let calls = try rows.map { row -> QFAgentToolCall in
      guard Set(row.keys) == ["name", "arguments"], let name = row["name"] as? String,
        let arguments = row["arguments"] as? [String: String] else { throw Invalid.schema }
      let keys = Set(arguments.keys)
      switch name {
      case "recipe.search", "knowledge.search":
        guard keys == ["query"], let query = arguments["query"], !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          query.count <= (name == "recipe.search" ? 100 : 200) else { throw Invalid.arguments }
      case "recipe.detail":
        guard keys == ["recipe_id"], UUID(uuidString: arguments["recipe_id"] ?? "") != nil else { throw Invalid.arguments }
      case "plan.read":
        guard keys == ["date"], validDate(arguments["date"] ?? "") else { throw Invalid.arguments }
      case "inventory.read":
        guard keys.isSubset(of: ["query"]), (arguments["query"] ?? "").count <= 100 else { throw Invalid.arguments }
      case "feature.navigate":
        guard keys == ["destination"], ["recipes", "plan", "inventory", "model_settings", "memory"].contains(arguments["destination"] ?? "") else { throw Invalid.arguments }
      case "plan.draft":
        guard keys.isSubset(of: ["date", "recipe_id", "meal"]), validDate(arguments["date"] ?? ""),
          ["BREAKFAST", "LUNCH", "DINNER"].contains(arguments["meal"] ?? ""),
          UUID(uuidString: arguments["recipe_id"] ?? "") != nil else { throw Invalid.arguments }
      default: throw Invalid.arguments
      }
      return .init(name: name, arguments: arguments)
    }
    guard Set(calls.map { $0.name + $0.arguments.sorted { $0.key < $1.key }.description }).count == calls.count else { throw Invalid.arguments }
    return .init(calls: calls)
  }

  static func validDate(_ value: String) -> Bool {
    guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
      value >= "1000-01-01", value <= "9999-12-31" else { return false }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
    guard let date = formatter.date(from: value) else { return false }
    return formatter.string(from: date) == value
  }
}
