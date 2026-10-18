#!/usr/bin/env python3
"""Verify the locked, selected official SDK payload without fetching/installing."""
import hashlib
import json
from pathlib import Path

package = Path(__file__).resolve().parents[1] / "Packages" / "QFFilament"
lock = json.loads((package / "filament.lock.json").read_text())
for item in lock["files"]:
    path = package / item["path"]
    if not path.is_file():
        raise SystemExit(f"Missing SDK file: {item['path']}")
    data = path.read_bytes()
    if len(data) != item["bytes"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
        raise SystemExit(f"SDK payload differs from the verified archive: {item['path']}")
print(f"Filament {lock['version']}: {len(lock['files'])} locked binary payload files verified")
