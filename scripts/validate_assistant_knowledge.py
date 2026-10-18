#!/usr/bin/env python3
"""Check the exact bundled editorial knowledge variants, dates and source metadata."""
import json
from datetime import date
from pathlib import Path
from urllib.parse import urlparse

root = Path(__file__).resolve().parents[1]
bundle = json.loads((root / 'QiafanYoupu/Resources/AI/assistant-knowledge.json').read_text())
languages = {'zh-Hans', 'zh-Hant', 'en', 'ja', 'ko', 'ru', 'es', 'fr', 'de', 'pt-BR'}
assert bundle['schemaVersion'] == 1
seen = set()
for document in bundle['documents']:
    assert document['id'] not in seen
    seen.add(document['id'])
    assert document['revision'] and document['license']
    assert date.fromisoformat(document['reviewedAt']) <= date.fromisoformat(document['validUntil'])
    assert set(document['languages']) == languages
    if document['sourceURL']:
        url = urlparse(document['sourceURL'])
        assert url.scheme == 'https' and url.hostname and not url.username and not url.password
    assert document['destination'] in {None, 'recipes', 'plan', 'inventory', 'model_settings', 'memory'}
    for value in document['languages'].values():
        assert set(value) == {'title', 'keywords', 'body'}
        assert all(isinstance(text, str) and text.strip() and len(text.encode()) <= 2000 for text in value.values())
print(f'Validated {len(seen)} versioned knowledge documents / {len(seen) * len(languages)} language variants')
