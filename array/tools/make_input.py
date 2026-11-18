"""Native-simulator packets; real clustering decisions come from the CPU oracle."""
import argparse,json,struct
from pathlib import Path
from clustering_reference import reference
from assignment_cases import assignment_case
p=argparse.ArgumentParser();p.add_argument('data',type=Path);p.add_argument('build',type=Path)
p.add_argument('--events',type=int,default=2);p.add_argument('--gated',action='store_true')
p.add_argument('--assignment-count',type=int,default=0);p.add_argument('--ties-last',action='store_true')
p.add_argument('--assignment-cases',action='store_true');p.add_argument('--force-64',action='store_true');a=p.parse_args()
mapping=json.loads((a.build/'config/packet_map.json').read_text())
manifest=json.loads((a.data/'manifest.json').read_text());frames=(a.data/'payloads.bin').read_bytes()
events=1 if a.gated else a.events;assert 0<events<=len(frames)//6144
assert 0<=a.assignment_count<=64
def packet(out,header,payload=b''):
 words=[header,*struct.unpack('<%dI'%(len(payload)//4),payload)]
 for offset in range(0,len(words),4):
  if offset+4>=len(words):out.write('TLAST\n')
  out.write(' '.join(str(x) for x in words[offset:offset+4])+'\n')
for lane in mapping['lanes']:
 c=lane['index'];headers=lane['route_headers']
 with (a.build/f'aie/input-{c}.txt').open('w') as out:
  for event in range(events):
   frame=frames[event*6144:(event+1)*6144]
   if a.ties_last and event==events-1:frame=bytes(6144)
   if a.assignment_cases:frame,_=assignment_case(event)
   packet(out,headers[8],frame[5120:])
   for row in range(8):packet(out,headers[row],frame[c*1280+row*160:c*1280+(row+1)*160])
   if not a.gated:
    seeds=reference(frame,manifest['events'][event]['landmark_ids'],a.force_64)['seed_slots']
    if a.assignment_count:seeds=[(127-i*3)%128 for i in range(a.assignment_count)]
    if a.assignment_cases:_,seeds=assignment_case(event)
    payload=struct.pack('<I',len(seeds))+bytes(seeds+[0]*((-len(seeds))%4))
    packet(out,headers[9],payload)
