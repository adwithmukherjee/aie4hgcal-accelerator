"""Compare qualified 64/128 lane emulations with identical pinned fixtures."""
import hashlib,json,sys
from pathlib import Path
b64,b128,out=map(Path,sys.argv[1:4]);builds=[b64,b128];reports=[]
for build,lanes in zip(builds,[64,128]):
 r=json.loads((build/'system/results/trace-validation.json').read_text())
 assert r['status']=='passed' and r['lanes']==lanes
 reports.append(r)
for filename in ['wire.mem','expected.mem','kan_lane.sv',*[f'rom_0_{i}.mem' for i in range(4)],*[f'rom_1_{i}.mem' for i in range(12)]]:
 assert hashlib.sha256((b64/'generated'/filename).read_bytes()).digest()==hashlib.sha256((b128/'generated'/filename).read_bytes()).digest(),filename
rows=[]
for r in reports:
 event=next(e for e in r['events'] if e['hits']==8000 and e['stall_cycles']==0)
 rows.append(dict(lanes=r['lanes'],hits=8000,cycles=event['final_cycles'],first_cycles=event['first_cycles'],latency_us=event['final_us'],first_us=event['first_us'],pl_hz=r['pl_hz']))
result=dict(measurement='VCK5000 PL hardware emulation; raw resident register release to final local embedding capture; excludes AIE transfer and host loading/readback',rows=rows,speedup_128_vs_64=rows[0]['latency_us']/rows[1]['latency_us'],physical_fit_or_timing_qualified=False)
out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
