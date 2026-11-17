"""Verify full-stage timing and every integrated input/output word after the run."""
import json,re,statistics,struct,sys
from pathlib import Path
from reference import reference

data,results=map(Path,sys.argv[1:3])
max_latency_ns=float(sys.argv[3]) if len(sys.argv)>3 else 4000.0
assert max_latency_ns>0,'Latency budget must be positive'
report=json.loads((results/'events.json').read_text())
manifest=json.loads((data/'manifest.json').read_text())
assert report['status']=='passed'
payloads=(data/'payloads.bin').read_bytes()
names,state,measured={},{},[]
current=None
now=0

def sample(timestamp,changes):
    global current
    old=state.copy();state.update(changes)
    if state.get('release_strobe')==1 and old.get('release_strobe')!=1:
        current=dict(release_ps=timestamp,input=bytearray(),output=bytearray())
        measured.append(current)
    if current is None:return
    if old.get('release_strobe')==1 and state.get('release_strobe')==0:
        current['release_pulse_ps']=timestamp-current['release_ps']
    for direction,index,valid,value in [
            ('input','tx_index','m_axis_tx_tvalid','m_axis_tx_tdata'),
            ('output','rx_index','s_axis_rx_tvalid','s_axis_rx_tdata')]:
        count=state.get(index)
        if count is not None and old.get(index)==count-1:
            assert old[valid]==1
            current[direction].extend(old[value].to_bytes(16,'little'))
    if state.get('density_done')==1 and old.get('density_done')!=1:
        assert state['rx_index']==8,'Final density accumulation endpoint'
        current['full_latency_ps']=timestamp-current['release_ps']
        current['full_latency_pl_cycles']=state['elapsed_cycles']
    if state.get('density_done')==1:
        assert state['elapsed_cycles']==current['full_latency_pl_cycles'],'Timer changed after density completion'
    if state.get('readback_done')==1:
        current['readback_complete']=True

with (results/'pl.vcd').open() as source:
    header=[]
    for line in source:
        header.append(line)
        if line.lstrip().startswith('$var'):
            fields=line.split();names[fields[3]]=fields[4]
        if '$enddefinitions' in line:break
    unit=re.search(r'\$timescale\s+(\d+)\s*(fs|ps|ns|us|ms|s)',''.join(header))
    assert unit,'Missing VCD time unit'
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

assert len(measured)==len(report['events'])==len(manifest['events'])
periods=[];events=[]
for i,(observed,host,identity) in enumerate(zip(measured,report['events'],manifest['events'])):
    payload=payloads[i*1184:(i+1)*1184]
    expected=reference(payload)
    assert observed['input']==payload,('Input payload',i+1)
    assert observed['output']==expected,('Density/distance output',i+1)
    assert observed['readback_complete']
    assert observed['full_latency_pl_cycles']==host['full_latency_pl_cycles']
    accumulated=struct.unpack('<128I',(results/f'density-{i+1}.bin').read_bytes())
    assert list(accumulated)==list(expected[:128]),('PL accumulated densities',i+1)
    periods.append(observed['full_latency_ps']/observed['full_latency_pl_cycles'])
    events.append(dict(sequence=i+1,identity=identity['identity'],full_latency_pl_cycles=host['full_latency_pl_cycles'],
        full_latency_ns=observed['full_latency_ps']/1000,exact_input_bytes=1184,exact_distances=2560,
        exact_aie_density_counts=128,exact_pl_accumulated_densities=128,density_sum=sum(accumulated)))
period=statistics.median(periods)
for observed in measured:
    assert abs(observed['release_pulse_ps']-period)<=2*quantum
    assert abs(observed['full_latency_ps']-observed['full_latency_pl_cycles']*period)<=2*quantum
performance_passed=all(event['full_latency_ns']<=max_latency_ns for event in events)
summary=dict(status='passed' if performance_passed else 'failed',correctness_status='passed',
    performance_status='passed' if performance_passed else 'failed',max_latency_ns=max_latency_ns,
    measurement='Integrated hardware emulation',radius_squared=645,
    start='Release resident input registers',finish='Final density contribution added into PL accumulators',
    pl_measured_hz=1e12/period,pl_period_ps=period,events=events,
    excluded='Host loading/CPU reference checks and distance-matrix readback after density completion')
(results/'validation.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
assert performance_passed,('Full-stage latency exceeds budget',max_latency_ns,
                          [event['full_latency_ns'] for event in events])
