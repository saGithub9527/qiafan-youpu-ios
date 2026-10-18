#!/usr/bin/env python3
"""Exercise real voice-session transitions without microphone or model use."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
source = root / 'QiafanYoupu/Features/Assistant/QFAssistantVoiceInput.swift'
assert source.exists(), 'Voice recording needs a separate session state, independent of AI generation'
with tempfile.TemporaryDirectory(prefix='voice-state-', dir=root / '.build') as directory:
    tmp = Path(directory)
    test = tmp / 'Check.swift'
    test.write_text(r'''import Foundation
@main enum Check {
 static func main() {
  var state = QFAssistantVoiceInput()
  let token = state.begin(draft: "原来的草稿")!
  precondition(state.phase == .authorizing && state.isBusy)
  precondition(state.start(token: token))
  state.receive("番茄", token: token)
  precondition(state.transcript == "番茄")
  state.receive("番茄炒蛋", token: token)
  precondition(state.transcript == "番茄炒蛋", "Partial transcripts replace, never append duplicate prefixes")
  precondition(state.release() && state.phase == .finishing)
  state.receive("番茄炒蛋怎么做？", token: token)
  precondition(state.complete(token: token) == "原来的草稿\n番茄炒蛋怎么做？")
  precondition(!state.isBusy && state.complete(token: token) == nil)
  let denied = state.begin(draft: "保留")!
  precondition(!state.release())
  precondition(!state.start(token: denied), "Releasing before permission returns must never start a microphone")
  let cancelled = state.begin(draft: "保留")!; precondition(state.start(token: cancelled))
  state.receive("丢弃", token: cancelled); state.setCancelArmed(true)
  precondition(!state.release() && !state.isBusy)
  state.receive("迟到", token: cancelled); precondition(state.transcript.isEmpty)
  precondition(state.complete(token: cancelled) == nil)
  let next = state.begin(draft: "")!; precondition(state.start(token: next))
  state.setCancelArmed(true); state.setCancelArmed(false)
  state.receive("下一句", token: next); precondition(state.release())
  precondition(state.complete(token: next) == "下一句")
  let empty = state.begin(draft: "不删")!; precondition(state.start(token: empty)); precondition(state.release())
  precondition(state.complete(token: empty) == nil)
  let scope = state.begin(draft: "私密")!; precondition(state.start(token: scope)); state.cancel()
  precondition(!state.isCurrent(scope)); state.receive("旧账号", token: scope)
  precondition(state.complete(token: scope) == nil)
  print("PASS: live partial replacement, draft merge once, release, slide cancel, late authorization/result isolation")
 }
}''')
    binary = tmp / 'check'
    subprocess.run(['xcrun','swiftc','-parse-as-library','-module-cache-path',str(tmp/'modules'),str(source),str(test),'-o',str(binary)],check=True,timeout=45)
    subprocess.run([str(binary)],check=True,timeout=10)
