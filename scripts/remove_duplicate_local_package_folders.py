#!/usr/bin/env python3
"""Keep local SwiftPM dependencies without XcodeGen's duplicate Folder containers.

Xcode 26.3 cannot open one directory as both a Folder and a Swift Package
Dependency. Run after XcodeGen; only the navigator's duplicate folder references
are removed. Package references, products and build phases remain unchanged.
"""
import argparse
import copy
import json
from pathlib import Path
import re
import subprocess
import tempfile
import os

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "QiafanYoupu.xcodeproj/project.pbxproj"
PACKAGE_PATHS = {"Packages/QFFilament", "Packages/QFOrbRenderer", "Packages/QFLocalLLM", "Packages/QFSSE"}


def parse_project(data):
    result = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", "--", "-"],
        input=data, capture_output=True, check=True, timeout=10,
    )
    return json.loads(result.stdout)


def contains_reference(value, reference):
    if isinstance(value, dict):
        return any(contains_reference(item, reference) for item in value.values())
    if isinstance(value, list):
        return any(contains_reference(item, reference) for item in value)
    return value == reference


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check without writing")
    args = parser.parse_args()
    original = PROJECT.read_bytes()
    before = parse_project(original)
    objects = before["objects"]
    project = objects[before["rootObject"]]
    for path in PACKAGE_PATHS:
        refs = [key for key, obj in objects.items()
                if obj.get("isa") == "XCLocalSwiftPackageReference"
                and obj.get("relativePath") == path]
        if len(refs) != 1 or refs[0] not in project.get("packageReferences", []):
            raise ValueError(f"Expected one registered SwiftPM dependency: {path}")
        if not (ROOT / path / "Package.swift").is_file():
            raise ValueError(f"Missing package manifest: {path}")
    duplicates = {key: obj["path"] for key, obj in objects.items()
                  if obj.get("isa") == "PBXFileReference"
                  and obj.get("lastKnownFileType") == "folder"
                  and obj.get("sourceTree") == "SOURCE_ROOT"
                  and obj.get("path") in PACKAGE_PATHS}
    if args.check:
        if duplicates:
            raise ValueError("Duplicate local package folders: "
                             + ", ".join(sorted(duplicates.values())))
        print("Local package references OK; no duplicate Folder containers")
        return
    if not duplicates:
        print("Local package references already fixed")
        return
    expected = copy.deepcopy(before)
    patched = original.decode("utf-8")
    for reference in duplicates:
        del expected["objects"][reference]
        child_count = 0
        for obj in expected["objects"].values():
            if obj.get("isa") == "PBXGroup" and reference in obj.get("children", []):
                child_count += obj["children"].count(reference)
                obj["children"] = [child for child in obj["children"] if child != reference]
            if contains_reference(obj, reference):
                raise ValueError(f"Folder {reference} is used outside navigator children")
        if contains_reference(expected, reference):
            raise ValueError(f"Unexpected reference to Folder {reference}")
        patched, definitions = re.subn(
            rf"(?m)^[ \t]*{reference}(?: /\*[^\n]*?\*/)? = \{{[^}}]*\}};\n",
            "", patched,
        )
        patched, children = re.subn(
            rf"(?m)^[ \t]*{reference}(?: /\*[^\n]*?\*/)?,\n", "", patched,
        )
        if definitions != 1 or children != child_count:
            raise ValueError(f"Unexpected pbxproj representation for {reference}")
    data = patched.encode("utf-8")
    if parse_project(data) != expected:
        raise ValueError("Project graph changed beyond duplicate navigator folders")
    if PROJECT.read_bytes() != original:
        raise ValueError("Project changed during repair; close Xcode and retry")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=PROJECT.parent, prefix=".local-package-", delete=False) as output:
            temporary = Path(output.name)
            output.write(data)
        temporary.chmod(PROJECT.stat().st_mode & 0o777)
        if PROJECT.read_bytes() != original:
            raise ValueError("Project changed during repair; close Xcode and retry")
        os.replace(temporary, PROJECT)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print("Removed duplicate navigator folders: " + ", ".join(sorted(duplicates.values())))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
