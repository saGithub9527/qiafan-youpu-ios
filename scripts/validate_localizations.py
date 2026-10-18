#!/usr/bin/env python3
"""Validate the device-local UI language catalog against Swift source strings."""

from __future__ import annotations

import argparse
import ast
import json
import re
import sys
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "QiafanYoupu"
RESOURCE_ROOT = SOURCE_ROOT / "Resources" / "Localization"
SOURCE_MANIFEST = ROOT / "docs" / "localization-source.json"
LOCALES = ("zh-Hant", "ja", "ko", "ru", "es", "fr", "de", "pt-BR")

SWIFT_STRING = r'"((?:\\.|[^"\\])*)"'
CALL_PATTERN = re.compile(
    rf"(?:(?:app|language)\.(?:text|format)|"
    rf"(?<![.A-Za-z0-9_])(?:text|format))\(\s*(?:chinese:\s*)?{SWIFT_STRING}"
    rf"\s*,\s*(?:english:\s*)?{SWIFT_STRING}",
    re.DOTALL,
)
PAIR_PATTERN = re.compile(rf"{SWIFT_STRING}\s*:\s*{SWIFT_STRING}")
PLAN_PAIR_PATTERN = re.compile(
    rf"chinese(?:Title|Detail):\s*{SWIFT_STRING}\s*,\s*english(?:Title|Detail):\s*{SWIFT_STRING}"
)
ENTRY_PATTERN = re.compile(rf"\s*{SWIFT_STRING}\s*=\s*{SWIFT_STRING}\s*;", re.DOTALL)
FORMAT_PATTERN = re.compile(
    r"%(?:(\d+)\$)?[-+0 #']*\d*(?:\.\d+)?(?:hh|h|ll|l|L|z|j|t|q)?([@diuoxXfFeEgGaAcCsSp])"
)


def decode_swift_string(raw: str) -> str:
    try:
        return ast.literal_eval(f'"{raw}"')
    except (SyntaxError, ValueError) as error:
        raise ValueError(f"Unsupported Swift string literal: {raw!r}") from error


def collect_source_pairs() -> dict[str, set[str]]:
    pairs: dict[str, set[str]] = defaultdict(set)
    for path in SOURCE_ROOT.rglob("*.swift"):
        source = path.read_text(encoding="utf-8")
        for match in CALL_PATTERN.finditer(source):
            pairs[decode_swift_string(match.group(1))].add(decode_swift_string(match.group(2)))

        if path.name == "QFIngredientView.swift":
            marker = "private static let english: [String: String] = ["
            start = source.find(marker)
            end = source.find("\n  ]", start)
            if start >= 0 and end > start:
                for match in PAIR_PATTERN.finditer(source[start:end]):
                    pairs[decode_swift_string(match.group(1))].add(
                        decode_swift_string(match.group(2))
                    )

        if path.name == "QFPlanView.swift":
            for match in PLAN_PAIR_PATTERN.finditer(source):
                pairs[decode_swift_string(match.group(1))].add(
                    decode_swift_string(match.group(2))
                )

    return dict(sorted(pairs.items()))


def write_source_manifest(pairs: dict[str, set[str]]) -> None:
    SOURCE_MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "sourceLanguage": "zh-Hans",
        "developmentLanguage": "en",
        "requiredLocalizations": list(LOCALES),
        "strings": {
            key: {"english": sorted(values)[0], "englishVariants": sorted(values)}
            for key, values in pairs.items()
        },
    }
    SOURCE_MANIFEST.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def read_strings(path: Path) -> dict[str, str]:
    source = path.read_text(encoding="utf-8")
    result: dict[str, str] = {}
    cursor = 0
    for match in ENTRY_PATTERN.finditer(source):
        between = source[cursor : match.start()]
        if between.strip() and not all(
            part.strip().startswith("//") for part in between.splitlines() if part.strip()
        ):
            raise ValueError(f"Unparsed content near byte {cursor}")
        key = decode_swift_string(match.group(1))
        value = decode_swift_string(match.group(2))
        if key in result:
            raise ValueError(f"Duplicate key: {key}")
        result[key] = value
        cursor = match.end()
    if source[cursor:].strip():
        raise ValueError(f"Unparsed content near byte {cursor}")
    return result


def format_signature(value: str) -> list[str]:
    without_literal_percent = value.replace("%%", "")
    return sorted(match.group(2) for match in FORMAT_PATTERN.finditer(without_literal_percent))


def validate(pairs: dict[str, set[str]]) -> list[str]:
    errors: list[str] = []
    expected = set(pairs)
    for locale in LOCALES:
        path = RESOURCE_ROOT / f"{locale}.lproj" / "Localizable.strings"
        if not path.is_file():
            errors.append(f"{locale}: missing {path.relative_to(ROOT)}")
            continue
        try:
            values = read_strings(path)
        except ValueError as error:
            errors.append(f"{locale}: {error}")
            continue
        missing = sorted(expected - values.keys())
        extra = sorted(values.keys() - expected)
        empty = sorted(key for key, value in values.items() if not value.strip())
        for key in missing:
            errors.append(f"{locale}: missing key {key!r}")
        for key in extra:
            errors.append(f"{locale}: unknown key {key!r}")
        for key in empty:
            errors.append(f"{locale}: empty translation for {key!r}")
        for key in sorted(expected & values.keys()):
            source_signature = format_signature(key)
            target_signature = format_signature(values[key])
            if source_signature != target_signature:
                errors.append(
                    f"{locale}: format arguments differ for {key!r}: "
                    f"{source_signature} != {target_signature}"
                )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--write-source", action="store_true", help="rewrite the extracted source manifest"
    )
    args = parser.parse_args()
    pairs = collect_source_pairs()
    if args.write_source:
        write_source_manifest(pairs)
        print(f"Wrote {len(pairs)} source strings to {SOURCE_MANIFEST.relative_to(ROOT)}")
    errors = validate(pairs)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Validated {len(pairs)} strings across {len(LOCALES)} localizations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
