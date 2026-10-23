#!/usr/bin/env python3
"""Check the exact bundled editorial knowledge variants, dates and source metadata."""
import hashlib
import json
from datetime import date
from pathlib import Path
from urllib.parse import urlparse

root = Path(__file__).resolve().parents[1]
bundle_path = root / 'QiafanYoupu/Resources/AI/assistant-knowledge.json'
bundle_bytes = bundle_path.read_bytes()
bundle = json.loads(bundle_bytes)
languages = {'zh-Hans', 'zh-Hant', 'en', 'ja', 'ko', 'ru', 'es', 'fr', 'de', 'pt-BR'}
assert bundle['schemaVersion'] == 1
seen = set()
for document in bundle['documents']:
    assert document['id'] not in seen
    seen.add(document['id'])
    assert document['revision'].startswith(document['reviewedAt'] + '.') and document['license']
    assert date.fromisoformat(document['reviewedAt']) <= date.fromisoformat(document['validUntil'])
    assert set(document['languages']) == languages
    if document['sourceURL']:
        url = urlparse(document['sourceURL'])
        assert url.scheme == 'https' and url.hostname and not url.username and not url.password
    assert document['destination'] in {None, 'recipes', 'plan', 'inventory', 'model_settings', 'memory'}
    for value in document['languages'].values():
        assert set(value) == {'title', 'keywords', 'body'}
        assert all(isinstance(text, str) and text.strip() and len(text.encode()) <= 2000 for text in value.values())

network = next(document for document in bundle['documents'] if document['id'] == 'guide-network')
assert network['sourceURL'] is None and network['destination'] == 'model_settings'
for language, value in network['languages'].items():
    for model in ('GLM', 'DeepSeek', 'Qwen'):
        assert model in value['body'] and model in value['keywords'], f'{language}: missing model policy for {model}'

# Keep standalone iOS checkouts usable; verify the packaged server copy whenever it is present.
project_root = root.parents[1]
server_root = project_root / '后端/qiafan-youpu-server'
if server_root.is_dir():
    server_bundle = server_root / 'src/main/resources/assistant/assistant-knowledge.json'
    manifest = json.loads(server_bundle.with_name('assistant-knowledge-manifest.json').read_text())
    assert server_bundle.read_bytes() == bundle_bytes, 'iOS and server knowledge bundles differ'
    assert manifest['schemaVersion'] == bundle['schemaVersion']
    assert manifest['source'] == bundle_path.relative_to(project_root).as_posix()
    assert manifest['sha256'] == hashlib.sha256(bundle_bytes).hexdigest(), 'Knowledge manifest SHA mismatch'
    assert manifest['revisions'] == sorted({document['revision'] for document in bundle['documents']})
    assert manifest['documents'] == len(seen)
    assert manifest['languageVariants'] == len(seen) * len(languages)
print(f'Validated {len(seen)} versioned knowledge documents / {len(seen) * len(languages)} language variants')
