import Foundation
import NaturalLanguage
import SQLite3

/// A bounded on-device lexical RAG index. Only versioned project summaries enter it.
actor QFAssistantKnowledge {
  static let shared = QFAssistantKnowledge()
  struct Edition: Decodable {
    let schemaVersion: Int
    let documents: [Document]
  }
  struct Document: Decodable {
    struct Text: Decodable { let title: String; let keywords: String; let body: String }
    let id: String
    let revision: String
    let reviewedAt: String
    let validUntil: String
    let sourceURL: String?
    let license: String
    let destination: String?
    let languages: [String: Text]
    /// Complete reviewed questions only. Topic keywords never authorize a direct answer.
    let directQuestions: [String: [String]]?
  }
  struct Hit: Sendable {
    let title: String
    let body: String
    let source: QFAgentSource
    let destination: String?
  }
  enum Failure: Error { case unavailable }
  private var database: OpaquePointer?
  private var documents: [String: Document] = [:]
  private var indexedLanguage: String?
  private var indexedDay: String?
  private static let directDocumentIDs: Set<String> = [
    "food-separate", "food-leftovers", "food-thawing", "food-thermometer"
  ]
  // Do not cite a cooking document just because a question contains "is" or "です".
  // NLTokenizer provides word boundaries; FTS matches complete normalized words.
  private static let stopWords: Set<String> = Set("""
  可以 什么 怎么 如何 帮我 一下 请问 请教 解释 告诉 回答 是否 为什么
  the can how what please with about is are was were do does did this that these those
  you your me my we our to for of in on at an and or be from as it its if tell explain
  です ます ください について 教え どう なぜ とは それ これ
  알려 주세요 어떻게 무엇 왜 대해 이것
  что как это для или мне мой меня про
  qué que como cómo por para una uno los las del es son me mi el un
  quel quelle comment pourquoi est sont les des une pour sur moi mon la le du de et ce cette au il
  wie was warum ist sind ein eine der die das den dem für von mit mein mir
  qual quais como porque para uma dos das são meu minha
  今天 明天 昨天 today tomorrow yesterday 今日 明日 昨日 오늘 내일 어제
  сегодня завтра вчера hoy mañana ayer demain hier heute morgen gestern hoje amanhã ontem
  """.split(whereSeparator: \.isWhitespace).map(String.init))

  deinit { if let database { sqlite3_close(database) } }

  private func words(_ text: String) -> [String] {
    let text = text.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\u{200B}", with: "")
    let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
    var result: [String] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      let word = String(text[range]).lowercased()
      if word.count >= 2, word.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }),
        !Self.stopWords.contains(word) { result.append(word) }
      return true
    }
    return result
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure.unavailable }
    return statement
  }
  private func bind(_ value: String, to statement: OpaquePointer, index: Int32) {
    _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
  }

  private func index(language: String) throws {
    let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
    guard indexedLanguage != language || indexedDay != today else { return }
    guard let url = Bundle.main.url(forResource: "assistant-knowledge", withExtension: "json") else { throw Failure.unavailable }
    try load(data: Data(contentsOf: url), language: language)
  }

  /// Prepare the existing small index ahead of the first question; no inference or network.
  func prewarm(language: String) throws { try index(language: language) }

  private static func questionKey(_ text: String) -> String {
    let normalized = text.precomposedStringWithCanonicalMapping
      .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    return String(normalized.unicodeScalars.filter {
      !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        && $0.value != 0x200B
    })
  }

  /// A complete curated question can return the reviewed source text directly.
  /// Added clauses, personal constraints and numeric follow-ups cannot match it.
  func directAnswer(for query: String, language: String) throws -> Hit? {
    try index(language: language)
    guard query.utf8.count <= 600, !query.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else { return nil }
    let key = Self.questionKey(query)
    guard !key.isEmpty else { return nil }
    let matching = documents.values.filter { document in
      Self.directDocumentIDs.contains(document.id) && document.sourceURL != nil
        && document.directQuestions?[language]?.contains(where: { Self.questionKey($0) == key }) == true
    }
    // An editorial collision is ambiguous, never permission to choose arbitrarily.
    guard matching.count == 1, let document = matching.first else { return nil }
    return try lookup(sourceID: "knowledge:" + document.id, language: language)
  }

  /// Also used by the small host-side check with the exact bundled JSON.
  func load(data: Data, language: String) throws {
    let edition = try JSONDecoder().decode(Edition.self, from: data)
    guard edition.schemaVersion == 1, edition.documents.count <= 500,
      ["zh-Hans", "zh-Hant", "en", "ja", "ko", "ru", "es", "fr", "de", "pt-BR"].contains(language) else { throw Failure.unavailable }
    if let database { sqlite3_close(database) }; database = nil; indexedLanguage = nil; documents = [:]
    guard sqlite3_open(":memory:", &database) == SQLITE_OK,
      sqlite3_exec(database, "CREATE VIRTUAL TABLE knowledge USING fts5(id UNINDEXED,title,keywords,body)", nil, nil, nil) == SQLITE_OK else { throw Failure.unavailable }
    let insert = try prepare("INSERT INTO knowledge(id,title,keywords,body) VALUES(?,?,?,?)")
    defer { sqlite3_finalize(insert) }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
    let today = formatter.string(from: Date())
    for document in edition.documents {
      guard documents[document.id] == nil, !document.revision.isEmpty, !document.license.isEmpty,
        document.id.range(of: "^[a-z0-9][a-z0-9-]{0,79}$", options: .regularExpression) != nil,
        QFAgentPlan.validDate(document.reviewedAt), QFAgentPlan.validDate(document.validUntil),
        document.reviewedAt <= today, document.validUntil >= today,
        let value = document.languages[language], !value.body.isEmpty,
        [value.title, value.keywords, value.body].allSatisfy({ text in
          text.utf8.count <= 4000 && !text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) && $0 != "\t"
          }) && !text.contains("<|im_start|>") && !text.lowercased().contains("<script")
        }) else { continue }
      if let source = document.sourceURL {
        guard let url = URL(string: source), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { continue }
      }
      if let questions = document.directQuestions {
        guard Self.directDocumentIDs.contains(document.id), document.sourceURL != nil,
          Set(questions.keys).isSubset(of: Set(document.languages.keys)),
          questions.values.allSatisfy({ phrases in
            (1...3).contains(phrases.count) && phrases.allSatisfy { phrase in
              !Self.questionKey(phrase).isEmpty && phrase.utf8.count <= 600
                && !phrase.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                && !phrase.contains("<|im_start|>") && !phrase.lowercased().contains("<script")
            }
          }) else { continue }
      }
      documents[document.id] = document
      for (index, value) in [document.id, words(value.title).joined(separator: " "), words(value.keywords).joined(separator: " "), words(value.body).joined(separator: " ")].enumerated() {
        bind(value, to: insert, index: Int32(index + 1))
      }
      guard sqlite3_step(insert) == SQLITE_DONE else { throw Failure.unavailable }
      sqlite3_reset(insert); sqlite3_clear_bindings(insert)
    }
    indexedLanguage = language
    indexedDay = today
  }

  func search(_ query: String, language: String, limit: Int = 2) throws -> [Hit] {
    try index(language: language)
    if let guide = try capabilityGuide(for: query, language: language) { return [guide] }
    let tokens = Array(Set(words(String(query.prefix(500))))).sorted().prefix(12)
    guard !tokens.isEmpty else { return [] }
    let normalized = query.precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of: "\u{200B}", with: "")
    let queryWords = Set(words(normalized))
    func topicScore(_ value: Document.Text) -> Int {
      let aliases = value.keywords.contains("|") ? value.keywords.split(separator: "|") : value.keywords.split(whereSeparator: \.isWhitespace)
      return aliases.filter { alias in
        let alias = String(alias).lowercased().trimmingCharacters(in: .whitespaces)
        guard alias.count >= 2 else { return false }
        let cjk = alias.unicodeScalars.contains { $0.value >= 0x2E80 }
        if cjk { return normalized.contains(alias) }
        if !alias.contains(" ") { return queryWords.contains(alias) }
        let escaped = NSRegularExpression.escapedPattern(for: alias)
        return normalized.range(of: "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])", options: .regularExpression) != nil
      }.count
    }
    let statement = try prepare("SELECT id FROM knowledge WHERE knowledge MATCH ? ORDER BY bm25(knowledge,0,5,4,1),id LIMIT ?")
    defer { sqlite3_finalize(statement) }
    // Curated topic aliases define relevance. A generic word in a guide body
    // is not evidence that the guide answers the question.
    bind("keywords : (" + tokens.map { "\"\($0)\"" }.joined(separator: " OR ") + ")", to: statement, index: 1)
    // Filter complete editorial aliases before applying the result limit; token fragments are only retrieval candidates.
    sqlite3_bind_int(statement, 2, Int32(documents.count))
    var hits: [Hit] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { throw Failure.unavailable }
      let id = String(cString: raw)
      guard let doc = documents[id], let text = doc.languages[language], topicScore(text) > 0 else { continue }
      hits.append(.init(title: text.title, body: text.body.precomposedStringWithCanonicalMapping,
        source: .init(id: "knowledge:\(id)", title: text.title, url: doc.sourceURL, revision: doc.revision), destination: doc.destination))
      if hits.count >= max(1, min(3, limit)) { break }
    }
    if !hits.isEmpty { return hits }
    // A single bounded, literal-keyword fallback for segmentation misses. No
    // fuzzy expansion, other-language substitution or fabricated evidence.
    return documents.values.compactMap { document -> (Int, Hit)? in
      guard let value = document.languages[language] else { return nil }
      let score = topicScore(value)
      guard score > 0 else { return nil }
      return (score, Hit(title: value.title, body: value.body.precomposedStringWithCanonicalMapping,
        source: .init(id: "knowledge:\(document.id)", title: value.title, url: document.sourceURL, revision: document.revision), destination: document.destination))
    }.sorted { $0.0 == $1.0 ? $0.1.source.id < $1.1.source.id : $0.0 > $1.0 }.prefix(max(1, min(3, limit))).map(\.1)
  }

  /// Exact lookup for a source tap; never reinterpret a title as a query.
  func lookup(sourceID: String, language: String) throws -> Hit? {
    try index(language: language)
    guard sourceID.hasPrefix("knowledge:"), let doc = documents[String(sourceID.dropFirst(10))],
      let value = doc.languages[language] else { return nil }
    return .init(title: value.title, body: value.body,
      source: .init(id: sourceID, title: value.title, url: doc.sourceURL, revision: doc.revision), destination: doc.destination)
  }

  /// Product capabilities are owned by the App, not guessed by either model.
  /// Match a complete editorial question so a compound request is not swallowed.
  func capabilityGuide(for query: String, language: String) throws -> Hit? {
    try index(language: language)
    guard let doc = documents["guide-assistant"], let value = doc.languages[language] else { return nil }
    func key(_ text: String) -> String {
      String(text.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars.filter {
        !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
      })
    }
    let question = key(query)
    guard value.keywords.split(separator: "|").contains(where: { key(String($0)) == question }) else { return nil }
    return try lookup(sourceID: "knowledge:guide-assistant", language: language)
  }
}
