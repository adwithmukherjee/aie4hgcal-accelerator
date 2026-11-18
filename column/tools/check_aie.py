"""Match packetized densities and all distances for every active row/event."""
import json,struct,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
from reference import reference

data,output,config=map(Path,sys.argv[1:4])
manifest=json.loads((data/'manifest.json').read_text())
gated=len(sys.argv)>4 and sys.argv[4]=='--gated'
events=manifest['events'][:1] if gated else manifest['events']
mapping=json.loads(config.read_text())
frames=(data/'payloads.bin').read_bytes()
tiles=mapping['tiles']
rows={packet_id:row for row,packet_id in enumerate(mapping['output_ids'])}
progress=[[0,0] for _ in range(tiles)]
packet=[];last=False;keep=None;packets=0
now=0;started=0
for line in output.read_text().splitlines():
    line=line.strip()
    if not line or line.startswith('#'):continue
    if line.startswith('T '):
        _,value,unit=line.split()
        now=float(value)*{'ps':.001,'ns':1,'us':1000}[unit]
        continue
    if line.startswith('TLAST'):last=True;continue
    if line.startswith('TKEEP'):keep=int(line.split()[1],0);continue
    words=[int(x,0)&0xffffffff for x in line.split()]
    if keep is not None:
        words=words[:sum((keep>>(4*i))&15==15 for i in range(4))]
    if not packet:started=now
    packet.extend(words);keep=None
    header=packet[0];kind=(header>>12)&7
    assert kind in (0,1)
    expected_words=33 if kind==0 else 2561
    assert len(packet)<=expected_words
    if last:assert len(packet)==expected_words
    # Vitis omits TLAST annotations with --output-time-stamp=no, while
    # retaining the short final data line. Integrated VCD checks actual TLAST.
    if len(packet)<expected_words:continue
    assert len(words)==1, "Missing partial final packet beat"
    last=False
    row=rows[header&31]
    event,expected_kind=progress[row]
    assert kind==expected_kind and event<len(events),(row,event,kind)
    if gated:
        assert kind==0,(row,'Matrix returned without a readback request',started)
    frame=frames[event*2304:(event+1)*2304]
    expected=reference(frame[row*160:(row+1)*160]+frame[1280:])
    actual=struct.pack('<%dI'%(len(packet)-1),*packet[1:])
    assert actual==(expected[:128] if kind==0 else expected[128:]),(row,event,kind,'Output mismatch')
    progress[row]=[event,1] if kind==0 else [event+1,0]
    packets+=1;packet=[]
target=[0,1] if gated else [len(events),0]
assert not packet and all(p==target for p in progress),(progress,'Missing density or incomplete packet')
report=dict(status='passed',measurement='AIE functional simulation',tiles=tiles,
            events=len(events),packets=packets,exact_distances=0 if gated else tiles*2560*len(events),
            exact_density_counts=tiles*128*len(events),radius_squared=645,
            readback_requests_withheld=gated)
(output.parent/'validation.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
