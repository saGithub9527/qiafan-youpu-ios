#!/usr/bin/env python3
"""Bounded Foundation-only checks of the actual Unicode reveal component."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = root / 'QiafanYoupu/Features/Assistant/QFAssistantTextReveal.swift'
assert source.is_file(), 'Missing production Unicode text reveal component'
with tempfile.TemporaryDirectory(prefix='chat-reveal-', dir=root / '.build') as tmp:
    tmp = Path(tmp)
    test = tmp / 'Check.swift'
    test.write_text('''import Foundation
@main enum Check {
 static func main() {
  var value = QFAssistantTextReveal()
  value.receive("你好👨‍👩‍👧‍👦！")
  precondition(value.visible.isEmpty)
  value.step(); precondition(value.visible == "你")
  value.step(); precondition(value.visible == "你好")
  value.step(); precondition(value.visible == "你好👨‍👩‍👧‍👦")
  value.receive("你好👨‍👩‍👧‍👦！第二段")
  while !value.isComplete { value.step() }
  precondition(value.visible == "你好👨‍👩‍👧‍👦！第二段")
  value.receive("权威的最终修正"); precondition(value.visible == "权威的最终修正")
  value.receive("权威的最终修正加长"); value.step(reduceMotion: true)
  precondition(value.visible == "权威的最终修正加长" && value.isComplete)
  var burst = QFAssistantTextReveal(); burst.receive(String(repeating: "字", count: 3000))
  var frames = 0
  while !burst.isComplete { burst.step(); frames += 1; precondition(frames <= 18, "A completed answer must catch up within 18 frames, not seconds of artificial typing") }
  precondition(burst.visible.count == 3000)
  var live = QFAssistantTextReveal()
  for i in 1...50 { live.receive(String(repeating: "中", count: i * 20)); live.step() }
  for _ in 0..<18 { live.step() }
  precondition(live.isComplete && live.visible.count == 1000)
  let settled = live.visible; live.receive(settled); live.step(); precondition(live.visible == settled)
  var returned = QFAssistantTextReveal(initial: "已显示的前缀")
  returned.receive("已显示的前缀与新增文字"); returned.step()
  precondition(returned.visible == "已显示的前缀与")
  print("PASS: Unicode clusters, streaming append, terminal correction, Reduce Motion, bounded backlog")
 }
}''')
    binary = tmp / 'check'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(tmp / 'modules'),
                    str(source), str(test), '-o', str(binary)], check=True, timeout=45)
    subprocess.run([str(binary)], check=True, timeout=10)
