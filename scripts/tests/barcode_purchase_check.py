#!/usr/bin/env python3
"""Compile shipping barcode metadata/draft rules; never touches App preferences or network."""
from pathlib import Path
import tempfile,subprocess
root=Path(__file__).resolve().parents[2]
source=root/'QiafanYoupu/Features/Ingredient/QFBarcodePurchase.swift'
assert source.exists(), 'Barcode purchase adapter is not implemented'
raw_models=(root/'QiafanYoupu/Features/Plan/QFPurchaseReceiptModels.swift').read_text()
models=raw_models.split('\nextension QFAppSession {')[0]+'\nstruct QFPurchaseAdjustmentItem'+raw_models.split('\nstruct QFPurchaseAdjustmentItem')[1].split('\nextension QFAppSession {')[0]
stubs=r'''
import Foundation
struct QFShoppingList {
 struct Item { var id:String; var checked:Bool; var received:Bool?; var ingredientId:String?; var name:String; var quantityMax:String?;var quantityMin:String?;var unitCode:String?;var revision:Int }
 var id:String;var householdId:String?;var revision:Int;var items:[Item]
}
enum QFManualPlanDraft {
 static func date(_ value:String)->Date? { let f=DateFormatter();f.dateFormat="yyyy-MM-dd";f.locale=Locale(identifier:"en_US_POSIX");f.isLenient=false;return f.date(from:value) }
}
'''
harness=r'''
import Foundation
@main struct Check {
 static func main() throws {
 let barcode=QFProductBarcode(value:"3017620422003",symbology:"EAN13")!
 let item=QFPurchaseReceiptLine.scannedProduct(barcode:barcode,name:"榛子酱",source:"OPEN_FOOD_FACTS")
 precondition(item.quantity=="1" && item.unitCode=="piece" && item.lineAmount==nil && item.ingredientId==nil)
 precondition(item.scanBarcode==barcode.value && item.scanProductSource=="OPEN_FOOD_FACTS")
 var draft=QFPurchaseReceiptDraft(date:"2026-10-17",householdId:nil)
 precondition(draft.addScannedProduct(item) == .added)
 precondition(draft.addScannedProduct(item) == .duplicate && draft.items.count==1 && draft.items[0].quantity=="1")
 let ingredient=UUID().uuidString.lowercased();draft.items[0].ingredientId=ingredient;draft.items[0].name="我改过的商品名称"
 let restored=try JSONDecoder().decode(QFPurchaseReceiptDraft.self,from:JSONEncoder().encode(draft))
 precondition(restored.items[0].name=="我改过的商品名称" && restored.items[0].ingredientId==ingredient && restored.items[0].lineAmount==nil)
 let request=try restored.request()
 let json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as! [String:Any]
 let line=(json["items"] as! [[String:Any]])[0]
 precondition(line["name"] as? String=="我改过的商品名称" && line["scanBarcode"]==nil && line["scanProductSource"]==nil && line["lotId"]==nil)
 draft.pending = .init(body:request,language:"zh-Hans")
 precondition(draft.addScannedProduct(item) == .locked)
 var full=restored;full.items=(0..<40).map { i in var v=item;v.id=UUID().uuidString;v.scanBarcode=String(i);return v }
 precondition(full.addScannedProduct(item) == .full)
 let response=#"{"status":"success","product":{"code":"3017620422003","product_name_zh":"榛子酱","product_name":"Hazelnut spread","quantity":"750 g","price":999}}"#
 let info=try QFBarcodeProductInfo.read(Data(response.utf8),requestedCode:barcode.lookupCode!,language:"zh-Hans")
 precondition(info?.name=="榛子酱")
 let wrong=try QFBarcodeProductInfo.read(Data(response.utf8),requestedCode:"1234567890128",language:"en");precondition(wrong==nil)
 let absent=#"{"status":"failure","result":{"id":"product_not_found"}}"#
 let missing=try QFBarcodeProductInfo.read(Data(absent.utf8),requestedCode:barcode.value,language:"zh-Hans");precondition(missing==nil)
 let bad=#"{"status":"success","product":{"code":"3017620422003","product_name":"\u0000bad"}}"#
 let invalid=try QFBarcodeProductInfo.read(Data(bad.utf8),requestedCode:barcode.value,language:"en");precondition(invalid==nil)
 var old=try JSONSerialization.jsonObject(with:JSONEncoder().encode(restored)) as! [String:Any]
 var legacyLines=old["items"] as! [[String:Any]];legacyLines[0].removeValue(forKey:"scanBarcode");legacyLines[0].removeValue(forKey:"scanProductSource");old["items"]=legacyLines
 let legacy=try JSONDecoder().decode(QFPurchaseReceiptDraft.self,from:JSONSerialization.data(withJSONObject:old))
 precondition(legacy.items[0].scanBarcode==nil && legacy.items[0].name==restored.items[0].name)
 print("PASS barcode purchase: editable names, no inferred price, default count, idempotent draft append, frozen/legacy/API boundaries and matched metadata")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='qf-barcode-purchase-') as folder:
 p=Path(folder);(p/'Stubs.swift').write_text(stubs);(p/'Models.swift').write_text(models);(p/'Main.swift').write_text(harness)
 cmd=['swiftc','-parse-as-library',str(root/'QiafanYoupu/Features/Ingredient/QFProductBarcode.swift'),str(source),str(p/'Stubs.swift'),str(p/'Models.swift'),str(p/'Main.swift'),'-o',str(p/'check')]
 subprocess.run(cmd,check=True,timeout=20);subprocess.run([str(p/'check')],check=True,timeout=5)
