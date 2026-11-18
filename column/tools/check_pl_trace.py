"""Verify integrated packet traffic, global density endpoint and CPU results."""
import json, re, statistics, struct, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2]/'tools'))
from reference import reference

data, build = map(Path, sys.argv[1:3])
results = build/'system/results'
mapping = json.loads((build/'config/packet_map.json').read_text())
manifest = json.loads((data/'manifest.json').read_text())
report = json.loads((results/'events.json').read_text())
assert report['status'] == 'passed' and report['tiles'] == mapping['tiles']
tiles = mapping['tiles']
payloads = (data/'payloads.bin').read_bytes()
names, state, measured = {}, {}, []
current = None
now = 0

def sample(timestamp, changes):
    global current
    old = state.copy()
    state.update(changes)
    if state.get('release_strobe') == 1 and old.get('release_strobe') != 1:
        current = dict(release_ps=timestamp, input=[], output=[], partial_input=[], partial_output=[])
        measured.append(current)
        assert state['active_count'] == tiles
    if current is None:
        return
    if old.get('release_strobe') == 1 and state.get('release_strobe') == 0:
        current['period_ps'] = timestamp-current['release_ps']
    for direction, index, prefix in [('input','tx_beats','m_axis_tx'), ('output','rx_beats','s_axis_rx')]:
        count = state.get(index)
        if count is None or old.get(index) != count-1:
            continue
        assert old[prefix+'_tvalid'] == old[prefix+'_tready'] == 1
        keep = old[prefix+'_tkeep']
        assert keep in (15,255,4095,65535)
        length = bin(keep).count("1")//4
        words = [(old[prefix+'_tdata']>>(32*i)) & 0xffffffff for i in range(length)]
        current['partial_'+direction].extend(words)
        if old[prefix+'_tlast']:
            current[direction].append((timestamp,current['partial_'+direction]))
            current['partial_'+direction] = []
    if state.get('density_done') == 1 and old.get('density_done') != 1:
        assert state['density_mask'] == (1<<tiles)-1
        assert state['rx_beats'] == 9*tiles
        current['finish_ps'] = timestamp
        current['cycles'] = state['elapsed_cycles']
    if state.get('density_done') == 1:
        assert state['elapsed_cycles'] == current['cycles'], 'Timer changed after accumulation'
    if state.get('readback_done') == 1:
        current['readback_complete'] = True
        assert state['readback_mask'] == (1<<tiles)-1

with (results/'pl.vcd').open() as source:
    header = []
    for line in source:
        header.append(line)
        if line.lstrip().startswith('$var'):
            fields = line.split(); names[fields[3]] = fields[4]
        if '$enddefinitions' in line:
            break
    unit = re.search(r'\$timescale\s+(\d+)\s*(fs|ps|ns|us|ms|s)', ''.join(header))
    assert unit
    quantum = int(unit[1])*{'fs':.001,'ps':1,'ns':1000,'us':1e6,'ms':1e9,'s':1e12}[unit[2]]
    changes = {}
    for line in source:
        line = line.strip()
        if line.startswith('#'):
            sample(now*quantum,changes); now = int(line[1:]); changes = {}
        elif line and line[0] in 'bB':
            value, identifier = line[1:].split()
            if identifier in names:
                changes[names[identifier]] = None if re.search('[xXzZ]',value) else int(value,2)
        elif line and line[0] in '01xXzZ' and line[1:] in names:
            changes[names[line[1:]]] = int(line[0]) if line[0] in '01' else None
    sample(now*quantum,changes)

def words(payload):
    return list(struct.unpack('<%dI'%(len(payload)//4),payload))

assert len(measured) == len(report['events']) == len(manifest['events'])
period = statistics.median((v["finish_ps"]-v["release_ps"])/v["cycles"] for v in measured)
assert abs(1e12/period/300000000-1) < .001
events = []
for index, (observed, host, identity) in enumerate(zip(measured,report['events'],manifest['events'])):
    frame = payloads[index*2304:(index+1)*2304]
    expected = [reference(frame[row*160:(row+1)*160]+frame[1280:]) for row in range(tiles)]
    tx = observed['input']
    assert len(tx) == 1+2*tiles
    assert tx[0][1] == [mapping['route_headers'][8],*words(frame[1280:])]
    for row in range(tiles):
        assert tx[1+row][1] == [mapping['route_headers'][row],*words(frame[row*160:(row+1)*160])]
        timestamp, request = tx[1+tiles+row]
        assert request == [mapping['route_headers'][12+row]]
        assert timestamp > observed['finish_ps'], 'Diagnostic request inside timed interval'
    rx = observed['output']
    assert len(rx) == 2*tiles
    seen = set()
    actual_matrices = [None]*tiles
    for timestamp, packet in rx:
        packet_header = packet[0]
        row = mapping['output_ids'].index(packet_header & 31)
        kind = (packet_header>>12)&7
        assert kind in (0,1) and (row,kind) not in seen
        seen.add((row,kind))
        assert packet[1:] == words(expected[row][:128] if kind==0 else expected[row][128:])
        if kind==1:
            actual_matrices[row]=struct.pack('<2560I',*packet[1:])
        assert timestamp <= observed['finish_ps'] if kind==0 else timestamp > observed['finish_ps']
    assert not observed['partial_input'] and not observed['partial_output'] and observed['readback_complete']
    accumulated = struct.unpack('<128I',(results/f'density-{index+1}.bin').read_bytes())
    assert list(accumulated) == [sum(result[r] for result in expected) for r in range(128)]
    matrix_bytes=b''.join(actual_matrices)
    assert matrix_bytes == b''.join(result[128:] for result in expected)
    (results/f'distances-{index+1}.bin').write_bytes(matrix_bytes)
    assert observed['cycles'] == host['full_latency_pl_cycles']
    latency = observed['finish_ps']-observed['release_ps']
    assert abs(latency-observed['cycles']*period) <= 2*quantum
    assert abs(observed['period_ps']-period) <= 2*quantum
    events.append(dict(sequence=index+1,identity=identity['identity'],full_latency_pl_cycles=observed['cycles'],
        full_latency_ns=latency/1000,exact_distances=tiles*2560,exact_aie_density_counts=tiles*128,
        exact_pl_accumulated_densities=128,density_sum=sum(accumulated)))
summary = dict(status='passed',measurement='Integrated hardware emulation',tiles=tiles,hits=20*tiles,
    landmarks=128,radius_squared=645,start='Release raw resident PL embeddings',
    finish='Final tile density contribution accumulated in PL',
    pl_measured_hz=1e12/period,pl_period_ps=period,events=events,
    excluded='Host loading, CPU correctness checks and full distance-matrix readback')
(results/'validation.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
