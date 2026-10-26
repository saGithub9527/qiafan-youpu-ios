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
 static var allowMutations = false
 static var files: [String:Set<String>] = [:]
 static var failures = Set<String>()
 static var saveCalls = 0
 static func save(_ data: Data, video: Bool, scope: String) throws -> Saved {
  precondition(allowMutations,"unexpected media write")
  let id = "local:" + UUID().uuidString.lowercased(); files[scope,default:[]].insert(id); saveCalls += 1
  return Saved(id:id)
 }
 static func remove(_ id: String, scope: String) { precondition(allowMutations,"unexpected media delete"); files[scope]?.remove(id) }
 static func removeAll(scope: String) throws {
  precondition(allowMutations,"unexpected media directory deletion")
  if failures.contains(scope) { throw CocoaError(.fileWriteNoPermission) }
  files.removeValue(forKey:scope)
 }
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
  defaults.set(["unopened-retained-image"], forKey:storageKey(scope) + ".images")
  let beforeReadOnly = defaults.dictionaryRepresentation() as NSDictionary
  precondition(reopened.readOnlyMessages().count == 40)
  precondition(beforeReadOnly.isEqual(to:defaults.dictionaryRepresentation()), "history viewing must not write preferences or prune stored images")
  for other in [QFAgentScope(account:"history-other-account",household:nil,language:"zh-Hans"),
    QFAgentScope(account:scope.account,household:"history-other-household",language:"zh-Hans"),
    QFAgentScope(account:scope.account,household:nil,language:"en")] {
   precondition(QFAssistantConversationStore(scope:other,defaults:defaults).readOnlyMessages().isEmpty)
  }
  defaults.removeObject(forKey:storageKey(scope) + ".images")
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

  // Purge uses the real encoded scope keys and a media-only in-memory stub.
  // No user defaults domain or filesystem images outside this suite are touched.
  QFLocalMediaStore.allowMutations = true
  let target = "production.https://api.fixture.invalid/api/v1.owner-a"
  let languages = ["zh-Hans","zh-Hant","en","ja","ko","ru","es","fr","de","pt-BR"]
  let households: [String?] = [nil,"family-a","family-b"]
  var targetScopes: [QFAgentScope] = []
  var staleStores: [QFAssistantConversationStore] = []
  let retainedMessage = QFAssistantLocalMessage(id:UUID(),role:"user",text:"isolated deletion fixture",createdAt:Date(),state:"complete")
  let suffixes = ["", ".context", ".contextBoundary", ".nativeCapacity", ".images"]
  for household in households {
   for language in languages {
    let value = QFAgentScope(account:target,household:household,language:language)
    targetScopes.append(value)
    let item = QFAssistantConversationStore(scope:value,defaults:defaults)
    staleStores.append(item)
    item.save([retainedMessage]); item.markNativeCapacityReached()
    defaults.set(retainedMessage.id.uuidString,forKey:storageKey(value) + ".contextBoundary")
    _ = try item.saveImage(Data([1])); _ = try item.saveImage(Data([2])) // Includes an image outside the visible row window.
   }
  }
  let orphan = QFAgentScope(account:target,household:"suffix-only",language:"en")
  defaults.set(Data("orphan context".utf8),forKey:storageKey(orphan) + ".context")
  QFLocalMediaStore.files["assistant-chat|" + orphan.cacheKey] = ["old-orphan-image"]
  targetScopes.append(orphan)
  let others = [QFAgentScope(account:target + "-suffix",household:nil,language:"zh-Hans"),
    QFAgentScope(account:"production.https://other-api.fixture.invalid/api/v1.owner-a",household:nil,language:"zh-Hans"),
    QFAgentScope(account:"test.https://api.fixture.invalid/api/v1.owner-a",household:nil,language:"zh-Hans")]
  for other in others {
   let item = QFAssistantConversationStore(scope:other,defaults:defaults)
   item.save([retainedMessage]); _ = try item.saveImage(Data([3]))
  }
  let corruptKey = "qf.assistant.conversation.v2.not-base64.context"
  defaults.set("do not guess ownership",forKey:corruptKey)
  let invalidScopeKey = "qf.assistant.conversation.v2." + Data("{\"account\":\"incomplete\"}".utf8).base64EncodedString() + ".images"
  defaults.set("not a scope",forKey:invalidScopeKey)
  defaults.set("unknown version remains",forKey:storageKey(targetScopes[0]) + ".future-field")
  let otherSnapshots = others.map { value in suffixes.map { defaults.object(forKey:storageKey(value) + $0) ?? NSNull() } }
  precondition(QFAssistantConversationStore.purge(account:target,defaults:defaults))
  for value in targetScopes {
   for suffix in suffixes { precondition(defaults.object(forKey:storageKey(value) + suffix) == nil) }
   precondition(QFLocalMediaStore.files["assistant-chat|" + value.cacheKey] == nil)
  }
  precondition(defaults.string(forKey:corruptKey) == "do not guess ownership")
  precondition(defaults.string(forKey:invalidScopeKey) == "not a scope")
  precondition(defaults.string(forKey:storageKey(targetScopes[0]) + ".future-field") == "unknown version remains")
  for (index,other) in others.enumerated() {
   let after = suffixes.map { defaults.object(forKey:storageKey(other) + $0) ?? NSNull() }
   precondition((otherSnapshots[index] as NSArray).isEqual(to:after),"other account/environment changed")
   precondition(QFLocalMediaStore.files["assistant-chat|" + other.cacheKey]?.isEmpty == false)
  }
  let savesBeforeLateCallbacks = QFLocalMediaStore.saveCalls
  for item in staleStores {
   item.save([retainedMessage]); item.markNativeCapacityReached(); item.beginNewContext(after:nil)
   precondition(item.load().isEmpty && item.readOnlyMessages().isEmpty)
   do { _ = try item.saveImage(Data([4])); fatalError("stale store recreated an image") }
   catch is CancellationError {}
  }
  precondition(QFLocalMediaStore.saveCalls == savesBeforeLateCallbacks)
  for value in targetScopes { for suffix in suffixes { precondition(defaults.object(forKey:storageKey(value) + suffix) == nil) } }
  precondition(QFAssistantConversationStore.purge(account:target,defaults:defaults),"repeated purge must be safe")

  let retryScope = QFAgentScope(account:"retry-account-fixture",household:nil,language:"en")
  let retryStore = QFAssistantConversationStore(scope:retryScope,defaults:defaults)
  retryStore.save([retainedMessage]); _ = try retryStore.saveImage(Data([5]))
  let healthyScope = QFAgentScope(account:retryScope.account,household:"healthy",language:"ja")
  let healthyStore = QFAssistantConversationStore(scope:healthyScope,defaults:defaults)
  healthyStore.save([retainedMessage]); _ = try healthyStore.saveImage(Data([5]))
  let retryMedia = "assistant-chat|" + retryScope.cacheKey
  QFLocalMediaStore.failures.insert(retryMedia)
  precondition(!QFAssistantConversationStore.purge(account:retryScope.account,defaults:defaults))
  precondition(defaults.data(forKey:storageKey(retryScope)) != nil,"failed media cleanup must retain scope discovery for retry")
  precondition(defaults.object(forKey:storageKey(healthyScope)) == nil && QFLocalMediaStore.files["assistant-chat|" + healthyScope.cacheKey] == nil,"one failed scope must not block other scopes")
  let retrySnapshot = defaults.dictionaryRepresentation() as NSDictionary
  retryStore.save([retainedMessage]); retryStore.markNativeCapacityReached(); retryStore.beginNewContext(after:nil)
  do { _ = try retryStore.saveImage(Data([6])); fatalError("failed cleanup left old writer active") }
  catch is CancellationError {}
  precondition(retrySnapshot.isEqual(to:defaults.dictionaryRepresentation()))
  QFLocalMediaStore.failures.remove(retryMedia)
  precondition(QFAssistantConversationStore.purge(account:retryScope.account,defaults:defaults))
  precondition(defaults.object(forKey:storageKey(retryScope)) == nil && QFLocalMediaStore.files[retryMedia] == nil)
  // Epoch invalidation targets old instances, not a permanent block on a future authenticated session.
  let future = QFAssistantConversationStore(scope:retryScope,defaults:defaults)
  future.save([retainedMessage]); precondition(future.readOnlyMessages().count == 1)
  precondition(recoveryFailures.isEmpty,recoveryFailures.joined(separator:"; "))
  print("PASS \(recoveryChecks) reset recovery and legacy migration checks")
  print("PASS actual context persistence beyond visible window and scoped isolation")
  print("PASS account purge across households/languages, retained scopes, retry, and stale-writer rejection")
 }
}''')
    binary = folder/'check'
    subprocess.run(['xcrun','swiftc','-j','1','-parse-as-library','-module-cache-path',str(folder/'modules'),str(root/'QiafanYoupu/Features/Assistant/QFAssistantAgentContract.swift'),str(root/'QiafanYoupu/Features/Assistant/QFAssistantConversationStore.swift'),str(source),'-o',str(binary)],check=True,timeout=60)
    subprocess.run([str(binary)],check=True,timeout=15)
