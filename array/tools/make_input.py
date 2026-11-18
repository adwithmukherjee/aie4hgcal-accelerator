"""Packetize distinct real hit slices on independent column ports."""
import argparse,json,struct
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('data',type=Path);p.add_argument('build',type=Path)
p.add_argument('--events',type=int,default=2);p.add_argument('--gated',action='store_true');a=p.parse_args()
mapping=json.loads((a.build/'config/packet_map.json').read_text())
frames=(a.data/'payloads.bin').read_bytes();assert len(frames)%6144==0
events=1 if a.gated else a.events
assert 0<events<=len(frames)//6144
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
   packet(out,headers[8],frame[5120:])
   for row in range(8):packet(out,headers[row],frame[c*1280+row*160:c*1280+(row+1)*160])
   if not a.gated:
    for row in range(8):packet(out,headers[9+row])
