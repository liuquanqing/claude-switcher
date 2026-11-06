#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/render-unified-controls.sh
python3 - "${1:-_qa/protection-interactions}" <<'PY'
import hashlib,json,subprocess,shutil,sys
from pathlib import Path
exe=Path('_qa/rc7/visual/ClaudeSwitcherUIFixture.app/Contents/MacOS/Renderer')
assert exe.exists()
base=[str(exe),'--demo','--demo-api','--fixture-cli-api','--fixture-protection-expanded']
scenarios={'idle':([],''),'passed':(['--fixture-diagnostic'],'-diagnostic'),'failed':(['--fixture-diagnostic','--demo-blocked'],'-diagnostic-blocked'),'draft':(['--fixture-draft'],'-draft'),'checking':(['--fixture-checking'],'-checking'),'paused':(['--fixture-paused'],'-paused'),'collapsed':(['--fixture-diagnostic','--fixture-results-collapsed'],'-diagnostic-results-collapsed')}
q=Path(sys.argv[1]);q.mkdir(parents=True,exist_ok=True)
for name,(args,suffix) in scenarios.items():
    with (q/(name+'-render.log')).open('w') as log:
        subprocess.run(base+args,stdout=log,stderr=subprocess.STDOUT,check=True)
    directory=Path('_qa/rc7-ui-revision/visual')/('api-expanded-cli-api'+suffix)
    for lang in ['zh','en']:
        shutil.copyfile(directory/('settings-'+lang+'.png'),q/(name+'-'+lang+'.png'))
def digest(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
(q/'render-manifest.json').write_text(json.dumps({'rendererSHA256':digest(exe),'sourceSHA256':{p:digest(p) for p in ['App/ProtectionView.swift','App/AppLocalization.swift','App/Views.swift']},'scenarios':list(scenarios),'languages':['zh','en'],'data':'fictional only','nativeClickAcceptance':'NOT_RUN'},indent=2)+'\n')
print('PASS: fresh renderer produced all 14 scenario screenshots')
PY
