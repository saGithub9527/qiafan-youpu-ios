#!/usr/bin/env python3
"""Actual scoped conversation storage with one disposable UserDefaults suite."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='conversation-store-', dir=root/'.build') as folder:
    folder = Path(folder)
    source = folder/'Check.swift'
    source.write_text(r'''import Foundation
// Only media I/O is replaced; these tests do not create or delete user images.
enum QFLocalMediaStore {
 struct Saved { let id: String }
 static func save(_ data: Data, video: Bool, scope: String) throws -> Saved { fatalError("unexpected media write") }
 static func remove(_ id: String, scope: String) { fatalError("unexpected media delete") }
 static func url(_ id: String, scope: String) throws -> URL { URL(fileURLWithPath:"/not-opened") }
}
@main enum Check {
 static func main() throws {
  let suite = "qf.agent-test." + UUID().uuidString
  let defaults = UserDefaults(suiteName:suite)!
  defer { defaults.removePersistentDomain(forName:suite) }
  let scope = QFAgentScope(account:"isolated-fixture",household:nil,language:"zh-Hans")
  let store = QFAssistantConversationStore(scope:scope,defaults:defaults)
  var visible: [QFAssistantLocalMessage] = [], original: [QFAgentConversationContext.Turn] = []
  var recoveryChecks = 0, recoveryFailures: [String] = []
  func expectRecovery(_ condition: Bool, _ label: String) {
   recoveryChecks += 1
   if !condition { recoveryFailures.append(label); print("FAIL " + label) }
  }
  func storageKey(_ value: QFAgentScope) -> String { "qf.assistant.conversation.v2." + value.cacheKey }
  let oldSource = QFAgentSource(id:"knowledge:ended-topic-fixture",title:"Public ended topic",url:nil,revision:"fixture-1")
  for index in 0..<80 {
   let role = index % 2 == 0 ? "user" : "assistant"
   let text = index == 0 ? "本段对话对花生过敏。"
    : index == 78 ? "Ended context constraint: list names only, without quantities." : "公开合成内容\(index)"
   visible.append(.init(id:UUID(),role:role,text:text,createdAt:Date(),sources:index == 79 ? [oldSource] : nil,state:"complete"))
   original.append(.init(role:role,content:text))
   store.save(visible)
   visible = store.load() // repeatedly recreate the actual forty-row UI window
  }
  let reopened = QFAssistantConversationStore(scope:scope,defaults:defaults)
  precondition(reopened.load().count == 40)
  let restoredHistory = try reopened.history(reopened.load(), imageQuestion:"Image placeholder")
  precondition(restoredHistory == original,
    "reopening must not silently lose early constraints outside the visible forty messages")
  for other in [QFAgentScope(account:"other",household:nil,language:"zh-Hans"),
    QFAgentScope(account:scope.account,household:"other",language:"zh-Hans"),
    QFAgentScope(account:scope.account,household:nil,language:"en")] {
   let isolated = QFAssistantConversationStore(scope:other,defaults:defaults)
   let isolatedHistory = try isolated.history(isolated.load(),imageQuestion:"Image")
   precondition(isolatedHistory.isEmpty)
  }
  reopened.markNativeCapacityReached()
  let blockedNative = QFAssistantConversationStore(scope:scope,defaults:defaults)
  precondition(blockedNative.nativeCapacityReached)
  reopened.beginNewContext(after: visible.last?.id)
  let reset = QFAssistantConversationStore(scope:scope,defaults:defaults)
  let resetHistory = try reset.history(reset.load(),imageQuestion:"Image")
  precondition(resetHistory.isEmpty && reset.load().count == 40 && !reset.nativeCapacityReached)
  let resetBytes = defaults.data(forKey:storageKey(scope) + ".context")!
  let resetSnapshot = try JSONSerialization.jsonObject(with:resetBytes) as? [String:Any]
  expectRecovery((resetSnapshot?["records"] as? [[String:Any]])?.isEmpty == true,
    "reset context must be a single closed snapshot containing its records")
  expectRecovery((resetSnapshot?["boundary"] as? String)?.lowercased() == visible.last!.id.uuidString.lowercased(),
    "the same snapshot must contain the explicit reset boundary")
  expectRecovery(resetSnapshot?["nativeCapacity"] as? Bool == false,
    "the same snapshot must contain the cleared native capacity flag")

  // Simulate only the first old-style reset write surviving: [] is present,
  // while the separately persisted boundary is missing or from an earlier cut.
  // The still-visible chat and its source must not become active context again.
  for staleBoundary in [false, true] {
   let brokenScope = QFAgentScope(account:"interrupted-reset-\(staleBoundary)",household:nil,language:"zh-Hans")
   let base = storageKey(brokenScope)
   try defaults.set(JSONEncoder().encode(visible),forKey:base)
   let emptyLegacy = Data("[]".utf8)
   defaults.set(emptyLegacy,forKey:base + ".context")
   if staleBoundary { defaults.set(visible.first!.id.uuidString,forKey:base + ".contextBoundary") }
   else { defaults.removeObject(forKey:base + ".contextBoundary") }
   let interrupted = QFAssistantConversationStore(scope:brokenScope,defaults:defaults)
   let rows = interrupted.load()
   var refused = false
   do { _ = try interrupted.history(rows,imageQuestion:"Image") }
   catch QFAgentConversationContext.Invalid.schema { refused = true }
   expectRecovery(refused,"interrupted empty legacy reset must fail closed; stale=\(staleBoundary)")
   expectRecovery(interrupted.knownSources(rows).isEmpty,"interrupted reset cannot restore old source; stale=\(staleBoundary)")
   interrupted.save(rows)
   expectRecovery(defaults.data(forKey:base + ".context") == emptyLegacy,
     "ambiguous recovery must not overwrite its evidence; stale=\(staleBoundary)")
  }

  // A valid nonempty old record array remains readable, including constraints
  // older than the forty-row UI. This is migration, not a fresh reset.
  let legacyScope = QFAgentScope(account:"valid-legacy-context",household:nil,language:"zh-Hans")
  let legacyBase = storageKey(legacyScope)
  try defaults.set(JSONEncoder().encode(visible),forKey:legacyBase)
  let legacyRecords: [[String:Any]] = original.enumerated().map { index, turn in
   ["id": index < 40 ? UUID().uuidString : visible[index - 40].id.uuidString,
    "role":turn.role,"text":turn.content,"hasImage":false]
  }
  try defaults.set(JSONSerialization.data(withJSONObject:legacyRecords),forKey:legacyBase + ".context")
  defaults.set(true,forKey:legacyBase + ".nativeCapacity")
  let legacy = QFAssistantConversationStore(scope:legacyScope,defaults:defaults)
  expectRecovery(try legacy.history(legacy.load(),imageQuestion:"Image") == original,
    "valid nonempty legacy records must migrate without losing earlier context")
  expectRecovery(legacy.nativeCapacityReached,"legacy native capacity guard must survive migration")

  // No context key is the established first-upgrade case; the existing visible
  // forty messages must still seed the first context without a silent reset.
  let firstScope = QFAgentScope(account:"first-context-upgrade",household:nil,language:"zh-Hans")
  try defaults.set(JSONEncoder().encode(visible),forKey:storageKey(firstScope))
  let first = QFAssistantConversationStore(scope:firstScope,defaults:defaults)
  expectRecovery(try first.history(first.load(),imageQuestion:"Image") == Array(original.suffix(40)),
    "first upgrade without a context snapshot must retain the visible conversation")
  let newUser = QFAssistantLocalMessage(id:UUID(),role:"user",text:"New synthetic topic",createdAt:Date(),state:"complete")
  visible.append(newUser); reset.save(visible)
  let newSession = QFAssistantConversationStore(scope:scope,defaults:defaults)
  let newHistory = try newSession.history(newSession.load(),imageQuestion:"Image")
  precondition(newHistory == [.init(role:"user",content:newUser.text)])
  precondition(newSession.load().count == 40) // chat retained; only the explicitly reset context changed
  for i in 0..<60 {
   var items = newSession.load()
   items.append(.init(id:UUID(),role:"user",text:"New topic continuation \(i)",createdAt:Date(),state:"complete"))
   newSession.save(items)
  }
  let agedBoundary = QFAssistantConversationStore(scope:scope,defaults:defaults)
  let agedHistory = try agedBoundary.history(agedBoundary.load(),imageQuestion:"Image")
  precondition(agedHistory.count == 61 && agedHistory.first?.content == newUser.text)
  precondition(agedHistory.allSatisfy { !$0.content.contains("花生") })
  // Reopening corrupted context must fail closed, not silently fall back to
  // the visible40. Only an explicit new-context action may discard that context.
  let contextKey = storageKey(scope) + ".context"
  let malformed = Data("not JSON".utf8)
  defaults.set(malformed,forKey:contextKey)
  let invalid = QFAssistantConversationStore(scope:scope,defaults:defaults)
  do { _ = try invalid.history(invalid.load(),imageQuestion:"Image"); fatalError("corrupt context silently dropped") }
  catch QFAgentConversationContext.Invalid.schema { }
  invalid.save(invalid.load())
  precondition(defaults.data(forKey:contextKey) == malformed)
  invalid.beginNewContext(after:invalid.load().last?.id)
  let restored = try invalid.history(invalid.load(),imageQuestion:"Image")
  precondition(restored.isEmpty && invalid.load().count == 40)
  let transient = QFAssistantConversationStore(scope:scope,persistent:false,defaults:defaults)
  precondition(transient.load().isEmpty)
  precondition(recoveryFailures.isEmpty,recoveryFailures.joined(separator:"; "))
  print("PASS \(recoveryChecks) reset recovery and legacy migration checks")
  print("PASS actual context persistence beyond visible window and scoped isolation")
 }
}''')
    binary = folder/'check'
    subprocess.run(['xcrun','swiftc','-j','1','-parse-as-library','-module-cache-path',str(folder/'modules'),str(root/'QiafanYoupu/Features/Assistant/QFAssistantAgentContract.swift'),str(root/'QiafanYoupu/Features/Assistant/QFAssistantConversationStore.swift'),str(source),'-o',str(binary)],check=True,timeout=60)
    subprocess.run([str(binary)],check=True,timeout=15)
