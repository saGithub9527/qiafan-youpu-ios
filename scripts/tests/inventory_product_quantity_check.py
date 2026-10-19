#!/usr/bin/env python3
"""Check displayed product totals without changing canonical lot mutation quantities."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
api = (root / 'QiafanYoupu/Core/Networking/QFPlanningAPI.swift').read_text()
purchase = (root / 'QiafanYoupu/Features/Plan/QFPurchaseReceiptModels.swift').read_text()
model = 'struct QFInventoryLot:' + api.split('struct QFInventoryLot:', 1)[1].split('\nstruct QFInventoryLedgerEntry:', 1)[0]
numbers = 'enum QFPurchaseNumber {' + purchase.split('enum QFPurchaseNumber {', 1)[1].split('\nextension QFAppSession', 1)[0]
harness = r'''
import Foundation
@main struct Check {
  static func main() throws {
    let json = #"{"id":"lot-a","ingredientId":"tea","ingredientName":"Tea","contentAvailable":false,"unitCode":"ml","initialQuantity":"1000","currentQuantity":"1000","location":"fridge","status":"ACTIVE","revision":3,"packageUnit":"bottle","packageSize":"1000","packageContentUnit":"ml","groupQuantity":"3000","groupLotCount":2}"#
    let lot = try JSONDecoder().decode(QFInventoryLot.self, from: Data(json.utf8))
    precondition(lot.displayedQuantity == "3" && lot.displayedUnitCode == "bottle")
    precondition(lot.currentQuantity == "1000" && lot.revision == 3, "Summaries must never replace a real batch's quantity or revision")
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(lot)) as! [String: Any]
    precondition(encoded["currentQuantity"] as? String == "1000")
    var legacy = lot; legacy.groupQuantity = nil; legacy.groupLotCount = nil
    precondition(legacy.displayedQuantity == "1" && legacy.displayedUnitCode == "bottle")
    var invalid = lot; invalid.groupQuantity = "200"
    precondition(invalid.displayedQuantity == "1", "A stale smaller total must not hide the current lot")
    invalid.groupQuantity = "bad"
    precondition(invalid.displayedQuantity == "1")
    var mixed = lot; mixed.hasMultipleCostSources = true
    precondition(mixed.displayedQuantity == "3000" && mixed.displayedUnitCode == "ml", "Mixed packages cannot become a guessed bottle count")
    var missing = lot; missing.packageSize = nil
    precondition(missing.displayedQuantity == "3000" && missing.displayedUnitCode == "ml")
    var repeating = lot; repeating.groupQuantity = "1001"; repeating.packageSize = "3"
    precondition(repeating.displayedQuantity == "1001" && repeating.displayedUnitCode == "ml", "Do not invent a rounded package count")
    var fractional = lot; fractional.groupQuantity = "1500"
    precondition(fractional.displayedQuantity == "1.5" && fractional.displayedUnitCode == "bottle")
    var oldPayload = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    oldPayload.removeValue(forKey: "groupQuantity"); oldPayload.removeValue(forKey: "groupLotCount")
    let decodedLegacy = try JSONDecoder().decode(QFInventoryLot.self, from: JSONSerialization.data(withJSONObject: oldPayload))
    precondition(decodedLegacy.groupQuantity == nil && decodedLegacy.displayedQuantity == "1")
    print("PASS inventory product quantities: exact bottles, grouped totals, legacy fallback, mixed/unknown specs and canonical lot preservation")
  }
}
'''
with tempfile.TemporaryDirectory(prefix='qf-inventory-product-') as folder:
    temp = Path(folder)
    (temp / 'Models.swift').write_text('import Foundation\n' + model + '\n' + numbers)
    (temp / 'Check.swift').write_text(harness)
    subprocess.run(['swiftc', '-parse-as-library', str(temp / 'Models.swift'), str(temp / 'Check.swift'), '-o', str(temp / 'check')], check=True, timeout=25)
    subprocess.run([str(temp / 'check')], check=True, timeout=5)
