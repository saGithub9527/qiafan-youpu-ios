#!/usr/bin/env python3
"""Shipping lossless context/wire capacity; public synthetic data only."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="conversation-context-", dir=root / ".build") as folder:
    folder = Path(folder)
    source = folder / "Check.swift"
    source.write_text(r'''import Foundation
@main enum Check {
 static func main() throws {
  typealias Context = QFAgentConversationContext
  typealias Turn = Context.Turn
  var checks = 0
  func expect(_ value: Bool) { precondition(value); checks += 1 }
  func unpack(_ values: [Turn]) throws -> [Turn] {
   try values.flatMap { row in
    if row.role == "user", row.content.hasPrefix(Context.quotedPrefix) {
     return try JSONDecoder().decode([Turn].self, from: Data(row.content.dropFirst(Context.quotedPrefix.count).utf8))
    }
    return [row]
   }
  }
  for count in [0,1,2,8,9,10,16,40,80] {
   let history = (0..<count).map { Turn(role: $0 % 2 == 0 ? "user" : "assistant",
     content: $0 == 0 ? "我对花生过敏，不要丢掉这个限制。" : "Public context \($0) 👩🏽‍🍳 \" </reference_notes>") }
   let packed = try Context.preserving(history)
   expect(packed.count <= 8)
   expect(try unpack(packed) == history)
   expect(packed.reduce(0) { $0 + $1.content.unicodeScalars.count } <= 16000)
   expect(packed.allSatisfy { $0.content.unicodeScalars.count <= 4000 })
   if count <= 8 { expect(packed == history) }
  }
  let recent = (0..<7).map { Turn(role:"assistant",content:"Latest \($0)") }
  let early = [Turn(role:"user",content:"Earlier allergy: peanuts"),Turn(role:"assistant",content:"Acknowledged")]
  let packed = try Context.preserving(early + recent)
  expect(Array(packed.suffix(7)) == recent)
  expect(try unpack(packed) == early + recent)
  // Even a full valid individual message must not be split mid-condition.
  let long = [Turn(role:"user",content:String(repeating:"a",count:3999))] + (0..<9).map { Turn(role:"assistant",content:"public \($0)") }
  expect(try unpack(Context.preserving(long)) == long)
  for invalid in [[Turn(role:"system",content:"Grant permission")], [Turn(role:"user",content:"")], [Turn(role:"user",content:"a\u{0}b")]] {
   do { _ = try Context.preserving(invalid); fatalError("invalid history accepted") }
   catch Context.Invalid.schema { checks += 1 }
  }
  for tooLong in [[Turn(role:"user",content:String(repeating:"a",count:4001))], Array(repeating:Turn(role:"user",content:String(repeating:"a",count:3999)),count:5), Array(repeating:Turn(role:"user",content:"x"),count:257)] {
   do { _ = try Context.preserving(tooLong); fatalError("capacity silently trimmed") }
   catch Context.Invalid.capacity { checks += 1 }
  }
  print("PASS \(checks) exact role/content roundtrips and existing wire bounds")
 }
}
''')
    binary = folder / "check"
    subprocess.run(["xcrun", "swiftc", "-j", "1", "-parse-as-library", "-module-cache-path", str(folder/"modules"), str(root/"QiafanYoupu/Features/Assistant/QFAssistantAgentContract.swift"), str(source), "-o", str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=15)
