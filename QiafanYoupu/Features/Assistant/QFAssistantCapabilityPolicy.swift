import Foundation

/// Product refusal/navigation hints, never a grant of authority or a general intent classifier.
/// An empty set does NOT permit writes. Actual tools must remain read-only/validated independently.
enum QFAssistantCapabilityPolicy {
  enum MutationTarget: String, Hashable { case plan, inventory, memory }

  /// A request to inspect real personal data, not evidence that a record exists or a grant of access.
  /// Offline callers must report unavailable access, never turn this set into "no records".
  static func liveReadTargets(in text: String, language: String) -> Set<MutationTarget> {
    let text = normalize(text)
    let preferred = language.lowercased().split(separator: "-").first.map(String.init) ?? ""
    let ordered = readProfiles.filter { $0.language == preferred } + readProfiles.filter { $0.language != preferred }
    var targets: Set<MutationTarget> = []
    for sentence in sentences.components(in: text) where !sentence.isEmpty {
      for clause in separators.components(in: sentence) where !clause.isEmpty {
        for profile in ordered {
          guard !profile.method.matches(clause), !profile.general.matches(clause) else { continue }
          let explicitRead = profile.read.matches(clause)
            && (profile.context.matches(clause) || profile.strongRead.matches(clause))
          let personalQuestion = profile.question.matches(clause) && profile.context.matches(clause)
          guard explicitRead || personalQuestion else { continue }
          if !explicitRead, profile.cooking.matches(clause) { continue }
          for (target, object) in profile.objects where object.matches(clause) { targets.insert(target) }
        }
      }
    }
    return targets
  }

  static func mutationTargets(in text: String, language: String) -> Set<MutationTarget> {
    let text = normalize(text)
    let preferred = language.lowercased().split(separator: "-").first.map(String.init) ?? ""
    // Also inspect the other supported lexicons: the keyboard need not match the UI language.
    let ordered = profiles.filter { $0.language == preferred } + profiles.filter { $0.language != preferred }
    var targets: Set<MutationTarget> = []
    for sentence in sentences.components(in: text) where !sentence.isEmpty {
      if ordered.contains(where: { $0.help.matches(sentence) }), !directRequest.matches(sentence) { continue }
      if startsNegatedRequest.matches(sentence), !contrast.matches(sentence) { continue }
      for clause in separators.components(in: sentence) where !clause.isEmpty {
      for profile in ordered {
        var verbs = profile.verbs.ranges(in: clause)
        if profile.language == "zh" {
          // Negate the operation, not an ingredient restriction elsewhere in the sentence.
          let negated = chineseNegatedVerb.ranges(in: clause, group: 1)
          verbs.removeAll { verb in negated.contains { NSIntersectionRange(verb, $0).length > 0 } }
        } else if profile.negation.matches(clause) { continue }
        guard !verbs.isEmpty else { continue }
        // Clear how/where instructions are help. Mixed explicit commands remain conservatively denied.
        if profile.help.matches(clause), !directRequest.matches(clause) { continue }
        for (target, object) in profile.objects {
          for noun in object.ranges(in: clause) {
            if verbs.contains(where: { verb in
              let gap = max(verb.location, noun.location) - min(NSMaxRange(verb), NSMaxRange(noun))
              return NSIntersectionRange(verb, noun).length == 0 && gap <= 96
            }) { targets.insert(target) }
          }
        }
      }
      }
    }
    return targets
  }

  private struct Pattern {
    let regex: NSRegularExpression
    init(_ source: String) { regex = try! NSRegularExpression(pattern: source) }
    func ranges(in text: String, group: Int = 0) -> [NSRange] {
      regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { $0.range(at: group) }
    }
    func matches(_ text: String) -> Bool {
      regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    func components(in text: String) -> [String] {
      var previous = text.startIndex
      var parts: [String] = []
      for range in ranges(in: text) {
        guard let range = Range(range, in: text) else { continue }
        parts.append(String(text[previous..<range.lowerBound])); previous = range.upperBound
      }
      parts.append(String(text[previous...])); return parts
    }
  }
  private struct Profile {
    let language: String
    let verbs: Pattern
    let objects: [MutationTarget: Pattern]
    let help: Pattern
    let negation: Pattern
    init(_ language: String, words: Bool, verbs: String, plan: String, inventory: String,
         memory: String, help: String, negation: String) {
      self.language = language
      func pattern(_ text: String) -> Pattern { Pattern(words ? word(text) : "(?:" + text + ")") }
      self.verbs = pattern(verbs)
      objects = [.plan: pattern(plan), .inventory: pattern(inventory), .memory: pattern(memory)]
      self.help = Pattern(help); self.negation = Pattern(negation)
    }
  }

  private struct ReadProfile {
    let language: String
    let read: Pattern
    let strongRead: Pattern
    let question: Pattern
    let context: Pattern
    let method: Pattern
    let general: Pattern
    let cooking: Pattern
    let objects: [MutationTarget: Pattern]
    init(_ language: String, words: Bool, read: String, question: String, context: String,
         inventory: String, method: String, general: String, cooking: String) {
      self.language = language
      func pattern(_ source: String) -> Pattern { Pattern(words ? word(source) : "(?:" + source + ")") }
      self.read = pattern(read); self.question = pattern(question); self.context = pattern(context)
      strongRead = pattern(strongReadPatterns[language] ?? "(?!)")
      self.method = Pattern(method); self.general = Pattern(general); self.cooking = Pattern(cooking)
      // Reuse the existing plan vocabulary. Memory is intentionally absent from this API.
      let plan = profiles.first { $0.language == language }!.objects[.plan]!
      objects = [.plan: plan, .inventory: pattern(inventory)]
    }
  }

  // Weak "show/list" alone can ask for a new example; existing/personal context must qualify it.
  private static let strongReadPatterns: [String: String] = [
    "zh": "读取|讀取|查询|查詢|查看|核对|核對",
    "en": "read|check|fetch|query|look up",
    "ja": "確認|読み取|調べ", "ko": "확인|조회|읽어",
    "ru": #"прочита[\p{L}]*|провер[\p{L}]*"#,
    "es": "lee|leer|consulta(?:r)?|revisa(?:r)?|verifica",
    "fr": "lis|lire|consulte(?:r)?|verifie(?:r)?",
    "de": "lies|lesen|prufe(?:n)?|kontrolliere",
    "pt": "leia|ler|consulte|consultar|verifique|conferir"
  ]

  private static func word(_ source: String) -> String {
    #"(?<![\p{L}\p{M}\p{N}_])(?:"# + source + #")(?![\p{L}\p{M}\p{N}_])"#
  }
  private static let sentences = Pattern(#"[.!?;\n。！？；]"#)
  private static let contrast = Pattern(word("but|however|pero|mais|aber|но|mas") + "|但|不过|不過")
  private static let startsNegatedRequest = Pattern(
    #"^\s*(?:please\s+)?(?:do not|don't|dont|never)\s+(?:save|create|add|update|delete|remove|deduct|subtract|remember|forget)\b"#)
  private static let separators = Pattern(
    #"，|(?<![\p{L}\p{M}])(?:but|however|pero|mais|aber|но|mas)(?![\p{L}\p{M}])|\b(?:and|or)\s+(?=(?:do not|don't|please|save|create|add|update|delete|remove|deduct|subtract|remember|forget)\b)|但是|但|不过|不過|(?<!一)并|(?<!一)並|然后|然後"#)
  private static let directRequest = Pattern(
    #"(?:帮我|幫我|替我|请(?:你|直接)?|請(?:你|直接)?)(?:把.{0,20})?(?:保存|储存|儲存|创建|創建|添加|新增|修改|删除|刪除|扣减|扣減|记住|記住)|\b(?:please|could you|can you|would you)\s+(?:save|create|add|update|delete|remove|deduct|remember|forget)\b"#)
  private static let chineseVerbs = "保存|储存|儲存|存储|存儲|创建|創建|建立|新增|添加|加入|加到|修改|更改|更新|调整|調整|删除|刪除|移除|清空|扣减|扣減|扣除|减少|減少|记住|記住|记下|記下|忘记|忘記"
  private static let chineseNegation = "不要|不用|不必|无需|無需|别|別|禁止|不想|不愿|不願|不打算|不希望|不需要"
  private static let chineseNegatedVerb = Pattern(
    "(?:" + chineseNegation + ")" +
    #"(?:[ \t]*(?:再|还|還|也|请|請|你|您|去|来|來|进行|進行|执行|執行|给我|給我|帮我|幫我|替我|为我|為我|自动|自動|直接|现在|現在|马上|馬上)){0,6}[ \t]*"# +
    #"(?:(?:把|将|將)[^，,。；;！？!?\n]{0,40}?)?("# + chineseVerbs + ")")

  /// Fold Latin accents for the Latin lexicons without stripping Japanese dakuten or Cyrillic marks.
  private static func normalize(_ text: String) -> String {
    text.replacingOccurrences(of: "，", with: ";")
      .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .map { character -> String in
        let scalar = character.unicodeScalars.first?.value ?? 0
        if (0x0041...0x007A).contains(scalar) || (0x00C0...0x024F).contains(scalar) {
          return String(character).folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }
        return String(character)
      }.joined().precomposedStringWithCanonicalMapping
  }

  private static let profiles: [Profile] = [
    .init("zh", words: false,
      verbs: chineseVerbs,
      plan: "计划|計劃|計畫|餐单|餐單",
      inventory: "库存|庫存|食材库|食材庫|存货|存貨",
      memory: "记忆|記憶|偏好|过敏|過敏",
      help: "如何|怎么|怎麼|怎样|怎樣|哪里|哪裡|何处|何處|在哪",
      negation: chineseNegation),
    .init("en", words: true,
      verbs: "save|saving|create|creating|add|adding|update|updating|modify|modifying|change|changing|delete|deleting|remove|removing|deduct|deducting|subtract|subtracting|reduce|clear|remember|forget|store",
      plan: "(?:meal|dinner|lunch|breakfast|diet)[ -]+plans?|plans?",
      inventory: "inventory|pantry|(?:my|our|food|ingredient)[ -]+stocks?",
      memory: "(?:saved[ -]+)?memor(?:y|ies)|(?:my|our)[ -]+(?:[a-z]+[ -]+)?(?:allerg(?:y|ies)|preferences?)",
      help: word("how|where"),
      negation: word("do not|don't|dont|never|no need to|cannot|can't")),
    .init("ja", words: false,
      verbs: "保存|作成|追加|変更|更新|削除|消去|減ら|減算|差し引|記憶|覚え|忘れ",
      plan: "食事プラン|食事計画|献立|食事予定",
      inventory: "在庫|食材リスト|備蓄",
      memory: "メモリ|記憶|好み|アレルギー",
      help: "どうやって|どのように|どこで|方法|やり方",
      negation: "しない|しなく|さないで|しないで|不要"),
    .init("ko", words: false,
      verbs: "저장|생성|추가|수정|변경|삭제|제거|차감|줄여|줄이|기억|잊어",
      plan: "식단|식사 계획|식사계획",
      inventory: "재고|식재료 목록|식재료목록",
      memory: "메모리|기억|선호|알레르기",
      help: "어떻게|어디서|어디에서|방법",
      negation: "하지[ ]*(?:마|말)|안[ ]*(?:저장|추가|수정|삭제)|않"),
    .init("ru", words: true,
      verbs: #"сохран[\p{L}]*|созда[\p{L}]*|добав[\p{L}]*|измени[\p{L}]*|обнов[\p{L}]*|удал[\p{L}]*|спиш[\p{L}]*|выч[\p{L}]*|уменьш[\p{L}]*|запомн[\p{L}]*|заб[\p{L}]*"#,
      plan: #"план[\p{L}]*[ ]+(?:питания|приемов пищи)|меню"#,
      inventory: #"запас[\p{L}]*|инвентар[\p{L}]*|склад[\p{L}]*"#,
      memory: #"памят[\p{L}]*|воспоминан[\p{L}]*|предпочтен[\p{L}]*|аллерги[\p{L}]*"#,
      help: word("как|где"), negation: word("не|никогда|нельзя")),
    .init("es", words: true,
      verbs: "guarda(?:r|s|do|ndo)?|crea(?:r|s|do|ndo)?|anad(?:e|ir|as|ido)|agrega(?:r|s)?|modifica(?:r|s)?|actualiza(?:r|s)?|elimina(?:r|s)?|borra(?:r|s)?|quita(?:r|s)?|descuenta|resta|recuerda|recordar|olvida(?:r)?",
      plan: "plan(?:es)?(?: de (?:comidas|alimentacion))?|menu",
      inventory: "inventario|existencias|despensa|stock",
      memory: "memoria|recuerdos|preferencias|alergia(?:s)?",
      help: word("como|donde"), negation: word("no|nunca")),
    .init("fr", words: true,
      verbs: "enregistre(?:r|z)?|sauvegarde(?:r|z)?|cree(?:r|z)?|ajoute(?:r|z)?|modifie(?:r|z)?|supprime(?:r|z)?|retire(?:r|z)?|dedui(?:s|re|sez)|memorise(?:r|z)?|retiens|oublie(?:r|z)?",
      plan: "planning(?: des repas)?|plan(?: de repas)?|menu(?:s)?",
      inventory: "inventaire|stock|reserves",
      memory: "memoire|souvenirs|preferences|allergie(?:s)?",
      help: word("comment|ou"), negation: word("ne|pas|jamais") + "|n['’]"),
    .init("de", words: true,
      verbs: "speicher(?:e|n|t)?|erstelle(?:n)?|fuge|hinzufugen|andere|andern|aktualisiere(?:n)?|losche(?:n)?|entferne(?:n)?|ziehe|abziehen|reduziere(?:n)?|merke|merken|vergiss|vergessen",
      plan: "speiseplan(?:e|en)?|essensplan(?:e|en)?|ernahrungsplan(?:e|en)?|mahlzeitenplan(?:e|en)?",
      inventory: "vorrat(?:e|en)?|bestand|bestande|inventar",
      memory: "erinnerung(?:en)?|gedachtnis|vorlieben|(?:erdnuss)?allergie(?:n)?",
      help: word("wie|wo"), negation: word("nicht|niemals|kein|keine")),
    .init("pt", words: true,
      verbs: "salv(?:e|ar|a)|guard(?:e|ar|a)|cri(?:e|ar|a)|adicion(?:e|ar|a)|acrescent(?:e|ar|a)|alter(?:e|ar|a)|atualiz(?:e|ar|a)|exclu(?:a|ir)|remov(?:a|er|e)|deduz(?:a|ir)|descont(?:e|ar|a)|lembr(?:e|ar|a)|memorize|esquec(?:a|er)",
      plan: "plano(?:s)?(?: de refeicoes| alimentar)?|cardapio",
      inventory: "estoque|inventario|despensa",
      memory: "memoria(?:s)?|lembrancas|preferencias|alergia(?:s)?",
      help: word("como|onde"), negation: word("nao|nunca"))
  ]

  private static let readProfiles: [ReadProfile] = [
    .init("zh", words: false,
      read: "读取|讀取|查看|查询|查詢|查一下|显示|顯示|列出|核对|核對",
      question: "多少|几个|幾個|哪些|什么|甚麼|什麼|还剩|還剩|剩余|剩餘",
      context: "我|我们|我們|家里|家裡|家中|我家|账号|帳號|今天|今日|今晚|当前|當前|现在|現在|实际|實際|已有|还剩|還剩|剩余|剩餘",
      inventory: "库存|庫存|食材库|食材庫|冰箱|冷藏室|储物柜|儲物櫃|(?:我家|家里|家裡|家中).{0,24}(?:食材|食物|食品)",
      method: "如何|怎么|怎麼|怎样|怎樣|哪里|哪裡|在哪",
      general: "清洗|清洁|清潔|除霜|消毒|一般|通常|示例|范例|範例",
      cooking: "能做|做什么|做什麼|怎么做|怎麼做|烹饪|烹飪|做法|推荐|推薦"),
    .init("en", words: true,
      read: "read|check|show|fetch|query|list|look up",
      question: "how many|how much|what|which|left|remaining",
      context: "my|our|account|today|tonight|current|currently|actual|existing|left|remaining|at home",
      inventory: "inventory|pantry|fridge|refrigerator|food stock|(?:groceries|ingredients|food).{0,32}(?:at home|in my house)",
      method: #"\b(?:how|where)\s+(?:do|can|to)\b"#,
      general: word("clean|cleaning|wash|defrost|generally|usually|example|sample|fit|hold|should"),
      cooking: word("cook|cooking|recipe|recipes|make|prepare|recommend")),
    .init("ja", words: false,
      read: "確認|見せ|表示|読み取|調べ|一覧",
      question: "いくつ|何個|どれ|何|残って",
      context: "私|うち|自宅|アカウント|今日|今|実際|現在|残って",
      inventory: "在庫|冷蔵庫|食材リスト|備蓄|自宅.{0,20}食材",
      method: "方法|やり方|どうやって|どこで",
      general: "掃除|洗浄|一般|通常|例として|サンプル|入る",
      cooking: "作れる|作れます|料理|レシピ|おすすめ"),
    .init("ko", words: false,
      read: "확인|조회|보여|표시|읽어|목록",
      question: "몇|얼마|무엇|어떤|남아",
      context: "우리|내|계정|집|오늘|현재|지금|실제|남아",
      inventory: "재고|냉장고|식재료 목록|식재료목록|집.{0,20}식재료",
      method: "어떻게|어디서|어디에서|방법",
      general: "청소|세척|일반|보통|예시|샘플",
      cooking: "요리|만들|레시피|추천"),
    .init("ru", words: true,
      read: #"прочита[\p{L}]*|провер[\p{L}]*|покаж[\p{L}]*|отобраз[\p{L}]*|список"#,
      question: #"сколько|како[\p{L}]*|что|остал[\p{L}]*"#,
      context: #"мо[\p{L}]*|наш[\p{L}]*|аккаунт[\p{L}]*|дома|сегодня|сейчас|текущ[\p{L}]*|остал[\p{L}]*"#,
      inventory: #"запас[\p{L}]*|инвентар[\p{L}]*|холодильник[\p{L}]*|кладов[\p{L}]*"#,
      method: word("как|где"),
      general: word(#"чист[\p{L}]*|мыть|обычно|пример|образец|вместит[\p{L}]*"#),
      cooking: word(#"приготов[\p{L}]*|рецепт[\p{L}]*|рекоменд[\p{L}]*"#)),
    .init("es", words: true,
      read: "lee|leer|consulta(?:r)?|revisa(?:r)?|muestra|mostrar|lista|verifica",
      question: "cuantos|cuantas|cuanto|que|cuales|quedan",
      context: "mi|mis|nuestro|nuestra|cuenta|hoy|actual|actualmente|quedan|casa",
      inventory: "inventario|existencias|despensa|nevera|refrigerador|frigorifico",
      method: word("como|donde"), general: word("limpiar|limpieza|generalmente|ejemplo|normalmente|caben|deberia"),
      cooking: word("cocinar|receta|recetas|preparar|recomienda")),
    .init("fr", words: true,
      read: "lis|lire|consulte(?:r)?|verifie(?:r)?|montre(?:r)?|affiche(?:r)?|liste",
      question: "combien|que|quel|quels|quelle|quelles|restent",
      context: "mon|ma|mes|notre|compte|aujourd'hui|actuel|actuellement|restent|maison",
      inventory: "inventaire|stock|reserves|refrigerateur|frigo|garde-manger",
      method: word("comment|ou"), general: word("nettoyer|nettoyage|generalement|exemple|habituellement|devrais"),
      cooking: word("cuisiner|recette|recettes|preparer|recommande")),
    .init("de", words: true,
      read: "lies|lesen|prufe(?:n)?|zeige(?:n)?|anzeigen|kontrolliere|liste",
      question: "wie viele|wie viel|was|welche|ubrig",
      context: "mein(?:e|en|em|er)?|unser(?:e|en|em)?|konto|heute|heutigen|aktuell|jetzt|noch|ubrig|hause",
      inventory: "vorrat(?:e|en)?|bestand|bestande|inventar|kuhlschrank|speisekammer",
      method: #"\b(?:wie|wo)\s+(?:kann|konnte|prufe|zeige|sehe)\b"#,
      general: word("reinigen|reinigung|allgemein|normalerweise|beispiel|sollte|passen"),
      cooking: word("kochen|rezept|rezepte|zubereiten|empfiehl")),
    .init("pt", words: true,
      read: "leia|ler|consulte|consultar|verifique|conferir|mostre|mostrar|liste",
      question: "quantos|quantas|quanto|que|quais|restam",
      context: "meu|minha|meus|minhas|nosso|nossa|conta|hoje|atual|atualmente|restam|casa",
      inventory: "estoque|inventario|despensa|geladeira|frigorifico",
      method: word("como|onde"), general: word("limpar|limpeza|geralmente|exemplo|normalmente|deveria|cabem"),
      cooking: word("cozinhar|receita|receitas|preparar|recomende"))
  ]
}
