"""Export compiler-assigned packet IDs for PL setup and CPU verification."""
import json, re, struct, sys
from pathlib import Path

build = Path(sys.argv[1]).resolve()
experiment = json.loads((build/'config/experiment.json').read_text())
tiles = experiment['tiles']
header = (build/'aie/Work/temp/packet_ids_c.h').read_text()
defines = {name:int(value,0) for name,value in re.findall(
    r'^#define\s+(\w+)\s+(0x[\da-fA-F]+|\d+)\s*$',header,re.M)}

def ids(prefix, count):
    values = [defines[f'{prefix}_{i}'] for i in range(count)]
    assert all(0 <= v < 32 for v in values)
    assert len(set(values)) == count
    return values

def make_header(packet_id, packet_type=0):
    value = packet_id | (packet_type << 12) | (31 << 16) | (127 << 21)
    return value | ((1 ^ (bin(value).count('1') & 1)) << 31)

incoming = ids('column_input', 2*tiles+1)
outgoing = ids('column_output', tiles)
registers = [0]*20
for row in range(tiles):
    registers[row] = make_header(incoming[row])
    registers[12+row] = make_header(incoming[tiles+1+row], 2)
for group in range(4):
    registers[8+group] = make_header(incoming[tiles])
output_ids = outgoing+[0]*(8-tiles)
report = dict(**experiment,hit_ids=incoming[:tiles],landmark_id=incoming[tiles],
              readback_ids=incoming[tiles+1:],output_ids=outgoing,
              route_headers=registers,
              timed_input_payload_bytes=1024+160*tiles,
              timed_input_packet_bytes=1028+164*tiles,
              timed_input_beats=65+11*tiles,
              density_packet_bytes=132*tiles,density_beats=9*tiles)
(build/'config/packet_map.json').write_text(json.dumps(report,indent=2)+'\n')
(build/'config/route_headers.bin').write_bytes(struct.pack('<20I',*registers))
(build/'config/output_ids.bin').write_bytes(struct.pack('<8I',*output_ids))
print(json.dumps(report,indent=2))
