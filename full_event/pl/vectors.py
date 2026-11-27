"""Translate event 187 native AIE packets into AXI-stream beats for PL verification."""
from pathlib import Path
import re
import struct
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from verify_event import oracle, packet_header, read_packets, embeddings

aie, fixture, out = map(Path,sys.argv[1:])
out.mkdir(exist_ok=True, parents=True)
ids = {k:int(v,0) for k,v in re.findall(r'^#define\s+(\w+)\s+(0x[\da-fA-F]+|\d+)\s*$',(aie/'Work/temp/packet_ids_c.h').read_text(),re.M)}
lm,seeds,batches,counts,labels=oracle(fixture)
def mem(name,values,digits):
    (out/name).write_text(''.join(f'{v:0{digits}x}\n' for v in values))
def beats(words):
    for i in range(0,len(words),4):
        chunk=words[i:i+4]
        yield (int(i+4>=len(words))<<144) | (((1<<(4*len(chunk)))-1)<<128) | sum(v<<(32*j) for j,v in enumerate(chunk))
def payload_words(buf):
    return list(struct.unpack('<%dI'%(len(buf)//4),buf))
routes=[]
for c in range(48):
    heads=[packet_header(ids[f'array_input_{c}_{i}'],2 if i==9 else 0) for i in range(10)]
    routes.extend(heads+[ids[f'array_output_{c}_{i}'] for i in range(8)])
    tx=list(beats([heads[8]]+payload_words(embeddings(lm))))
    for row in range(8):
        data=embeddings(batches[8*c+row])
        tx.extend(beats([heads[row]]+payload_words(data+bytes(-len(data)%16))))
    tx.extend(beats([heads[9],len(seeds)]+payload_words(bytes(seeds)+bytes(-len(seeds)%4))))
    rx=[b for packet in read_packets(aie/f'sim/output-{c}.txt',21 if c<40 else 20) for b in beats(packet)]
    mem(f'tx{c}.mem',tx,37)
    mem(f'rx{c}.mem',rx,37)
mem('routes.mem',routes,8)
gold=b''.join(labels)
(out/'labels.bin').write_bytes(gold)
(out/'routes.bin').write_bytes(struct.pack('<%dI'%len(routes),*routes))
mem('densities.mem',[sum(tile[i] for tile in counts) for i in range(128)],8)
mem('labels.mem',gold,2)
