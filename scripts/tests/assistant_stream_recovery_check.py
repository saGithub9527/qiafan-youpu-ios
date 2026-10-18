#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='chat-recovery-', dir=root / '.build') as tmp:
    tmp = Path(tmp)
    test = tmp / 'Check.swift'
    test.write_text('''import Foundation
@main enum Check {
 static func main() {
  for status in [0,200,502,503,504] {
   precondition(QFAssistantStreamRecovery.delay(attempt:0,supported:true,status:status) == 800_000_000)
   precondition(QFAssistantStreamRecovery.delay(attempt:1,supported:true,status:status) == 2_000_000_000)
   precondition(QFAssistantStreamRecovery.delay(attempt:2,supported:true,status:status) == nil)
   precondition(QFAssistantStreamRecovery.delay(attempt:0,supported:false,status:status) == nil)
  }
  for status in [201,301,400,401,403,404,409,422,429] {
   precondition(QFAssistantStreamRecovery.delay(attempt:0,supported:true,status:status) == nil)
  }
  print("PASS: two bounded same-job recovery delays; no initial POST replay on legacy server; auth/business denials terminal")
 }
}''')
    binary = tmp / 'check'
    subprocess.run(['xcrun','swiftc','-parse-as-library','-module-cache-path',str(tmp/'modules'),
        str(root/'QiafanYoupu/Core/Networking/QFAssistantStreamRecovery.swift'),str(test),'-o',str(binary)],check=True,timeout=45)
    subprocess.run([str(binary)],check=True,timeout=10)
