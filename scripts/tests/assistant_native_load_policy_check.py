#!/usr/bin/env python3
"""Bounded host check of the production pure load selector; no model or device."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = Path(__file__).with_suffix(".cpp")
include = root / "Packages/QFLocalLLM/Sources/QFLocalLLM"
with tempfile.TemporaryDirectory(prefix="native-load-policy-", dir=root / ".build") as folder:
    binary = Path(folder) / "check"
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-Wall", "-Wextra", "-pedantic",
                    "-I", str(include), str(source), "-o", str(binary)],
                   check=True, timeout=15)
    subprocess.run([str(binary)], check=True, timeout=2)
