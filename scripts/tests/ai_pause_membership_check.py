#!/usr/bin/env python3
"""Run retained shipping request/access policies without launching or buying in the App."""
from pathlib import Path
import subprocess, tempfile
ROOT = Path(__file__).resolve().parents[2]
policy = (ROOT/'QiafanYoupu/App/QFLaunchPolicy.swift').read_text().split('enum QFLaunchPolicy {')[0]
models = (ROOT/'QiafanYoupu/Core/Membership/QFMembershipModels.swift').read_text()
access = (ROOT/'QiafanYoupu/Core/Membership/QFMembershipAccessPolicy.swift').read_text()
check = r'''
@main enum Check {
 static func main() throws {
  var checks = 0
  func verify(_ value: Bool) { precondition(value); checks += 1 }
  verify(!QFAIAvailability.isEnabled)
  for path in ["me/assistant/chat/stream", "me/assistant/vision", "me/assistant/preview", "me/assistant/knowledge/search", "me/weekly-plan-proposals", "me/weekly-plan-proposals/1/accept"] {
   verify(!QFAIAvailability.permitsRequest(path:path,method:"POST"))
  }
  for path in ["me/plans", "me/purchases", "me/inventory", "me/plan-reminders", "me/membership/apple/purchase-context", "me/membership/apple/transactions"] {
   verify(QFAIAvailability.permitsRequest(path:path,method:"POST"))
  }
  verify(QFAIAvailability.permitsRequest(path:"me/assistant/credits",method:"GET"))
  verify(QFAIAvailability.permitsRequest(path:"me/assistant/memories/1",method:"DELETE"))
  verify(QFAIAvailability.permitsRequest(path:"me/assistant/chat/stream",method:"DELETE"))
  let binding = QFMembershipBinding(scope:"test/account-a",generation:1)
  let initial: [String:Any] = ["launchState":"OPEN", "activeSubscription":true,"productIds":["monthly"],
    "contractVersion":"core-subscription-v2","accessState":"ACTIVE","accessSource":"APPLE_SANDBOX",
    "appleEnvironment":"SANDBOX","serverTime":"2026-10-30T12:00:00Z","verifiedAt":"2026-10-30T12:00:00Z",
    "effectiveUntil":"2026-11-30T12:00:00Z","appleExpiresAt":"2026-11-30T12:00:00Z",
    "offlineUntil":"2026-10-30T12:15:00Z","revision":1,"accessEntitlements":["CORE_COOKING"]]
  func snapshot(_ changes:[String:Any]=[:]) throws -> QFMembershipVerifiedSnapshot? {
   let values = initial.merging(changes){_,new in new}
   let status = try JSONDecoder().decode(QFMembershipStatus.self,from:JSONSerialization.data(withJSONObject:values))
   return QFMembershipVerifiedSnapshot(status:status,binding:binding,receivedUptime:100,requestDuration:2)
  }
  let active = try snapshot()!
  verify(active.allowsAccess(for:binding,at:101,offline:false))
  verify(active.allowsAccess(for:binding,at:101,offline:true))
  verify(!active.allowsAccess(for:binding,at:998,offline:false))
  verify(!active.allowsAccess(for:.init(scope:"test/account-b",generation:1),at:101,offline:false))
  verify(!active.allowsAccess(for:.init(scope:"test/account-a",generation:2),at:101,offline:false))
  for state in ["UNKNOWN","NONE","EXPIRED","REVOKED"] { verify(try snapshot(["accessState":state]) == nil) }
  verify(try snapshot(["accessSource":"TEST"]) == nil)
  verify(try snapshot(["accessEntitlements":[String]()]) == nil)
  verify(try snapshot(["contractVersion":"legacy"]) == nil)
  print("PASS: \(checks) shipping AI request and subscription access assertions; no UI, StoreKit or network calls")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='qf-ai-pause-') as scratch:
 p=Path(scratch); f=p/'Check.swift'; f.write_text(policy+'\n'+models+'\n'+access+'\n'+check)
 subprocess.run(['xcrun','swiftc','-j','1','-parse-as-library','-module-cache-path',str(p/'modules'),str(f),'-o',str(p/'check')],check=True,timeout=60)
 subprocess.run([str(p/'check')],check=True,timeout=10)
