#!/usr/bin/env python3
"""Rebuild the offline orb after editing its authored source, never during App launch."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Packages/QFOrbRenderer"
parser = argparse.ArgumentParser()
parser.add_argument("--esbuild", required=True, help="Path to verified esbuild 0.28.2 CLI")
args = parser.parse_args()
version = subprocess.check_output([args.esbuild, "--version"], text=True, timeout=10).strip()
if version != "0.28.2":
    raise SystemExit(f"Expected esbuild 0.28.2, found {version}")
subprocess.run([
    args.esbuild, str(PACKAGE / "WebSource/orb.js"), "--bundle", "--format=iife",
    "--platform=browser", "--target=safari15", "--minify", "--legal-comments=eof",
    "--metafile=" + str(PACKAGE / "WebSource/bundle-manifest.json"),
    "--outfile=" + str(PACKAGE / "Sources/QFOrbRenderer/Web/orb.bundle.js"),
], check=True, timeout=60, env={**os.environ, "GOMAXPROCS": "2"})
manifest_path = PACKAGE / "runtime-manifest.json"
manifest = json.loads(manifest_path.read_text())
runtime = PACKAGE / "Sources/QFOrbRenderer/Web"
manifest["files"] = {
    p.name: {"bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
    for p in runtime.iterdir()
}
manifest["runtimeBytes"] = sum(p.stat().st_size for p in runtime.iterdir())
manifest["sourceSHA256"] = hashlib.sha256((PACKAGE / "WebSource/orb.js").read_bytes()).hexdigest()
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
print(f"Offline runtime: {manifest['runtimeBytes']} bytes")
