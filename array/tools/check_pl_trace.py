"""Check parallel traffic, CPU results and the final-label timer endpoint."""
import json,re,statistics,struct,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
from clustering_reference import reference,squared

data,build=map(Path,sys.argv[1:3])
mode=sys.argv[3] if len(sys.argv)>3 else 'normal'
assert mode in ('normal','force64')
force_64=mode=='force64'
results=build/f'system/results-{mode}'
mapping=json.loads((build/'config/packet_map.json').read_text())
manifest=json.loads((data/'manifest.json').read_text())
host_report=json.loads((results/'events.json').read_text())
columns=mapping['columns'];tiles=columns*8
assert host_report['status']=='passed' and host_report['columns']==columns
assert host_report['seed_mode']==('force64_density_rank' if force_64 else 'normal')
payloads=(data/'payloads.bin').read_bytes()
names,state,measured={},{},[]
current=None
now=0
def part(values,key,col,width):
    value=values.get(key)
    return None if value is None else (value>>(col*width))&((1<<width)-1)

def sample(timestamp,changes):
    global current
    old=state.copy();state.update(changes)
    if state.get('release_strobe')==1 and old.get('release_strobe')!=1:
        assert state.get('force_64')==int(force_64),'Hardware seed mode differs from requested benchmark'
        assert state.get('tx_valid')==(1<<columns)-1,'Column transmitters were not released together'
        current=dict(release_ps=timestamp,lanes=[dict(input=[],output=[],partial_input=[],partial_output=[]) for _ in range(columns)])
        measured.append(current)
    if current is None:return
    assert not state.get('fault') and not state.get('column_fault'),'PL protocol fault'
    if old.get('release_strobe')==1 and state.get('release_strobe')==0:
        current['period_ps']=timestamp-current['release_ps']
    for col,lane in enumerate(current['lanes']):
        for direction,prefix in [('input','tx'),('output','rx')]:
            count=part(state,prefix+'_beats',col,32)
            if count is None or part(old,prefix+'_beats',col,32)!=count-1:continue
            assert part(old,prefix+'_valid',col,1)==part(old,prefix+'_ready',col,1)==1
            keep=part(old,prefix+'_keep',col,16)
            assert keep in (15,255,4095,65535)
            length=bin(keep).count('1')//4
            value=part(old,prefix+'_data',col,128)
            lane['partial_'+direction].extend((value>>(32*i))&0xffffffff for i in range(length))
            lane.setdefault('first_'+direction+'_ps',timestamp)
            if part(old,prefix+'_last',col,1):
                lane[direction].append((timestamp,lane['partial_'+direction]))
                lane['partial_'+direction]=[]
        if part(state,'column_density_done',col,1)==1 and part(old,'column_density_done',col,1)!=1:
            assert part(state,'tile_density_masks',col,8)==255
            assert part(state,'rx_beats',col,32)==72
            lane['finish_ps']=timestamp
    if state.get('cluster_done')==1 and old.get('cluster_done')!=1:
        assert state['column_labels_done']==(1<<columns)-1
        current['finish_ps']=timestamp;current['cycles']=state['elapsed_cycles']
    if state.get('cluster_done')==1:
        assert state['elapsed_cycles']==current['cycles'],'Timer changed after final label storage'
    if state.get('cluster_done')==1:
        current['complete']=True
        assert state['column_labels_done']==(1<<columns)-1
        for col in range(columns):
            assert part(state,'tile_label_masks',col,8)==255
            assert part(state,'rx_beats',col,32)==88
            seed_count=host_report['events'][len(measured)-1]['seed_count']
            assert part(state,'tx_beats',col,32)==153+(2+(seed_count+3)//4+3)//4

with (results/'pl.vcd').open() as source:
    header=[]
    for line in source:
        header.append(line)
        if line.lstrip().startswith('$var'):
            fields=line.split();names[fields[3]]=fields[4]
        if '$enddefinitions' in line:break
    unit=re.search(r'\$timescale\s+(\d+)\s*(fs|ps|ns|us|ms|s)',''.join(header));assert unit
    quantum=int(unit[1])*{'fs':.001,'ps':1,'ns':1000,'us':1e6,'ms':1e9,'s':1e12}[unit[2]]
    changes={}
    for line in source:
        line=line.strip()
        if line.startswith('#'):
            sample(now*quantum,changes);now=int(line[1:]);changes={}
        elif line and line[0] in 'bB':
            value,identifier=line[1:].split()
            if identifier in names:changes[names[identifier]]=None if re.search('[xXzZ]',value) else int(value,2)
        elif line and line[0] in '01xXzZ' and line[1:] in names:
            changes[names[line[1:]]]=int(line[0]) if line[0] in '01' else None
    sample(now*quantum,changes)

def words(payload):return list(struct.unpack('<%dI'%(len(payload)//4),payload))
assert len(measured)==len(host_report['events'])==len(manifest['events'])
period=statistics.median((v['finish_ps']-v['release_ps'])/v['cycles'] for v in measured)
assert abs(1e12/period/300000000-1)<.001
events=[]
for index,(observed,host,identity) in enumerate(zip(measured,host_report['events'],manifest['events'])):
    frame=payloads[index*6144:(index+1)*6144]
    expected=reference(frame,identity['landmark_ids'],force_64)
    if force_64:assert expected['seed_count']==64 and len(set(expected['seed_slots']))==64
    values=struct.unpack('6144b',frame)
    landmarks=[values[i:i+8] for i in range(5120,6144,8)]
    last_labels=[]
    for col,(lane,routes) in enumerate(zip(observed['lanes'],mapping['lanes'])):
        tx=lane['input'];assert len(tx)==10
        assert tx[0][1]==[routes['route_headers'][8],*words(frame[5120:])]
        for row in range(8):
            tile=col*8+row
            assert tx[1+row][1]==[routes['route_headers'][row],*words(frame[tile*160:(tile+1)*160])]
        seeds=expected['seed_slots']
        seed_payload=struct.pack('<I',len(seeds))+bytes(seeds+[0]*((-len(seeds))%4))
        assert tx[9][1]==[routes['route_headers'][9],*words(seed_payload)]
        assert tx[9][0]>max(l['finish_ps'] for l in observed['lanes'])
        rx=lane['output'];assert len(rx)==16
        seen=set()
        for timestamp,packet in rx:
            row=routes['output_ids'].index(packet[0]&31);tile=col*8+row
            kind=(packet[0]>>12)&7
            assert kind in (0,2) and (row,kind) not in seen
            seen.add((row,kind))
            if kind==0:
                hits=[values[i:i+8] for i in range(tile*160,(tile+1)*160,8)]
                payload=bytes(sum(squared(h,r)<=645 for h in hits) for r in landmarks)
                assert timestamp<=lane['finish_ps']
            else:
                payload=bytes(expected['labels'][tile*20:(tile+1)*20])
                assert tx[9][0]<timestamp<=observed['finish_ps']
                last_labels.append(timestamp)
            assert packet[1:]==words(payload),(index,col,row,kind)
        assert not lane['partial_input'] and not lane['partial_output']
    assert observed['complete'] and max(last_labels)==observed['finish_ps']
    accumulated=struct.unpack('<128I',(results/f'density-{index+1}.bin').read_bytes())
    assert list(accumulated)==expected['density']
    assert (results/f'labels-{index+1}.bin').read_bytes()==bytes(expected['labels'])
    assert (results/f'seed-slots-{index+1}.bin').read_bytes()==bytes(seeds+[0]*(64-len(seeds)))
    assert words((results/f'seed-hit-ids-{index+1}.bin').read_bytes())==expected['seed_hit_ids']+[0]*(64-len(seeds))
    assert host['seed_count']==len(seeds) and host['seed_overflow']==expected['seed_overflow']
    assert observed['cycles']==host['full_latency_pl_cycles']
    latency=observed['finish_ps']-observed['release_ps']
    assert abs(latency-observed['cycles']*period)<=2*quantum
    assert abs(observed['period_ps']-period)<=2*quantum
    events.append(dict(sequence=index+1,identity=identity['identity'],full_latency_pl_cycles=observed['cycles'],
        full_latency_ns=latency/1000,exact_labels=640,exact_aie_density_counts=tiles*128,
        exact_pl_accumulated_densities=128,density_sum=sum(accumulated),
        seed_count=expected['seed_count'],seed_slots=expected['seed_slots'],
        seed_hit_ids=expected['seed_hit_ids'],seed_overflow=expected['seed_overflow']))
clock=json.loads((build/'system/clock_evidence.json').read_text())
summary=dict(status='passed',measurement='Integrated hardware emulation',columns=columns,tiles=tiles,hits=tiles*20,
    seed_mode=host_report['seed_mode'],separation_calculations_retained=True,
    landmarks=128,radius_squared=645,start='Release raw resident PL embeddings',
    finish='Final hit label stored in original order in PL',pl_measured_hz=1e12/period,
    aie_hz=clock['aie_hz'],pl_period_ps=period,events=events,
    excluded='Landmark sampling/gathering, host loading and CPU correctness checks')
(results/'validation.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
