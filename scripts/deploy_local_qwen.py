#!/usr/bin/env python3
"""Install a built development App and the verified model on one explicit device."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import time
import uuid
from download_local_qwen import CACHE, ROOT, digest


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--on-device-download', action='store_true')
    parser.add_argument('--skip-install', action='store_true', help='Use only after this exact App was installed')
    parser.add_argument('--deployment-mirror', action='store_true', help='Debug-only download mirror; same pinned checksum')
    parser.add_argument('--agent-check', action='store_true', help='Check installed model with knowledge and public recipe tools; no cloud or writes')
    parser.add_argument('--agent-read-check', action='store_true', help='Only verify direct read adapters and offline policy, avoiding repeated model inference')
    parser.add_argument('--agent-knowledge-check', action='store_true', help='Verify offline knowledge retrieval and actual on-device answer, with no business network reads')
    parser.add_argument('--agent-stream-check', action='store_true', help='Check actual native incremental output with a bounded short prompt; not full Agent acceptance')
    parser.add_argument('--agent-quality-check', action='store_true', help='Collect fixed offline allergy, permission, safety and unknown-data answers for review')
    args=parser.parse_args()
    args.agent_check = args.agent_check or args.agent_read_check or args.agent_knowledge_check or args.agent_stream_check or args.agent_quality_check
    descriptor=json.loads((ROOT/'QiafanYoupu/Resources/AI/qwen-local-model.json').read_text())
    model=CACHE/descriptor['filename']
    if not args.app.is_dir(): raise ValueError('Built App not found')
    if not args.on_device_download and not args.agent_check and (not model.is_file() or model.stat().st_size != descriptor['bytes'] or digest(model) != descriptor['sha256']):
        raise ValueError('Run download_local_qwen.py and verify the model first')
    output=ROOT/'.build/qwen-deployment';output.mkdir(parents=True,exist_ok=True)
    run=str(uuid.uuid4())
    record={'runID':run,'pid':os.getpid(),'device':args.device,'startedAt':datetime.now(timezone.utc).isoformat(),
            'modelSHA256':descriptor['sha256'],'app':str(args.app),'completed':False}
    receipt=output/'deployment.json';receipt.write_text(json.dumps(record,indent=2)+'\n')
    def ctl(parts, timeout=90, capture=False):
        if parts[:3] == ['device', 'process', 'launch']:
            boundary = parts.index('com.talka.qiafanyoupu') + 1
            parts = parts[:boundary] + ['--'] + parts[boundary:]
        return subprocess.run(['xcrun','devicectl',*parts[:3],'--timeout',str(timeout),*parts[3:]],
            check=not capture, capture_output=capture, text=True, timeout=timeout+5)
    bundle='com.talka.qiafanyoupu'
    if not args.skip_install: ctl(['device','install','app','--device',args.device,str(args.app)],timeout=300)
    if not args.on_device_download and not args.agent_check:
        ctl(['device','process','launch','--device',args.device,'--terminate-existing',bundle,'-QFPrepareLocalModel'])
        time.sleep(2)
        ctl(['device','copy','to','--device',args.device,'--domain-type','appDataContainer',
             '--domain-identifier',bundle,'--source',str(model),
             '--destination','Library/Application Support/OnDeviceModels/'+descriptor['filename']],timeout=600)
    ctl(['device','process','launch','--device',args.device,'--terminate-existing',bundle,
         ('-QFVerifyAssistantQuality' if args.agent_quality_check else ('-QFVerifyAssistantStream' if args.agent_stream_check else ('-QFVerifyAssistantKnowledge' if args.agent_knowledge_check else ('-QFVerifyAssistantReads' if args.agent_read_check else '-QFVerifyAssistantTools')))) if args.agent_check else ('-QFDownloadAndVerifyLocalModel' if args.on_device_download else '-QFVerifyLocalModel'),'-QFCheckRun',run]
         + (['-QFDeploymentMirror'] if args.deployment_mirror else []))
    result=output/('qwen-agent-check.json' if args.agent_check else 'qwen-device-check.json')
    last_phase=None
    for _ in range(56):
        time.sleep(15)
        copied=ctl(['device','copy','from','--device',args.device,'--domain-type','appDataContainer',
            '--domain-identifier',bundle,'--source','Documents/'+('qwen-agent-check.json' if args.agent_check else 'qwen-deployment-check.json'),
            '--destination',str(result)],timeout=20,capture=True)
        if copied.returncode: continue
        check=json.loads(result.read_text())
        if check.get('runID') != run: continue
        if check.get('status') == 'IN_PROGRESS':
            phase=(check.get('phase'),int(check.get('downloadProgress',0)*10))
            if phase!=last_phase:
                print('Device phase:',phase[0],phase[1]*10,'%',flush=True);last_phase=phase
            continue
        record['deviceCheck']=check;record['completed']=True
        receipt.write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps(check,ensure_ascii=False,indent=2),flush=True)
        if check.get('status') != ('AGENT_CHECK_COMPLETED' if args.agent_check else 'INFERENCE_COMPLETED'): raise RuntimeError('Device check did not complete')
        return
    raise TimeoutError('No current device result; inspect device lock, cancellation or process exit')


if __name__=='__main__':main()
