"""Check all 2,560 distances and all 128 density contributions for every event."""
import json,struct,sys
from pathlib import Path
from reference import reference

data,output=map(Path,sys.argv[1:])
manifest=json.loads((data/'manifest.json').read_text())
payloads=(data/'payloads.bin').read_bytes()
words=[]
for line in output.read_text().splitlines():
    line=line.strip()
    if not line or line.startswith(('#','T ')) or line=='TLAST':continue
    words.extend(int(token,0)&0xffffffff for token in line.split())
actual=struct.pack('<%dI'%len(words),*words)
assert len(payloads)==1184*len(manifest['events'])
assert len(actual)==10368*len(manifest['events']),(len(actual),'output byte count')
for i,event in enumerate(manifest['events']):
    expected=reference(payloads[i*1184:(i+1)*1184])
    returned=actual[i*10368:(i+1)*10368]
    assert returned==expected,('Distance/density mismatch',event['sequence'],next(j for j,(a,b) in enumerate(zip(returned,expected)) if a!=b))
report=dict(status='passed',measurement='AIE functional simulation',radius_squared=645,
    events=[dict(sequence=e['sequence'],identity=e['identity'],exact_distances=2560,exact_density_counts=128) for e in manifest['events']])
(output.parent/'validation.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
