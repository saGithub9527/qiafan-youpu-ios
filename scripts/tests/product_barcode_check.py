#!/usr/bin/env python3
"""Compile the real Foundation barcode validator; no camera, network or Xcode build.

Regression targets: wrong GTIN parity, Unicode digit acceptance, false UPC-E
expansion, restricted codes leaking into lookup, URL payloads, and forged drafts.
UPC-E literal fixtures follow GS1 General Specifications 5.2.2.4.1; in particular
01234558 expands to the published GS1 example 012345000058.
"""
from pathlib import Path
import os
import signal
import subprocess
import tempfile
import time


root = Path(__file__).resolve().parents[2]
source = root / "QiafanYoupu/Features/Ingredient/QFProductBarcode.swift"
assert source.is_file(), "RED: the real product-barcode validator is not implemented"
deadline = time.monotonic() + 19  # Leave one second for task-owned process cleanup.


def run(command):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise subprocess.TimeoutExpired(command, 19)
    process = subprocess.Popen(command, start_new_session=True)
    try:
        return_code = process.wait(timeout=remaining)
    except BaseException:
        if process.poll() is None and os.getpgid(process.pid) == process.pid:
            # This fresh session belongs only to this command, including swift-frontend.
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=1)
        raise
    if return_code:
        raise subprocess.CalledProcessError(return_code, command)


with tempfile.TemporaryDirectory(prefix="qf-product-barcode-") as directory:
    temporary = Path(directory)
    main = temporary / "Check.swift"
    main.write_text(r'''import Foundation
@main enum Check {
  static var count = 0
  static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    count += 1
    if !condition() {
      fputs("FAIL: \(message)\n", stderr)
      exit(1)
    }
  }
  static func main() throws {
    for (value, kind, expected) in [
      ("4006381333931", "EAN13", "4006381333931"),
      ("0123456789012", "EAN13", "0123456789012"),
      ("96385074", "EAN8", "96385074"),
      ("00012348", "EAN8", "00012348"),
      ("01234505", "UPCE", "0012000003455"),
      ("01234514", "UPCE", "0012100003454"),
      ("01234523", "UPCE", "0012200003453"),
      ("01234531", "UPCE", "0012300000451"),
      ("01234543", "UPCE", "0012340000053"),
      ("01234558", "UPCE", "0012345000058"),
      ("01234565", "UPCE", "0012345000065"),
      ("01234572", "UPCE", "0012345000072"),
      ("01234589", "UPCE", "0012345000089"),
      ("01234596", "UPCE", "0012345000096"),
      ("04252614", "UPCE", "0042100005264"),
    ] {
      let result = QFProductBarcode(value: value, symbology: kind)
      check(result?.value == value && result?.symbology == kind, "preserve \(kind) \(value)")
      check(result?.lookupCode == expected, "correct lookup/UPC-E expansion \(value)")
    }
    for (value, kind) in [
      ("4006381333932", "EAN13"), ("96385075", "EAN8"),
      ("400638133393", "EAN13"), ("963850740", "EAN8"),
      (" 4006381333931", "EAN13"), ("96385074\n", "EAN8"),
      ("４００６３８１３３３９３１", "EAN13"), ("٩٦٣٨٥٠٧٤", "EAN8"),
      ("0000000000000", "EAN13"), ("00000000", "EAN8"),
      ("01234559", "UPCE"), ("123455", "UPCE"), ("0123455", "UPCE"),
      ("11234555", "UPCE"), ("01204534", "UPCE"),
      ("01230545", "UPCE"), ("01234053", "UPCE"),
      ("4006381333931", "QR"), ("4006381333931", "ean13"),
      ("", "CODE128"), ("   ", "CODE128"),
      ("https://example.com/sku", "CODE128"), ("HTTP://example.com", "CODE128"),
      ("www.example.com", "CODE128"), ("//example.com", "CODE128"),
      ("file:/tmp/sku", "CODE128"), ("javascript:alert(1)", "CODE128"),
      ("SKU\n123", "CODE128"), ("SKU\u{001B}123", "CODE128"),
      ("SKU\u{007F}", "CODE128"), ("SKU\u{200B}123", "CODE128"),
      ("SKU\\123", "CODE128"), ("<script>", "CODE128"),
      (String(repeating: "A", count: 81), "CODE128"),
    ] {
      check(QFProductBarcode(value: value, symbology: kind) == nil, "reject unsafe/invalid \(kind): \(value.debugDescription)")
    }
    for (value, kind) in [
      ("2001234567893", "EAN13"), ("2901234567896", "EAN13"),
      ("20123451", "EAN8"), ("0212345678909", "EAN13"),
      ("0021234567893", "EAN13"),
    ] {
      let restricted = QFProductBarcode(value: value, symbology: kind)
      check(restricted?.value == value, "retain restricted code for manual entry")
      check(restricted?.lookupCode == nil, "restricted code must never reach public lookup")
    }
    for value in ["SKU-2026/001_A", "LOT 123.45", "4006381333931", String(repeating: "A", count: 80)] {
      let identifier = QFProductBarcode(value: value, symbology: "CODE128")
      check(identifier?.value == value, "retain safe Code128 identifier")
      check(identifier?.lookupCode == nil, "Code128 is never guessed to be a GTIN")
    }
    let original = QFProductBarcode(value: "01234558", symbology: "UPCE")!
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(QFProductBarcode.self, from: encoded)
    check(decoded == original, "validated draft round trip")
    let forged = Data(#"{"value":"2001234567893","symbology":"EAN13","lookupCode":"4006381333931"}"#.utf8)
    let forgedDecoded = try JSONDecoder().decode(QFProductBarcode.self, from: forged)
    check(forgedDecoded.lookupCode == nil,
          "decode must recompute lookup eligibility rather than trust persisted lookupCode")
    let invalid = Data(#"{"value":"4006381333932","symbology":"EAN13"}"#.utf8)
    do {
      _ = try JSONDecoder().decode(QFProductBarcode.self, from: invalid)
      check(false, "invalid persisted barcode must fail decoding")
    } catch DecodingError.dataCorrupted { check(true, "invalid draft rejected") }
    print("PASS: \(count) barcode assertions; GTIN/UPC-E, no-lookup boundaries, safe Code128 and Codable")
  }
}
''')
    binary = temporary / "check"
    run(["xcrun", "swiftc", "-parse-as-library", str(source), str(main), "-o", str(binary)])
    run([str(binary)])
