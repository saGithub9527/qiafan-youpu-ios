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
 precondition(item.quantity=="1" && item.unitCode=="pack" && item.lineAmount==nil && item.ingredientId==nil)
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
 precondition(info?.netContent?.value=="750" && info?.netContent?.unit=="g")
 let actualSuccess=#"{"status":"success","code":"3017620422003","product":{"code":"3017620422003","product_name":"Nutella","quantity":"400 g e","product_quantity":400,"product_quantity_unit":"g","price":999}}"#
 let actualInfo=try QFBarcodeProductInfo.read(Data(actualSuccess.utf8),requestedCode:barcode.value,language:"en")!
 precondition(actualInfo.packageLabel=="400 g e" && actualInfo.netContent?.value=="400" && actualInfo.netContent?.unit=="g")
 var packaged=QFPurchaseReceiptLine.scannedProduct(barcode:barcode,info:actualInfo)
 precondition(packaged.name=="Nutella" && packaged.quantity=="1" && packaged.packageSize=="400" && packaged.packageContentUnit=="g" && packaged.packageUnit=="pack" && packaged.lineAmount==nil)
 packaged.name="My edited name";packaged.packageSize="350"
 packaged.applyBarcodeInfo(actualInfo,status:.found)
 precondition(packaged.name=="My edited name" && packaged.packageSize=="350", "A retry must not overwrite user edits")
 packaged.applyBarcodeInfo(nil,status:.unavailable)
 precondition(packaged.name=="My edited name" && packaged.packageSize=="350" && packaged.scanLookupState=="unavailable")
 packaged.ingredientId=ingredient
 var enriched=restored;enriched.items=[packaged]
 let enrichedRequest=try enriched.request()
 let enrichedJSON=try JSONSerialization.jsonObject(with:JSONEncoder().encode(enrichedRequest)) as! [String:Any]
 let enrichedLine=(enrichedJSON["items"] as! [[String:Any]])[0]
 precondition(enrichedLine["packageSize"] as? String=="350" && enrichedLine["packageContentUnit"] as? String=="g" && enrichedLine["lineAmount"]==nil)
 for key in ["scanBarcode","scanBarcodeSymbology","scanPackageLabel","scanLookupState","scanProductSource"] {precondition(enrichedLine[key]==nil)}
 for (raw,value,unit) in [(#""quantity":"1500 ml","product_quantity":"1500","product_quantity_unit":"ml""#,"1500","ml"),(#""quantity":"1,5 L""#,"1.5","l")] {
  let bytes=Data((#"{"status":"success","product":{"code":"3017620422003","product_name":"Drink","#+raw+"}}").utf8)
  let metadata=try QFBarcodeProductInfo.read(bytes,requestedCode:barcode.value,language:"en")!
  precondition(metadata.netContent?.value==value && metadata.netContent?.unit==unit)
 }
 for raw in [#""quantity":"6 x 25 g""#,#""quantity":"750 g","product_quantity":true,"product_quantity_unit":"g""#,#""quantity":"bottle","product_quantity":-10,"product_quantity_unit":"g""#,#""product_quantity":10,"product_quantity_unit":"oz""#] {
  let bytes=Data((#"{"status":"success","product":{"code":"3017620422003","product_name":"Food","#+raw+"}}").utf8)
  let metadata=try QFBarcodeProductInfo.read(bytes,requestedCode:barcode.value,language:"en")!
  precondition(metadata.netContent==nil,"Do not invent contents from multipacks, invalid types or unknown units")
 }
 let noName=#"{"status":"success","product":{"code":"3017620422003","quantity":"500 g","product_quantity":500,"product_quantity_unit":"g"}}"#
 let weightOnly=try QFBarcodeProductInfo.read(Data(noName.utf8),requestedCode:barcode.value,language:"en")!
 precondition(weightOnly.name==nil && weightOnly.netContent?.value=="500")
 let actualNotFound=#"{"code":"6925303723934","status":"failure","result":{"id":"product_not_found"}}"#
 let actualMissing=try QFBarcodeProductInfo.read(Data(actualNotFound.utf8),requestedCode:"6925303723934",language:"zh-Hans")
 precondition(actualMissing==nil)
 let wrong=try QFBarcodeProductInfo.read(Data(response.utf8),requestedCode:"1234567890128",language:"en");precondition(wrong==nil)
 let absent=#"{"status":"failure","result":{"id":"product_not_found"}}"#
 let missing=try QFBarcodeProductInfo.read(Data(absent.utf8),requestedCode:barcode.value,language:"zh-Hans");precondition(missing==nil)
 let bad=#"{"status":"success","product":{"code":"3017620422003","product_name":"\u0000bad"}}"#
 let invalid=try QFBarcodeProductInfo.read(Data(bad.utf8),requestedCode:barcode.value,language:"en");precondition(invalid==nil)
 var old=try JSONSerialization.jsonObject(with:JSONEncoder().encode(restored)) as! [String:Any]
 var legacyLines=old["items"] as! [[String:Any]]
 for key in ["scanBarcode","scanBarcodeSymbology","scanPackageLabel","scanLookupState","scanProductSource"] {legacyLines[0].removeValue(forKey:key)}
 old["items"]=legacyLines
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
