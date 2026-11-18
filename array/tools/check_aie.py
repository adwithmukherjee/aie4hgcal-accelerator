"""Compare each column's native output with exact integer CPU calculations."""
import argparse,json,struct,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
from reference import reference
p=argparse.ArgumentParser();p.add_argument('data',type=Path);p.add_argument('output',type=Path);p.add_argument('config',type=Path)
p.add_argument('--events',type=int,default=2);p.add_argument('--gated',action='store_true');a=p.parse_args()
mapping=json.loads(a.config.read_text());frames=(a.data/'payloads.bin').read_bytes()
events=1 if a.gated else a.events
assert 0<events<=len(frames)//6144
packets=0
for lane in mapping['lanes']:
 c=lane['index'];rows={v:r for r,v in enumerate(lane['output_ids'])}
 progress=[[0,0] for _ in range(8)];packet=[];last=False;keep=None
 for line in (a.output/f'output-{c}.txt').read_text().splitlines():
  line=line.strip()
  if not line or line.startswith(('#','T ')):continue
  if line.startswith('TLAST'):last=True;continue
  if line.startswith('TKEEP'):keep=int(line.split()[1],0);continue
  words=[int(x,0)&0xffffffff for x in line.split()]
  if keep is not None:words=words[:sum((keep>>(4*i))&15==15 for i in range(4))]
  packet.extend(words);keep=None
  kind=(packet[0]>>12)&7;assert kind in (0,1)
  size=33 if kind==0 else 2561
  assert len(packet)<=size
  if last:assert len(packet)==size
  if len(packet)<size:continue
  assert len(words)==1
  row=rows[packet[0]&31];event,expected_kind=progress[row]
  assert kind==expected_kind and event<events,(c,row,event,kind)
  if a.gated:assert kind==0,('Matrix output without readback request',c,row)
  frame=frames[event*6144:(event+1)*6144]
  expected=reference(frame[(c*8+row)*160:(c*8+row+1)*160]+frame[5120:])
  assert struct.pack('<%dI'%(size-1),*packet[1:])==(expected[:128] if kind==0 else expected[128:]),(c,row,event,kind)
  progress[row]=[event,1] if kind==0 else [event+1,0]
  packets+=1;packet=[];last=False
 target=[0,1] if a.gated else [events,0]
 assert not packet and all(x==target for x in progress),(c,progress)
report=dict(status='passed',measurement='AIE functional simulation',columns=mapping['columns'],events=events,
            packets=packets,exact_distances=0 if a.gated else mapping['columns']*8*2560*events,
            exact_density_counts=mapping['columns']*8*128*events,readback_requests_withheld=a.gated)
(a.output/'validation.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
