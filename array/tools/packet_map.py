"""Read each column's independent packet-routing domain from the compiler."""
import json,re,struct,sys
from pathlib import Path
build=Path(sys.argv[1]).resolve()
experiment=json.loads((build/'config/experiment.json').read_text())
header=(build/'aie/Work/temp/packet_ids_c.h').read_text()
defines={k:int(v,0) for k,v in re.findall(r'^#define\s+(\w+)\s+(0x[\da-fA-F]+|\d+)\s*$',header,re.M)}
def ids(prefix,n):
 values=[defines[f'{prefix}_{i}'] for i in range(n)]
 assert len(set(values))==n and all(0<=x<32 for x in values)
 return values
def packet_header(identifier,kind=0):
 value=identifier|(kind<<12)|(31<<16)|(127<<21)
 return value|((1^(bin(value).count('1')&1))<<31)
lanes=[];all_headers=[];all_ids=[]
for c in range(experiment['columns']):
 incoming=ids(f'array_input_{c}',17);outgoing=ids(f'array_output_{c}',8)
 registers=[packet_header(x,2 if i>=9 else 0) for i,x in enumerate(incoming)]
 lanes.append(dict(index=c,physical_column=24+c,hit_ids=incoming[:8],landmark_id=incoming[8],
                   readback_ids=incoming[9:],output_ids=outgoing,route_headers=registers))
 all_headers+=registers;all_ids+=outgoing
report=dict(**experiment,lanes=lanes,timed_input_beats_per_column=153,
            density_beats_per_column=72,timed_input_packet_bytes_per_column=2340,
            density_packet_bytes_per_column=1056)
(build/'config/packet_map.json').write_text(json.dumps(report,indent=2)+'\n')
for name,values in [('route_headers',all_headers),('output_ids',all_ids)]:
 (build/f'config/{name}.bin').write_bytes(struct.pack('<%dI'%len(values),*values))
print('Extracted routing for',len(lanes),'independent columns')
