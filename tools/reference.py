"""Exact scalar INT32-distance/landmark-density reference; untimed CPU only."""
import struct

def reference(payload):
    values=struct.unpack('1184b',payload)
    distances=[]
    counts=[0]*128
    for h in range(20):
        for r in range(128):
            squared=sum((int(values[h*8+d])-int(values[160+r*8+d]))**2 for d in range(8))
            distances.append(squared)
            counts[r]+=squared<=645
    return bytes(counts)+struct.pack('<2560i',*distances)
