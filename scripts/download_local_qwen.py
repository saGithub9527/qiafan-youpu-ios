#!/usr/bin/env python3
"""Fetch the fixed, licensed model outside the App bundle and verify every byte."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / '.build/local-models'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): value.update(block)
    return value.hexdigest()


def main():
    model = json.loads((ROOT/'QiafanYoupu/Resources/AI/qwen-local-model.json').read_text())
    CACHE.mkdir(parents=True, exist_ok=True)
    final = CACHE / model['filename']
    part = final.with_suffix('.gguf.part')
    owner = CACHE / 'download-owner.json'
    metadata = {'pid':os.getpid(),'startedAt':datetime.now(timezone.utc).isoformat(),
                'command':'scripts/download_local_qwen.py','partialFile':str(part),'released':False}
    owner.write_text(json.dumps(metadata,indent=2)+'\n')
    try:
        if final.exists():
            if final.stat().st_size != model['bytes'] or digest(final) != model['sha256']:
                raise ValueError('Existing model cache does not match the pinned model')
            print('Verified cached model:',final,flush=True); return
        if shutil.disk_usage(CACHE).free < model['bytes'] * 2: raise ValueError('Insufficient free space')
        if not part.exists() or part.stat().st_size != model['bytes']:
            subprocess.run(['/usr/bin/curl','--fail','--location','--silent','--show-error',
                '--continue-at','-','--connect-timeout','20','--max-time','3600',
                '--speed-limit','4096','--speed-time','60','--retry','1','--retry-delay','10',
                '--output',str(part),model['url']],check=True,timeout=3670)
        if part.stat().st_size != model['bytes'] or digest(part) != model['sha256']:
            raise ValueError('Downloaded model size or SHA256 mismatch; it is not installable')
        part.rename(final)
        (CACHE/'verified.json').write_text(json.dumps(model,ensure_ascii=False,indent=2)+'\n')
        print('Verified model:',final,flush=True)
    finally:
        metadata['released']=True
        owner.write_text(json.dumps(metadata,indent=2)+'\n')


if __name__=='__main__': main()
