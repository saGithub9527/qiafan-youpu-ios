#!/usr/bin/env python3
"""Run the bounded host check against the actual bundled knowledge and index."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='knowledge-check-',dir=root/'.build') as folder:
    tmp=Path(folder); binary=tmp/'check'
    paths=['QiafanYoupu/Features/Assistant/QFAssistantAgentContract.swift',
           'QiafanYoupu/Features/Assistant/QFAssistantKnowledge.swift',
           'scripts/tests/assistant_knowledge_check.swift']
    subprocess.run(['xcrun','swiftc','-j','1','-parse-as-library','-module-cache-path',str(tmp/'modules'),
                    *[str(root/path) for path in paths],'-o',str(binary)],check=True,timeout=90)
    subprocess.run([str(binary),str(root/'QiafanYoupu/Resources/AI/assistant-knowledge.json'),str(root/'scripts/tests/fixtures/assistant-reference-intent-v1.json')],check=True,timeout=30)
