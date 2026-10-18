#!/usr/bin/env python3
"""Foundation-only behavior checks of immediate, question-specific understanding."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = root / 'QiafanYoupu/Features/Assistant/QFAssistantQuestionAnalysis.swift'
with tempfile.TemporaryDirectory(prefix='chat-understanding-', dir=root / '.build') as directory:
    tmp = Path(directory)
    check = tmp / 'Check.swift'
    check.write_text(r'''import Foundation
@MainActor final class QFAppSession {
 func text(_ chinese: String, _ english: String) -> String { chinese }
 func format(_ chinese: String, _ english: String, _ arguments: CVarArg...) -> String {
  String(format: chinese, arguments: arguments)
 }
}
@main enum Check {
 @MainActor static func main() {
  let app = QFAppSession()
  func rows(_ question: String, image: Bool = false) -> [String] {
   QFAssistantQuestionAnalysis.summary(text: question, hasImage: image, app: app)
  }
  func kinds(_ question: String) -> String { rows(question).first { $0.hasPrefix("需要处理：") } ?? "" }
  var checks = 0
  let compound = "明晚给两人做白菜炒肉，花生过敏，不吃香菜，20分钟内完成；先查冰箱库存，再安排晚餐计划，按3步列出。"
  let detail = rows(compound).joined(separator: "\n")
  for requirement in ["菜谱与烹饪", "食材与库存", "饮食计划", "两人", "明晚", "花生过敏", "不吃香菜", "20分钟", "按3步"] {
   precondition(detail.contains(requirement), "Immediate understanding lost explicit requirement: \(requirement)"); checks += 1
  }
  let constraintRows = rows(compound).filter { $0.hasPrefix("你已说明：") }
  precondition(constraintRows.count == 1, "Constraints need a separate, inspectable row"); checks += 1
  let quoted = constraintRows[0].components(separatedBy: "“").dropFirst().compactMap { $0.components(separatedBy: "”").first }
  precondition(!quoted.isEmpty && quoted.count <= 6); checks += 1
  for value in quoted { precondition(compound.contains(value), "Invented constraint: \(value)"); checks += 1 }
  let cookingOnly = rows("白菜炒肉怎么做？列出食材和每一个步骤。").joined(separator: "\n")
  precondition(cookingOnly.contains("菜谱与烹饪")); checks += 1
  precondition(!kinds("白菜炒肉怎么做？列出食材和每一个步骤。").contains("食材与库存"), "Ingredients in a recipe do not imply live stock access"); checks += 1
  let stockOnly = kinds("查看食材库存")
  precondition(stockOnly.contains("食材与库存") && !stockOnly.contains("菜谱与烹饪"), "Stock ingredients alone must not invent a cooking request"); checks += 1
  let arithmetic = rows("12乘以7是多少？只回复数字。").joined(separator: "\n")
  precondition(arithmetic.contains("12乘以7是多少？") && arithmetic.contains("只回复数字")); checks += 1
  precondition(!kinds("12乘以7是多少？只回复数字。").contains("食材与库存") && !kinds("12乘以7是多少？只回复数字。").contains("饮食计划")); checks += 1
  let explanation = rows("为什么天空是蓝色的？").joined(separator: "\n")
  precondition(explanation.contains("为什么天空是蓝色的？") && explanation != arithmetic); checks += 1
  let noConditions = rows("你好").joined(separator: "\n")
  precondition(!noConditions.contains("你已说明：") && !noConditions.contains("两人")); checks += 1
  for question in ["我对什么过敏？", "花生过敏吗？", "Am I allergic to peanuts?"] {
   precondition(!rows(question).contains(where: { $0.hasPrefix("你已说明：") }), "An allergy question is not a stated allergy: \(question)"); checks += 1
  }
  let image = rows("这张图里是什么？", image: true).joined(separator: "\n")
  precondition(image.contains("这张图里是什么？") && !image.contains("识别到鸡肉")); checks += 1
  let languages = [
   "查冰箱库存、推荐菜谱并安排计划", "查冰箱庫存、推薦菜譜並安排計劃",
   "Check inventory, find a recipe and make a meal plan",
   "在庫を確認してレシピと献立を考えて", "재고를 확인하고 레시피와 식단 계획을 정리해",
   "Проверь запасы, найди рецепт и составь план питания",
   "Revisa el inventario, busca una receta y crea un plan de comidas",
   "Vérifie l’inventaire, trouve une recette et prépare un menu",
   "Prüfe den Vorrat, finde ein Rezept und erstelle einen Essensplan",
   "Verifique o estoque, encontre uma receita e faça um plano alimentar"
  ]
  for question in languages {
   let result = kinds(question)
   precondition(result.contains("菜谱与烹饪") && result.contains("食材与库存") && result.contains("饮食计划"), question)
   checks += 1
  }
  let mealSuggestions = [
   "请给两人安排20分钟的晚餐，花生过敏。", "請給兩人安排20分鐘的晚餐，花生過敏。",
   "Suggest a 20-minute dinner for two people. Allergic to peanuts.",
   "2人分の夕食を20分で用意する案を提案して。ピーナッツアレルギー。",
   "두 사람을 위한 20분 저녁 식사를 추천해 줘. 땅콩 알레르기가 있어.",
   "Предложи ужин для двоих за 20 минут. Аллергия на арахис.",
   "Recomienda una cena para dos en 20 minutos. Alergia al cacahuete.",
   "Propose un dîner pour deux en 20 minutes. Allergie aux arachides.",
   "Empfiehl ein Abendessen für zwei in 20 Minuten. Erdnussallergie.",
   "Sugira um jantar para duas pessoas em 20 minutos. Alergia a amendoim."
  ]
  for question in mealSuggestions {
   let result = rows(question).joined(separator: "\n")
   precondition(kinds(question).contains("饮食计划"), "Meal suggestions must be understood as meal planning: \(question)")
   precondition(!kinds(question).contains("食材与库存") && !result.contains("已读取") && !result.contains("已保存"), "A meal suggestion does not grant live-read or write authority")
   checks += 2
  }
  for question in ["帮我安排明天出行", "解释为什么不吃晚餐", "Arrange travel for two people tomorrow.", "Explain why I skip dinner."] {
   precondition(!kinds(question).contains("饮食计划"), "A scheduling verb or meal word alone is insufficient: \(question)"); checks += 1
  }
  let tooMany = "明天晚餐，两人份，30分钟，不吃香菜，花生过敏，不放辣椒，少油，按步骤列出，2026-10-20，做菜计划"
  let limited = rows(tooMany).first { $0.hasPrefix("你已说明：") } ?? ""
  precondition(limited.components(separatedBy: "“").count - 1 <= 6); checks += 1
  for question in ["明晚帮我推荐菜谱", "2 people, 20 minutes, no peanuts, recipe for dinner", "12乘以7是多少？只回复数字。"] {
   let visible = rows(question).joined(separator: "\n")
   precondition(!visible.contains("已读取") && !visible.contains("已经联网") && !visible.contains("已保存") && !visible.contains("模型内部")); checks += 1
   precondition(rows(question).allSatisfy { $0.hasPrefix("本轮问题：") || $0.hasPrefix("需要处理：") || $0.hasPrefix("你已说明：") }, "Show only this question, identified requests and literal conditions; no generic workflow or boundary text"); checks += 1
  }
  print("PASS \(checks) immediate question understanding checks")
 }
}''')
    binary = tmp / 'check'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(tmp / 'modules'),
                    str(source), str(check), '-o', str(binary)], check=True, timeout=45)
    subprocess.run([str(binary)], check=True, timeout=10)
