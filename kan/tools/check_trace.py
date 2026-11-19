"""Independently verify event endpoints and every accepted vector from PL VCD."""
import hashlib,json,re,statistics,struct,sys
from pathlib import Path
build=Path(sys.argv[1]);results=build/'system/results'
host=json.loads((results/'events.json').read_text());lanes=host['lanes']
expected=[int(s,16) for s in (build/'generated/expected.mem').read_text().splitlines()]
names={};state={};observed=[];current=None

def sample(t,changes):
 global current
 old=state.copy();state.update(changes)
 if state.get('busy')==1 and old.get('busy')!=1:
  assert state['cycles']==0 and state['captured']==0 and state['complete']==0
  current=dict(release_ps=t,embeddings=[],groups=0);observed.append(current)
 if current is None:return
 assert state.get('fault')==0
 rising=state.get('ap_clk')==1 and old.get('ap_clk')!=1
 if rising and (state.get('busy')==1 or old.get('busy')==1):
  current['clock_edges']=current.get('clock_edges',0)+1
  current.setdefault('first_clock_ps',t);current['last_clock_ps']=t
  if old.get('out_valid')==1 and old.get('capture_ready')==0:
   assert state['out_valid']==1
   for name in ('embeddings','base_id','mask','out_last'):
    assert state[name]==old[name],('Output changed under backpressure',name)
 if state.get('accepted_groups',0)==old.get('accepted_groups',0)+1:
  assert old['accepted']==old['out_valid']==old['capture_ready']==1
  base=old['base_id'];mask=old['mask'];data=old['embeddings']
  assert base==len(current['embeddings'])
  assert isinstance(data,str)
  fill=data[0] if data[0] in 'xXzZ' else '0'
  bits=data.rjust(lanes*64,fill)
  values=[]
  for i in range(lanes):
   if (mask>>i)&1:
    word=bits[len(bits)-64*(i+1):len(bits)-64*i] if i else bits[-64:]
    assert not re.search('[xXzZ]',word),'Unknown bits in a valid embedding lane'
    values.append(int(word,2))
  assert mask==(1<<len(values))-1
  assert values==expected[base:base+len(values)]
  assert state['captured']==base+len(values)
  current['embeddings'].extend(values);current['groups']+=1
  current.setdefault('first_ps',t)
  if old['out_last']:
   assert state['complete']==1 and state['busy']==0
   current['finish_ps']=t;current['cycles']=state['cycles'];current['first_cycles']=state['first_cycles'];current['stall_cycles']=state['stall_cycles']
 if state.get('complete')==1:
  assert 'finish_ps' in current and state['cycles']==current['cycles']

path=results/'pl.vcd'
with path.open() as source:
 header=[]
 for line in source:
  header.append(line)
  if line.lstrip().startswith('$var'):
   f=line.split();names[f[3]]=f[4]
  if '$enddefinitions' in line:break
 unit=re.search(r'\$timescale\s+(\d+)\s*(fs|ps|ns|us|ms|s)',''.join(header));assert unit
 quantum=int(unit[1])*{'fs':.001,'ps':1,'ns':1000,'us':1e6,'ms':1e9,'s':1e12}[unit[2]]
 now=0;changes={}
 for line in source:
  line=line.strip()
  if line.startswith('#'):
   sample(now*quantum,changes);now=int(line[1:]);changes={}
  elif line and line[0] in 'bB':
   value,key=line[1:].split()
   if key in names:changes[names[key]]=value if names[key]=='embeddings' else (None if re.search('[xXzZ]',value) else int(value,2))
  elif line and line[0] in '01xXzZ' and line[1:] in names:
   changes[names[line[1:]]]=int(line[0]) if line[0] in '01' else None
 sample(now*quantum,changes)
assert len(observed)==len(host['events'])==4
for o in observed:
 assert o['clock_edges']==o['cycles']+1,'Timer differs from directly counted PL rising edges'
 assert o['first_clock_ps']==o['release_ps'] and o['last_clock_ps']==o['finish_ps']
period=statistics.median((o['last_clock_ps']-o['first_clock_ps'])/(o['clock_edges']-1) for o in observed)
assert abs(1e12/period/300e6-1)<.001,period
rows=[]
for o,h in zip(observed,host['events']):
 assert len(o['embeddings'])==h['hits'] and o['groups']==h['groups']
 assert o['cycles']==h['final_cycles'] and o['first_cycles']==h['first_cycles'] and o['stall_cycles']==h['stall_cycles']
 assert abs((o['first_ps']-o['release_ps'])/period-h['first_cycles'])<.01
 assert (results/f'embeddings-{h["trial"]}.bin').read_bytes()==struct.pack('<%dQ'%h['hits'],*o['embeddings'])
 rows.append(dict(**h,first_us=(o['first_ps']-o['release_ps'])/1e6,final_us=(o['finish_ps']-o['release_ps'])/1e6))
report=dict(status='passed',measurement='VCK5000 integrated PL hardware emulation; not physical board timing',lanes=lanes,pl_hz=1e12/period,events=rows,direct_clock_edge_check=True,stalled_payload_stability_check=True,trace_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
(results/'trace-validation.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
