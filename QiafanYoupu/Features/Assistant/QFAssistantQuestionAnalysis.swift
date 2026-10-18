import Foundation

/// Synchronous understanding of this question, without generic workflow text,
/// claims that checks have run, or a model's private reasoning.
@MainActor
enum QFAssistantQuestionAnalysis {
  static func summary(text: String, hasImage: Bool, app: QFAppSession) -> [String] {
    let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = question.lowercased()
    func mentions(_ words: [String]) -> Bool { words.contains(where: value.contains) }
    let recipe = mentions(["菜谱", "菜譜", "食谱", "食譜", "做菜", "烹饪", "烹飪", "怎么做", "怎麼做", "recipe", "cook", "料理", "レシピ", "레시피", "рецепт", "receta", "recette", "rezept", "receita"])
      || value.range(of: "做.{0,12}(菜|饭|飯|汤|湯|肉|蛋|炒)", options: .regularExpression) != nil
    let inventory = mentions(["库存", "庫存", "冰箱", "家里剩", "家裡剩", "inventory", "stock", "fridge", "冷蔵庫", "在庫", "냉장고", "재고", "холодильник", "запас", "inventario", "inventaire", "réfrigérateur", "kühlschrank", "vorrat", "bestand", "estoque"])
    let meal = mentions(["早餐", "午餐", "晚餐", "早饭", "早飯", "午饭", "午飯", "晚饭", "晚飯", "breakfast", "lunch", "dinner", "supper", "朝食", "昼食", "夕食", "晩ご飯", "아침", "점심", "저녁", "завтрак", "обед", "ужин", "desayuno", "almuerzo", "cena", "petit-déjeuner", "déjeuner", "dîner", "frühstück", "mittagessen", "abendessen", "café da manhã", "almoço", "jantar"])
    let mealRequest = mentions(["安排", "推荐", "推薦", "准备", "準備", "suggest", "recommend", "prepare", "用意", "提案", "おすすめ", "추천", "준비", "предлож", "порекоменду", "приготов", "recomiend", "prepara", "sugier", "propos", "prépar", "recommand", "empfiehl", "bereite", "sugira", "suger"])
    let plan = mentions(["计划", "計劃", "安排晚餐", "饮食安排", "飲食安排", "meal plan", "menu", "献立", "計画", "계획", "식단", "план", "plan de comidas", "essensplan", "speiseplan", "plano alimentar"])
      || (meal && mealRequest)
    var kinds: [String] = []
    if recipe { kinds.append(app.text("菜谱与烹饪", "Recipes and cooking")) }
    if inventory { kinds.append(app.text("食材与库存", "Ingredients and stock")) }
    if plan { kinds.append(app.text("饮食计划", "Meal plans")) }
    if kinds.isEmpty { kinds.append(app.text("日常问答", "Everyday questions")) }
    let excerpt = question.isEmpty && hasImage ? app.text("分析本轮图片", "Analyze this turn's image")
      : String(question.prefix(120)) + (question.count > 120 ? "…" : "")
    var rows = [app.format("本轮问题：%@", "Current question: %@", excerpt),
      app.format("需要处理：%@", "Requests to address: %@", kinds.joined(separator: " · "))]
    let constraints = explicitConstraints(in: question)
    if !constraints.isEmpty {
      rows.append(app.format("你已说明：%@", "You specified: %@", constraints.map { "“\($0)”" }.joined(separator: " · ")))
    }
    return rows
  }

  /// Quote only literal spans from this user message. The cap bounds the panel;
  /// it never changes the full question or constraints passed to the Agent.
  private static func explicitConstraints(in text: String) -> [String] {
    let bounded = String(text.prefix(2000))
    let patterns = [
      #"[0-9一二两兩三四五六七八九十]{1,3}\s*(?:人(?:份|分)?|位|people|persons?|servings?|personas?|personnes?|Personen|pessoas?|명|человек)"#,
      #"[0-9]{1,3}\s*(?:分钟|分鐘|小时|小時|秒钟|秒鐘|minutes?|mins?|hours?|分|時間|분|시간|минут[а-я]*|час[а-я]*|minutos?|horas?|Stunden?|Minuten?)"#,
      #"[0-9]{4}[-/.年][0-9]{1,2}[-/.月][0-9]{1,2}日?"#,
      #"[0-9]{1,2}(?:[:：][0-9]{2}|[点點]半?)"#,
      #"(?:今天|明天|后天|後天|今晚|明晚|早餐|午餐|晚餐|下周[一二三四五六日天]?|下週[一二三四五六日天]?|tonight|tomorrow|today|next week|breakfast|lunch|dinner|今夜|明日|今日|내일|오늘|завтра|сегодня|mañana|demain|heute|morgen|amanhã)"#,
      #"(?:对|對)?[\p{L}]{1,12}(?:过敏|過敏)|(?:allergic to|allergy to)\s+[\p{L} -]{1,24}"#,
      #"(?:不吃|不放|忌口|少油|少盐|少鹽|少糖|低脂|低糖|低盐|低鹽|素食|无糖|無糖)[^，。,.;；\n]{0,10}|(?:no|without|avoid)\s+[\p{L}]+(?:\s+[\p{L}]+){0,2}"#,
      #"只(?:回复|回覆|回答|输出|輸出)[^，。,.;；\n]{1,12}|按[0-9一二三四五六七八九十]{1,2}步(?:列出)?|每一(?:个|個)?步骤|每一(?:个|個)?步驟|(?:only|just)\s+(?:the )?(?:number|answer|name)|(?:step by step|bullet points|JSON|json)"#
    ]
    let source = bounded as NSString
    let whole = NSRange(location: 0, length: source.length)
    var ranges = patterns.flatMap { pattern in
      // One literal example per category avoids spending the entire budget on
      // overlapping dates or meal words while dropping an explicit format.
      (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?.matches(in: bounded, range: whole).prefix(1).map(\.range) ?? []
    }
    ranges.sort { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }
    var selected: [NSRange] = []
    var values: [String] = []
    for range in ranges where !selected.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
      let value = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, !values.contains(value) else { continue }
      if ["过敏", "過敏", "allerg"].contains(where: value.lowercased().contains) {
        let tail = source.substring(from: NSMaxRange(range)).trimmingCharacters(in: .whitespaces)
        let prefix = source.substring(to: range.location).lowercased()
        let uncertain = ["什么", "什麼", "哪些", "是否", "会不会", "會不會", "有没有", "有沒有"].contains(where: value.contains)
          || ["吗", "嗎", "?", "？"].contains(where: tail.hasPrefix)
          || prefix.range(of: #"\b(?:am i|could i be|might i be|do i have)\s*$"#, options: .regularExpression) != nil
        // A question about an allergy is not evidence of a stated allergy.
        // The original question still reaches the Agent without modification.
        if uncertain { continue }
      }
      selected.append(range); values.append(value)
      if values.count == 6 { break }
    }
    return values
  }
}
