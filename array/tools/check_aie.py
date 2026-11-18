"""Check each tile's density and nearest-seed labels independently of cache layout."""
import argparse,json,struct
from pathlib import Path
from clustering_reference import reference,squared
from assignment_cases import assignment_case
p=argparse.ArgumentParser();p.add_argument('data',type=Path);p.add_argument('output',type=Path);p.add_argument('config',type=Path)
p.add_argument('--events',type=int,default=2);p.add_argument('--gated',action='store_true')
p.add_argument('--assignment-count',type=int,default=0);p.add_argument('--ties-last',action='store_true')
p.add_argument('--assignment-cases',action='store_true');p.add_argument('--force-64',action='store_true');a=p.parse_args()
mapping=json.loads(a.config.read_text());frames=(a.data/'payloads.bin').read_bytes();manifest=json.loads((a.data/'manifest.json').read_text())
events=1 if a.gated else a.events;packets=0
refs=[reference(frames[e*6144:(e+1)*6144],manifest['events'][e]['landmark_ids'],a.force_64) for e in range(events)]
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
  kind=(packet[0]>>12)&7;assert kind in (0,2)
  size=33 if kind==0 else 6
  assert len(packet)<=size
  if last:assert len(packet)==size
  if len(packet)<size:continue
  row=rows[packet[0]&31];event,expected_kind=progress[row]
  assert kind==expected_kind and event<events,(c,row,event,kind)
  if a.gated:assert kind==0,('Labels emitted without seeds',c,row)
  frame=struct.unpack('6144b',frames[event*6144:(event+1)*6144])
  if a.ties_last and event==events-1:frame=(0,)*6144
  if a.assignment_cases:frame=struct.unpack('6144b',assignment_case(event)[0])
  lm=[frame[i:i+8] for i in range(5120,6144,8)]
  hits=[frame[i:i+8] for i in range((c*8+row)*160,(c*8+row+1)*160,8)]
  if kind==0:expected=bytes(sum(squared(h,r)<=645 for h in hits) for r in lm)
  else:
   seeds=refs[event]['seed_slots'] if not a.assignment_count else [(127-i*3)%128 for i in range(a.assignment_count)]
   if a.assignment_cases:seeds=assignment_case(event)[1]
   expected=bytes(min(range(len(seeds)),key=lambda s:squared(h,lm[seeds[s]])) for h in hits)
  assert struct.pack('<%dI'%(size-1),*packet[1:])==expected,(c,row,event,kind)
  progress[row]=[event,2] if kind==0 else [event+1,0]
  packets+=1;packet=[];last=False
 target=[0,2] if a.gated else [events,0]
 assert not packet and all(x==target for x in progress),(c,progress)
report=dict(status='passed',measurement='native AIE simulation',columns=4,events=events,packets=packets,
 exact_density_counts=32*128*events,exact_labels=0 if a.gated else 640*events,
 seed_requests_withheld=a.gated,assignment_count_override=a.assignment_count,synthetic_tie_event=a.ties_last,
 adversarial_shortlist_cases=a.assignment_cases,forced_64_reference=a.force_64)
(a.output/'validation.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
