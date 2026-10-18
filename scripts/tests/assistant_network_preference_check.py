#!/usr/bin/env python3
from pathlib import Path
import tempfile,subprocess
root=Path(__file__).resolve().parents[2]
source=root/'QiafanYoupu/Features/Assistant/QFAssistantNetworkPreference.swift'
assert source.exists(), 'Absent network preference must default ON without overwriting an explicit OFF'
with tempfile.TemporaryDirectory(prefix='network-default-',dir=root/'.build') as directory:
 p=Path(directory);test=p/'Check.swift'
 test.write_text(r'''import Foundation
@main enum Check {
 static func main() {
  let suite="qf-network-check-"+UUID().uuidString
  let defaults=UserDefaults(suiteName:suite)!
  defer { defaults.removePersistentDomain(forName:suite) }
  let a=QFAssistantNetworkPreference.key(scope:"test-account-a")
  let b=QFAssistantNetworkPreference.key(scope:"test-account-b")
  precondition(QFAssistantNetworkPreference.isEnabled(defaults:defaults,key:a))
  precondition(defaults.object(forKey:a)==nil, "Reading a default is not a persisted user choice")
  defaults.set(false,forKey:a)
  precondition(!QFAssistantNetworkPreference.isEnabled(defaults:defaults,key:a))
  precondition(QFAssistantNetworkPreference.isEnabled(defaults:defaults,key:b))
  let reopened=UserDefaults(suiteName:suite)!
  precondition(!QFAssistantNetworkPreference.isEnabled(defaults:reopened,key:a), "Relaunch preserves explicit OFF")
  defaults.set(true,forKey:a)
  precondition(QFAssistantNetworkPreference.isEnabled(defaults:defaults,key:a))
  defaults.removeObject(forKey:a)
  precondition(QFAssistantNetworkPreference.isEnabled(defaults:defaults,key:a))
  print("PASS: absent defaults ON, explicit OFF/ON preserved, account isolation, no write on read")
 }
}''')
 binary=p/'check'
 subprocess.run(['xcrun','swiftc','-j','1','-parse-as-library','-module-cache-path',str(p/'modules'),str(source),str(test),'-o',str(binary)],check=True,timeout=45)
 subprocess.run([str(binary)],check=True,timeout=10)
