"""Check every encoder output, accepted packet, and ROI edge in the linked VCD."""
import argparse,hashlib,json,re,statistics,struct
from pathlib import Path

p=argparse.ArgumentParser();p.add_argument('build',type=Path);p.add_argument('data',type=Path,nargs='?');a=p.parse_args()
if a.data is None:a.data=a.build/'data'
results=a.build/'system/results';fixture=a.data/'event-00187'
host=json.loads((results/'events.json').read_text())
def hexes(name):return [int(s,16) for s in (fixture/name).read_text().split()]
expected=hexes('expected.mem');payload=hexes('payload.mem');tile_counts=hexes('tile_counts.mem')
headers=list(struct.unpack('<40I',(a.build/'config/route_headers.bin').read_bytes()))
ids=list(struct.unpack('<32I',(a.build/'config/output_ids.bin').read_bytes()))
clusters=[hexes('cluster_normal.mem'),hexes('cluster_forced.mem')]
state={};names={};observed=[];current=None
def bits(value,start,width):
 assert isinstance(value,str),('Missing bus',value)
 value=value.rjust(start+width,value[0] if value[0] in 'xXzZ' else '0')
 word=value[-start-width:len(value)-start] if start else value[-width:]
 assert not re.search('[xXzZ]',word),('Unknown valid bus bits',word)
 return int(word,2)
def packet_header(packet,kind,id):
 word=packet[0]
 assert word&31==id and (word>>12)&7==kind,(hex(word),id,kind)
 assert bin(word).count('1')%2==1,'Bad packet parity'
def sample(t,changes):
 global current
 old=state.copy();state.update(changes)
 if state.get('busy')==1 and old.get('busy')!=1:
  assert state['elapsed_cycles']==state['encoded_count']==0
  assert len(observed)<2
  current=dict(release_ps=t,embeddings=[],clock_edges=0,tx=[[] for _ in range(4)],rx=[[] for _ in range(4)],
               tx_packets=[[] for _ in range(4)],rx_packets=[[] for _ in range(4)],tx_stalls=[0]*4,
               first_payload_ps=[None]*4,last_input_ps=[None]*4,density_packets=[set() for _ in range(4)],label_packets=[set() for _ in range(4)])
  observed.append(current)
 if current is None:return
 assert not state.get('fault') and not state.get('column_fault'),('RTL fault',t)
 rising=state.get('ap_clk')==1 and old.get('ap_clk')!=1
 if rising and (state.get('busy') or old.get('busy')):
  current['clock_edges']+=1
  if state.get('prepare'):
   assert state['prefix_ready']&3==3 and state['busy']
   current.setdefault('geometry_prepare_ps',t)
  for col in range(4):
   if (old.get('tx_valid',0)>>col)&1:
    if not (old['tx_ready']>>col)&1:
     current['tx_stalls'][col]+=1
     assert (state['tx_valid']>>col)&1
     for name,width in [('tx_data',128),('tx_keep',16),('tx_last',1)]:
      if name=='tx_data':assert bits(old[name],col*width,width)==bits(state[name],col*width,width),'TX changed under backpressure'
      else:assert (old[name]>>(col*width))&((1<<width)-1)==(state[name]>>(col*width))&((1<<width)-1)
    else:
     keep=(old['tx_keep']>>(16*col))&65535
     assert keep in (15,255,4095,65535)
     words=[bits(old['tx_data'],col*128+32*k,32) for k in range(bin(keep).count('1')//4)]
     packet=current['tx'][col]
     assert ((old['tx_last']>>col)&1) or keep==65535,'Partial interior PLIO beat'
     if (packet or len(words)>1) and len(current['tx_packets'][col])==0 and current['first_payload_ps'][col] is None:
      current['first_payload_ps'][col]=t
      assert old['encoded_count']<8000,'Streaming began only after the whole event'
     packet.extend(words)
     if (old['tx_last']>>col)&1:
      index=len(current['tx_packets'][col]);gold=clusters[len(observed)-1]
      if index==0:expected_packet=[headers[col*10+8]]+payload[1280:1536]
      elif index<=8:
       row=index-1;offset=col*320+row*40
       expected_packet=[headers[col*10+row]]+payload[offset:offset+40]
      else:
       assert index==9
       expected_packet=[headers[col*10+9],gold[128]]+gold[130:130+(gold[128]+3)//4]
      assert packet==expected_packet,('TX packet mismatch',len(observed)-1,col,index)
      current['tx_packets'][col].append(len(packet));current['tx'][col]=[]
      if index==8:current['last_input_ps'][col]=t
   if ((old.get('rx_valid',0)&old.get('rx_ready',0))>>col)&1:
    keep=(old['rx_keep']>>(16*col))&65535;assert keep in (15,255,4095,65535)
    packet=current['rx'][col]
    packet.extend(bits(old['rx_data'],col*128+k*32,32) for k in range(bin(keep).count('1')//4))
    if (old['rx_last']>>col)&1:
     kind=(packet[0]>>12)&7;assert kind in (0,2)
     row=ids[col*8:col*8+8].index(packet[0]&31);tile=col*8+row
     packet_header(packet,kind,ids[tile])
     seen=current['density_packets'][col] if kind==0 else current['label_packets'][col]
     assert row not in seen;seen.add(row)
     gold=tile_counts[tile*32:tile*32+32] if kind==0 else clusters[len(observed)-1][210+tile*5:215+tile*5]
     assert packet[1:]==gold,('RX payload mismatch',col,row,kind)
     current['rx_packets'][col].append(dict(kind=kind,row=row,words=len(packet)));current['rx'][col]=[]
 if state.get('encoded_count',0)==old.get('encoded_count',0)+64:
  assert rising and old['out_valid']==1 and old['mask']==2**64-1
  base=old['base_id'];assert base==len(current['embeddings'])
  values=[bits(old['embeddings'],i*64,64) for i in range(64)]
  assert values==expected[base:base+64]
  current['embeddings'].extend(values);current.setdefault('first_embedding_ps',t)
  if old['out_last']:
   assert base==7936
   current['last_embedding_ps']=t;current['encoder_cycles']=state['encoder_cycles']
 if state.get('cluster_done')==1 and old.get('cluster_done')!=1:
  assert rising and old['busy'] and state['busy']==0 and state['encoded_count']==8000
  assert old['column_labels_finishing']==15 and state['column_labels_done']==15
  current['finish_ps']=t;current['cycles']=state['elapsed_cycles']
 if 'finish_ps' in current:assert state['elapsed_cycles']==current['cycles']

path=results/'pl.vcd'
with path.open() as source:
 header=[]
 for line in source:
  header.append(line)
  if line.lstrip().startswith('$var'):
   fields=line.split();names[fields[3]]=fields[4]
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
   if key in names:changes[names[key]]=value if names[key] in ('embeddings','tx_data','rx_data') else (None if re.search('[xXzZ]',value) else int(value,2))
  elif line and line[0] in '01xXzZ' and line[1:] in names:
   changes[names[line[1:]]]=int(line[0]) if line[0] in '01' else None
 sample(now*quantum,changes)
assert len(observed)==len(host['events'])==2
period=statistics.median((o['finish_ps']-o['release_ps'])/o['cycles'] for o in observed)
assert abs(1e12/period/300e6-1)<.001
clock=json.loads((a.build/'system/clock_evidence.json').read_text());assert clock['aie_hz']==1e9
rows=[]
for trial,(o,h) in enumerate(zip(observed,host['events'])):
 assert o['clock_edges']==o['cycles']+1
 assert o['cycles']==h['final_cycles'] and o['encoder_cycles']==h['encoder_cycles']==137
 assert o['embeddings']==expected
 assert (results/f'embeddings-{trial}.bin').read_bytes()==struct.pack('<8000Q',*expected)
 assert (results/f'labels-{trial}.bin').read_bytes()==struct.pack('<160I',*clusters[trial][210:370])
 assert (results/f'density-{trial}.bin').read_bytes()==struct.pack('<128I',*clusters[trial][:128])
 assert abs((o['first_embedding_ps']-o['release_ps'])/period-13)<.01
 assert abs((o['last_embedding_ps']-o['release_ps'])/period-137)<.01
 assert 'geometry_prepare_ps' in o
 assert all(len(v)==10 for v in o['tx_packets']) and all(len(v)==16 for v in o['rx_packets'])
 assert all(s==set(range(8)) for s in o['density_packets']+o['label_packets'])
 assert not any(o['tx']+o['rx'])
 rows.append(dict(**h,final_us=(o['finish_ps']-o['release_ps'])/1e6,
                  first_embedding_us=(o['first_embedding_ps']-o['release_ps'])/1e6,
                  last_embedding_us=(o['last_embedding_ps']-o['release_ps'])/1e6,
                  first_aie_payload_us=[(t-o['release_ps'])/1e6 for t in o['first_payload_ps']],
                  last_aie_input_us=[(t-o['release_ps'])/1e6 for t in o['last_input_ps']],tx_stall_cycles=o['tx_stalls']))
report=dict(status='passed',measurement=host['measurement'],setup_readback=host['setup_readback'],pl_hz=1e12/period,aie_hz=clock['aie_hz'],
            events=rows,direct_clock_edge_check=True,stalled_payload_stability_check=True,
            exact_tx_rx_packet_check=True,streaming_overlaps_encoding=True,
            trace_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
(results/'trace-validation.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
