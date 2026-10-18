#!/usr/bin/env python3
"""Small, deterministic design RAG for the Qiafan Youpu workspace."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
INDEX = HERE / "page-baselines.json"


def load_index() -> dict:
    return json.loads(INDEX.read_text(encoding="utf-8"))


def page_by_id(data: dict, page_id: str) -> dict:
    for page in data["pages"]:
        if page["id"] == page_id:
            return page
    raise SystemExit(f"Unknown baseline: {page_id}")


def source_root(data: dict) -> Path:
    return (HERE / data["sourceRoot"]).resolve()


def search(data: dict, query: str) -> int:
    terms = [part.casefold() for part in re.split(r"\s+", query.strip()) if part]
    ranked = []
    for page in data["pages"]:
        haystack = json.dumps(page, ensure_ascii=False).casefold()
        score = sum(haystack.count(term) for term in terms)
        if not terms or score:
            ranked.append((score, page))
    for score, page in sorted(ranked, key=lambda item: (-item[0], item[1]["id"])):
        print(f"{page['id']}\t{page['title']}\tscore={score}")
        print("  sources:")
        for source in page["sources"]:
            print(f"    - {source['path']}  sha256={source['sha256']}")
        print("  fixed:", json.dumps(page["layoutContract"], ensure_ascii=False))
        print("  interaction:")
        for rule in page["interactionContract"]:
            print(f"    - {rule}")
    return 0 if ranked else 1


def verify(data: dict, page_id: str) -> int:
    page = page_by_id(data, page_id)
    failures = []
    root = source_root(data)
    for source in page["sources"]:
        path = root / source["path"]
        if not path.is_file():
            failures.append(f"missing source: {path}")
            continue
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != source["sha256"]:
            failures.append(f"source drift: {source['path']} expected={source['sha256']} actual={actual}")

    contract = page.get("codeContract")
    if contract:
        code_path = (HERE / contract["file"]).resolve()
        if not code_path.is_file():
            failures.append(f"missing code contract file: {code_path}")
        else:
            code = code_path.read_text(encoding="utf-8")
            for name, expected in contract["constants"].items():
                match = re.search(
                    rf"static\s+let\s+{re.escape(name)}\s*:\s*CGFloat\s*=\s*([0-9]+(?:\.[0-9]+)?)",
                    code,
                )
                if not match:
                    failures.append(f"missing CGFloat constant: {name}")
                elif float(match.group(1)) != float(expected):
                    failures.append(f"constant drift: {name} expected={expected} actual={match.group(1)}")

    if failures:
        print(f"FAIL {page_id}")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print(f"OK {page_id}: source hashes and code constants match")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    search_parser = sub.add_parser("search", help="retrieve relevant page contracts")
    search_parser.add_argument("query")
    baseline_parser = sub.add_parser("baseline", help="print one complete page contract")
    baseline_parser.add_argument("page_id")
    verify_parser = sub.add_parser("verify", help="verify sources and code constants")
    verify_parser.add_argument("page_id")
    args = parser.parse_args()
    data = load_index()
    if args.command == "search":
        return search(data, args.query)
    if args.command == "baseline":
        print(json.dumps(page_by_id(data, args.page_id), ensure_ascii=False, indent=2))
        return 0
    return verify(data, args.page_id)


if __name__ == "__main__":
    sys.exit(main())
