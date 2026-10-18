#!/usr/bin/env python3
"""Compile the production Foundation link policy; no App, UI or model is started."""
from pathlib import Path
import json
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[2]
source = root / 'QiafanYoupu/Features/Assistant/QFAssistantChatUI.swift'
contract = root / 'QiafanYoupu/Features/Assistant/QFAssistantAgentContract.swift'
report = root / '.build/assistant-message-links-check.json'
start = time.monotonic()
try:
    content = source.read_text()
    marker = '// MARK: - Foundation-only trusted message links'
    assert marker in content, 'Missing production trusted-message link policy'
    policy = content.split(marker, 1)[1].split('// MARK: - Native message text view', 1)[0]
    with tempfile.TemporaryDirectory(prefix='chat-links-', dir=root / '.build') as tmp:
        tmp = Path(tmp)
        unit = tmp / 'Policy.swift'
        unit.write_text('import Foundation\n' + policy)
        check = tmp / 'Check.swift'
        check.write_text(r'''import Foundation
@main enum Check {
 static func main() {
  var checks = 0
  func expect(_ value: @autoclosure () -> Bool, _ message: String) {
   precondition(value(), message); checks += 1
  }
  let id = "00000000-0000-4000-8000-000000000001"
  func source(_ title: String, id: String = "knowledge:food-safe", url: String? = nil) -> QFAgentSource {
   .init(id: id, title: title, url: url, revision: "test")
  }
  func action(_ type: String, recipe: String? = nil, date: String? = nil, meal: String? = nil) -> QFAgentAction {
   .init(type: type, recipeID: recipe, date: date, meal: meal)
  }
  func candidates(_ sources: [QFAgentSource], _ actions: [QFAgentAction] = [], titles: [String] = [], binding: String = "test-binding") -> [QFAssistantMessageLinks.Candidate] {
   QFAssistantMessageLinks.candidates(sources: sources, actions: actions, actionTitles: titles, binding: binding)
  }
  let known = candidates([source("番茄炒蛋", id: "recipe:" + id)])
  let rows = QFAssistantMessageLinks.spans(in: "推荐番茄炒蛋。", candidates: known)
  expect(rows.count == 1 && rows.first?.target == .source(0), "Observed recipe title must link")
  expect(rows.first?.range == NSRange(location: 2, length: 4), "Chinese range")
  expect(QFAssistantMessageLinks.spans(in: "推荐番茄炒", candidates: known).isEmpty, "Partial reveal is not a complete title")
  expect(QFAssistantMessageLinks.spans(in: "[点击](https://evil.invalid)", candidates: []).isEmpty, "Model Markdown cannot introduce navigation")
  expect(QFAssistantMessageLinks.spans(in: "https://example.invalid", candidates: []).isEmpty, "No automatic URL detection")
  expect(QFAssistantMessageLinks.spans(in: "番茄炒蛋和番茄炒蛋", candidates: known).count == 2, "Repeated exact titles")
  let overlap = candidates([source("鸡蛋"), source("番茄炒鸡蛋", id: "recipe:" + id)])
  let wide = QFAssistantMessageLinks.spans(in: "番茄炒鸡蛋", candidates: overlap)
  expect(wide.count == 1 && wide.first?.target == .source(1), "Longest non-overlapping entity wins")
  let ambiguous = candidates([source("同名菜谱", id: "recipe:" + id), source("同名菜谱", id: "knowledge:other")])
  expect(ambiguous.isEmpty, "Ambiguous same-name entities retain source buttons only")
  expect(candidates([source("番茄炒蛋", id: "recipe:" + id), source("番茄炒蛋", id: "recipe:" + id)]).count == 1, "Identical repeated sources deduplicate")
  expect(!QFAssistantMessageLinks.spans(in: "champion", candidates: candidates([source("ham")])).contains(where: { _ in true }), "Latin word fragments do not link")
  expect(QFAssistantMessageLinks.spans(in: "Try ham, please.", candidates: candidates([source("ham")])).count == 1, "Latin word boundaries")
  expect(QFAssistantMessageLinks.spans(in: "👩🏽‍🍳番茄炒蛋", candidates: known).first?.range.location == ("👩🏽‍🍳" as NSString).length, "UTF16 grapheme prefix")
  expect(!candidates([source("知识条目")]).isEmpty, "Local reviewed knowledge can open without a URL")
  for bad in ["knowledge:", "knowledge:../private", "knowledge:<script>", "recipe:bad", "inventory-lot:bad", "plan-slot:bad"] {
   expect(candidates([source("恶意条目", id: bad)]).isEmpty, "Reject malformed App source " + bad)
  }
  for badURL in ["http://example.invalid/a", "https://u:p@example.invalid/a", "javascript:alert(1)", "file:///tmp/a"] {
   expect(candidates([source("网站条目", id: "web:test", url: badURL)]).isEmpty, "Reject unsafe source URL")
  }
  expect(candidates([source("网站条目", id: "web:test", url: "https://example.invalid/guide")]).count == 1, "Observed HTTPS source")
  let planSource = "plan-slot:personal:2026-10-16:DINNER"
  expect(candidates([source("晚餐计划", id: planSource)]).count == 1, "Valid plan source")
  expect(candidates([source("库存鸡蛋", id: "inventory-lot:" + id)]).count == 1, "Valid inventory source")
  expect(candidates([], [action("NAVIGATE_RECIPES")], titles: ["打开菜谱"]).count == 1, "Allowed navigation action")
  expect(candidates([], [action("OPEN_RECIPE", recipe: id)], titles: ["查看菜谱"]).count == 1, "Observed valid recipe action")
  expect(candidates([], [action("PLAN_DRAFT", recipe: id, date: "2026-10-16", meal: "DINNER")], titles: ["核对计划草稿"]).count == 1, "Valid draft navigation")
  for bad in [action("recipe.save"), action("DELETE_ACCOUNT"), action("OPEN_RECIPE", recipe: "bad"), action("PLAN_DRAFT", recipe: id, date: "2026-02-30", meal: "DINNER"), action("PLAN_DRAFT", recipe: id, date: "2026-10-16", meal: "MIDNIGHT")] {
   expect(candidates([], [bad], titles: ["打开"]).isEmpty, "No unknown action, invalid ID, date or meal")
  }
  let first = candidates([source("知识条目")], binding: "old-cell")
  let second = candidates([source("知识条目")], binding: "new-cell")
  expect(first.first?.url != second.first?.url, "Reused cells use a fresh local link binding")
  let actionRows = QFAssistantMessageLinks.spans(in: "可打开菜谱。", candidates: candidates([], [action("NAVIGATE_RECIPES")], titles: ["打开菜谱"]))
  expect(actionRows.first?.target == .action(0), "Action link uses existing action callback identity")
  print("PASS \(checks) trusted message link checks")
 }
}''')
        binary = tmp / 'check'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(tmp / 'modules'),
                        str(contract), str(unit), str(check), '-o', str(binary)], check=True, timeout=45)
        result = subprocess.run([str(binary)], check=True, timeout=10, text=True, capture_output=True)
        print(result.stdout, end='')
        report.write_text(json.dumps({'passed': True, 'seconds': round(time.monotonic() - start, 3),
                                      'output': result.stdout.strip(), 'scope': 'Production Foundation policy only; UIKit layout and taps not executed'}, ensure_ascii=False, indent=2) + '\n')
except Exception as error:
    report.parent.mkdir(exist_ok=True)
    report.write_text(json.dumps({'passed': False, 'seconds': round(time.monotonic() - start, 3),
                                  'error': str(error)}, ensure_ascii=False, indent=2) + '\n')
    raise
