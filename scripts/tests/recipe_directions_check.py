#!/usr/bin/env python3
from pathlib import Path
import tempfile, subprocess
root=Path(__file__).resolve().parents[2]
source=root/'QiafanYoupu/Features/Recipe/QFRecipeDirections.swift'
assert source.exists(), 'Legacy ingredient/calculation chapters must not be numbered as cooking actions'
with tempfile.TemporaryDirectory(prefix='directions-',dir=root/'.build') as folder:
 p=Path(folder);test=p/'Check.swift'
 test.write_text(r'''import Foundation
@main enum Check {
 static func main() {
  let raw = [QFRecipeDirections.Section(title:"必备原料和工具",body:"- 内脂豆腐\n- 水果刀"),
   .init(title:"计算",body:"- 1 盒豆腐\n- 1 枚鸭蛋"),
   .init(title:"操作",body:"1. 大蒜和生姜切碎，备用\n2. 小米辣切圈\n   - 不吃辣可省略\n3. 煮熟。出锅。"),
   .init(title:"附加内容",body:"按口味调节辣度"),.init(title:"资料来源",body:"CC BY-SA source")]
  let result=QFRecipeDirections.project(raw)
  precondition(result.actions.count==3)
  precondition(result.actions[0].body=="大蒜和生姜切碎，备用")
  precondition(result.actions[1].body.contains("不吃辣可省略"))
  precondition(result.actions[2].body=="煮熟。出锅。", "Never invent boundaries by splitting sentences")
  precondition(result.ingredients.count==2 && result.notes.count==2)
  precondition(result.notes.last!.body=="CC BY-SA source", "Attribution must remain visible")
  let four=(1...4).map { QFRecipeDirections.Section(title:"阶段\($0)",body:"第\($0)段原文") }
  precondition(QFRecipeDirections.project(four).actions==four, "A real four-step recipe remains four steps")
  let ambiguous=[QFRecipeDirections.Section(title:"材料",body:"- 豆腐"),.init(title:"成品",body:"整段未知内容")]
  precondition(QFRecipeDirections.project(ambiguous).actions==ambiguous)
  let paragraph=[QFRecipeDirections.Section(title:"计算",body:"10g"),.init(title:"操作",body:"炒香后加水。烧开出锅。")]
  precondition(QFRecipeDirections.project(paragraph).actions.count==1)
  let optional=[QFRecipeDirections.Section(title:"计算",body:"10g"),.init(title:"操作",body:"### 开始制作\n1. 晃锅\n2. 捞出\n### 脆化（可选项）\n1. 喷油\n2. 再炸")]
  let alternatives=QFRecipeDirections.project(optional).actions
  precondition(alternatives.count==4 && alternatives[0].title=="开始制作" && alternatives[2].title=="脆化（可选项）")
  precondition(!alternatives[1].body.contains("脆化"))
  for (index,path) in CommandLine.arguments.dropFirst().enumerated() {
   let root=try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String:Any]
   let data=root["data"] as! [String:Any]
   let sections=(data["steps"] as! [[String:String]]).map { QFRecipeDirections.Section(title:$0["title"]!,body:$0["body"]!) }
   let projection=QFRecipeDirections.project(sections)
   precondition(projection.actions.count == (index==0 ? 13 : 9), "Actual source list counts must stay 13 and 9")
   precondition(projection.ingredients.count==2 && projection.notes.last!.title=="资料来源")
  }
  print("PASS: ingredients/context separated, source list actions preserved, nested details/attribution retained, no invented step count")
 }
}''')
 binary=p/'check'
 subprocess.run(['xcrun','swiftc','-parse-as-library','-module-cache-path',str(p/'modules'),str(source),str(test),'-o',str(binary)],check=True,timeout=45)
 subprocess.run([str(binary),str(root/'scripts/tests/fixtures/recipe-directions-mapo-tofu.json'),str(root/'scripts/tests/fixtures/recipe-directions-radish-brisket.json')],check=True,timeout=10)
