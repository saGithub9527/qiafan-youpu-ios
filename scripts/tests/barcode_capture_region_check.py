#!/usr/bin/env python3
"""Run the shipping capture-region policy without camera, network or user data."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
program = '''import Foundation
import CoreGraphics
@main struct Check {
 static func main() {
  let all = CGRect(x: 0,y: 0,width: 1,height: 1)
  precondition(QFBarcodeCaptureRegion.effective(.zero, previewing: false) == all, "First layout before preview must not disable detection")
  precondition(QFBarcodeCaptureRegion.effective(.zero, previewing: true) == all, "Transient empty layout must remain scannable")
  precondition(QFBarcodeCaptureRegion.effective(CGRect(x: 0.2,y: 0.1,width: 0.6,height: 0.7), previewing: true) == CGRect(x: 0.2,y: 0.1,width: 0.6,height: 0.7))
  let clipped = QFBarcodeCaptureRegion.effective(CGRect(x: -0.1,y: 0.1,width: 1.2,height: 0.7), previewing: true)
  precondition(abs(clipped.origin.x) < 0.000000001 && abs(clipped.origin.y - 0.1) < 0.000000001 && abs(clipped.width - 1) < 0.000000001 && abs(clipped.height - 0.7) < 0.000000001)
  precondition(QFBarcodeCaptureRegion.effective(CGRect(x: 2,y: 2,width: 1,height: 1), previewing: true) == all)
  precondition(QFBarcodeCaptureRegion.effective(CGRect(x: CGFloat.nan,y: 0,width: 1,height: 1), previewing: true) == all)
  print("PASS capture region: first preview, invalid geometry, bounded ROI")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='qf-capture-region-') as folder:
    p = Path(folder); (p/'Main.swift').write_text(program)
    subprocess.run(['swiftc','-parse-as-library',str(root/'QiafanYoupu/Features/Ingredient/QFProductBarcode.swift'),str(p/'Main.swift'),'-o',str(p/'check')],check=True,timeout=20)
    subprocess.run([str(p/'check')],check=True,timeout=5)
