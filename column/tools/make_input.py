"""Packetize compact real-event fixtures for native AIE qualification."""
import json, struct, sys
from pathlib import Path

data, build = map(Path, sys.argv[1:3])
gated = len(sys.argv)>3 and sys.argv[3]=='--gated'
mapping = json.loads((build/'config/packet_map.json').read_text())
frames = (data/'payloads.bin').read_bytes()
assert len(frames) % 2304 == 0
if gated:
    frames = frames[:2304]
headers = mapping['route_headers']

def packet(output, header, payload=b''):
    words = [header, *struct.unpack('<%dI' % (len(payload)//4), payload)]
    for offset in range(0, len(words), 4):
        if offset+4 >= len(words):
            output.write('TLAST\n')
        output.write(' '.join(str(v) for v in words[offset:offset+4])+'\n')

with (build/'aie/input.txt').open('w') as output:
    for offset in range(0, len(frames), 2304):
        frame = frames[offset:offset+2304]
        packet(output, headers[8], frame[1280:])
        for row in range(mapping['tiles']):
            packet(output, headers[row], frame[row*160:(row+1)*160])
        # The gate regression supplies no tokens. Regular native qualification
        # prequeues them; integrated PL waits for global density completion.
        if not gated:
            for row in range(mapping['tiles']):
                packet(output, headers[12+row])
