#!/usr/bin/env python3
"""Host checks of shipping intent, calendar and persisted action contracts only."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
contract = root / 'QiafanYoupu/Features/Assistant/QFAssistantAgentContract.swift'
harness = r'''
import Foundation
@main enum Check {
 static func main() throws {
  var checks = 0
  func expect(_ v: @autoclosure () -> Bool) { precondition(v()); checks += 1 }
  for text in ["帮我制定未来一个星期的减肥饮食计划", "幫我安排一週飲食", "制定下周三餐食谱", "Create a weekly meal plan", "Plan my meals for the next seven days", "帮我制定一周不吃花生的饮食计划"] {
   expect(QFAssistantWeeklyPlanIntent.matches(text))
  }
  for text in ["你好", "未来一个星期天气如何", "不要帮我制定一周饮食计划", "取消下周饮食计划", "查看下周饮食计划", "已经制定一周饮食计划了吗", "帮我制定明天的食谱"] {
   expect(!QFAssistantWeeklyPlanIntent.matches(text))
  }
  var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
  let now = ISO8601DateFormatter().date(from: "2026-10-20T15:30:00Z")!
  expect(QFAssistantWeeklyPlanIntent.startDate(for: "未来一个星期", now: now, calendar: calendar) == "2026-10-21")
  expect(QFAssistantWeeklyPlanIntent.startDate(for: "下周", now: now, calendar: calendar) == "2026-10-26")
  expect(QFAssistantWeeklyPlanIntent.startDate(for: "从今天", now: now, calendar: calendar) == "2026-10-20")
  let monday = ISO8601DateFormatter().date(from: "2026-10-26T02:30:00Z")!
  expect(QFAssistantWeeklyPlanIntent.startDate(for: "next week", now: monday, calendar: calendar) == "2026-11-02")
  // Cloud chat is consent to fetch business records, not consent to enqueue a
  // paid weekly-generation job. The verified synchronous planner is shared.
  for (cloud, network, permitted) in [(false, false, false), (false, true, true),
                                    (true, false, true), (true, true, true)] {
   let policy = QFAssistantWeeklyPlanIntent.chatRequestPolicy(cloud: cloud, networkEnabled: network)
   expect((policy != nil) == permitted)
   if let policy {
    expect(policy.generationMode == "LOCAL_RULES")
    expect(policy.allowCloud == false)
   }
  }
  let old = try JSONDecoder().decode(QFAgentAction.self, from: Data(#"{"type":"NAVIGATE_PLAN","recipeID":null,"date":null}"#.utf8))
  expect(old.proposalID == nil)
  expect(QFAssistantWeeklyPlanIntent.requiresAppendAndShopping(generationMode: "CLOUD", goal: "BALANCED"))
  expect(QFAssistantWeeklyPlanIntent.requiresAppendAndShopping(generationMode: "CLOUD", goal: "BALANCED_FAT_LOSS"))
  expect(QFAssistantWeeklyPlanIntent.requiresAppendAndShopping(generationMode: "LOCAL_RULES", goal: nil))
  expect(!QFAssistantWeeklyPlanIntent.requiresAppendAndShopping(generationMode: "CLOUD", goal: nil))
  var action = QFAgentAction(type: "WEEKLY_PLAN_PROPOSAL", recipeID: nil, date: "2026-10-21")
  action.proposalID = "00000000-0000-4000-8000-000000000001"
  expect(try JSONDecoder().decode(QFAgentAction.self, from: JSONEncoder().encode(action)) == action)
  print("PASS \(checks) weekly intent/date/persisted action checks")
 }
}
'''.replace('expect(try JSONDecoder().decode(QFAgentAction.self, from: JSONEncoder().encode(action)) == action)',
            'let restored = try JSONDecoder().decode(QFAgentAction.self, from: JSONEncoder().encode(action)); expect(restored == action)')
with tempfile.TemporaryDirectory(prefix='weekly-plan-', dir=root / '.build') as folder:
    folder = Path(folder)
    check = folder / 'Check.swift'; check.write_text(harness)
    binary = folder / 'check'
    subprocess.run(['xcrun', 'swiftc', '-j1', '-parse-as-library', str(contract), str(check), '-o', str(binary)], check=True, timeout=45)
    subprocess.run([str(binary)], check=True, timeout=10)
