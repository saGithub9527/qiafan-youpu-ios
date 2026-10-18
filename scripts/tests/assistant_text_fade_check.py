#!/usr/bin/env python3
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
source = root/'QiafanYoupu/Features/Assistant/QFAssistantTextReveal.swift'
assert 'struct QFAssistantTextFade' in source.read_text(), 'New text needs a drawing-only fade instead of abrupt full text replacement'
with tempfile.TemporaryDirectory(prefix='text-fade-',dir=root/'.build') as folder:
 p=Path(folder); test=p/'Check.swift'
 test.write_text(r'''import Foundation
@main enum Check {
 static func main() {
  var fade = QFAssistantTextFade()
  fade.append(NSRange(location: 0, length: 5), at: 10)
  precondition(fade.advance(at: 10).first!.opacity == 0)
  let mid = fade.advance(at: 10.09).first!.opacity
  precondition(mid > 0.45 && mid < 0.55)
  fade.append(NSRange(location: 5, length: 2), at: 10.1)
  let frame = fade.advance(at: 10.18)
  precondition(frame.first!.opacity > 0.999 && frame.last!.opacity < 0.5)
  precondition(fade.advance(at: 10.3).last!.opacity == 1 && !fade.isActive)
  for index in 0..<200 { fade.append(NSRange(location: index, length: 1), at: 20) }
  precondition(fade.advance(at: 20.1).count <= 32)
  _ = fade.advance(at: 21); precondition(!fade.isActive)
  print("PASS: independent appended UTF16 ranges fade 0→1 in 180ms, expire and remain bounded")
 }
}''')
 binary=p/'check'
 subprocess.run(['xcrun','swiftc','-parse-as-library','-module-cache-path',str(p/'modules'),str(source),str(test),'-o',str(binary)],check=True,timeout=45)
 subprocess.run([str(binary)],check=True,timeout=10)
