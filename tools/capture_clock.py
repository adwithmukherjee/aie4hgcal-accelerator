"""Preserve generated AIE clock evidence; Vitis duplicates the linked model."""
import hashlib,json,re,shutil,sys
from pathlib import Path
build=Path(sys.argv[1])
records=[]
for path in sorted((build/'system/link').rglob('ai_engine.cpp')):
    match=re.search(r'me_core_clk\("me_core_clk",\s*1\.0/(\d+(?:\.\d+)?),\s*SC_US\)',path.read_text())
    assert match,('Cannot determine generated AIE clock',str(path))
    records.append(dict(path=str(path),aie_hz=float(match[1])*1e6,sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
assert records,'No generated AIE model'
assert len({row['aie_hz'] for row in records})==1,'Generated models disagree on AIE clock'
linked=[row for row in records if '/prj.gen/sources_1/bd/design_1/' in row['path'] and '/.local/' not in row['path']]
assert len(linked)==1,('Cannot identify linked design model',linked)
shutil.copy2(linked[0]['path'],build/'system/ai_engine.cpp')
report=dict(aie_hz=linked[0]['aie_hz'],selected_model=linked[0]['path'],generated_models=records)
(build/'system/clock_evidence.json').write_text(json.dumps(report,indent=2)+'\n')
print('Saved clock evidence:',len(records),'generated copies agree on',linked[0]['aie_hz'],'Hz')
