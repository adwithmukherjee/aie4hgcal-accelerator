"""Prepare native AIE streams or verify the 384 workers against event 187."""
import argparse
import json
from pathlib import Path
import re
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'array/tools'))
from clustering_reference import select, squared

def packet_header(identifier, kind):
    value = identifier | (kind << 12) | (31 << 16) | (127 << 21)
    return value | ((1 ^ (bin(value).count('1') & 1)) << 31)

def write_packet(stream, header, payload):
    words = [header, *struct.unpack('<%dI' % (len(payload) // 4), payload)]
    for i in range(0, len(words), 4):
        if i + 4 >= len(words):
            stream.write('TLAST\n')
        stream.write(' '.join(str(v) for v in words[i:i+4]) + '\n')

def read_packets(path, hits_per_worker):
    words, last, keep = [], False, None
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith(('#', 'T ')):
            continue
        if line.startswith('TLAST'):
            last = True
            continue
        if line.startswith('TKEEP'):
            keep = int(line.split()[1], 0)
            continue
        beat = [int(x, 0) & 0xffffffff for x in line.split()]
        if keep is not None:
            beat = [v for i, v in enumerate(beat) if ((keep >> (4*i)) & 15) == 15]
        words.extend(beat)
        keep = None
        kind = (words[0] >> 12) & 7
        if kind not in (0, 2):
            raise ValueError(f'{path}: unknown packet type {kind}')
        length = 33 if kind == 0 else 1 + (hits_per_worker + 3) // 4
        if len(words) > length or (last and len(words) != length):
            raise ValueError(f'{path}: invalid packet boundary at {len(words)} of {length} words')
        if len(words) == length:
            yield words
            words, last = [], False
    assert not words and not last, ('partial packet', path)

def oracle(fixture):
    slot_ids = [int(s, 16) for s in (fixture/'original_ids.mem').read_text().split()]
    assert len(slot_ids) == len(set(slot_ids)) == 8000 and 0xffffffff not in slot_ids
    ids = struct.unpack('<128I', (fixture/'landmark_ids.bin').read_bytes())
    assert list(ids) == slot_ids[:128]
    hits = [struct.unpack('<8b', int(s, 16).to_bytes(8, 'little'))
            for s in (fixture/'expected.mem').read_text().split()]
    assert len(hits) == 8000
    landmarks = hits[:128]
    tile_counts, totals, tiles = [], [0]*128, []
    cursor = 0
    for tile in range(384):
        n = 21 if tile < 320 else 20
        batch = hits[cursor:cursor+n]
        counts = [sum(squared(hit, lm) <= 645 for hit in batch) for lm in landmarks]
        tile_counts.append(bytes(counts))
        totals = [a+b for a, b in zip(totals, counts)]
        tiles.append(batch)
        cursor += n
    assert cursor == 8000
    seeds, _ = select(landmarks, totals, ids)
    labels = [bytes(min(range(len(seeds)), key=lambda s: squared(hit, landmarks[seeds[s]]))
                    for hit in batch) for batch in tiles]
    return landmarks, seeds, tiles, tile_counts, labels

def embeddings(values):
    return b''.join(struct.pack('<8b', *v) for v in values)

def main():
    p = argparse.ArgumentParser()
    p.add_argument('mode', choices=['reference', 'prepare', 'verify'])
    p.add_argument('fixture', type=Path)
    p.add_argument('aie', type=Path, nargs='?')
    a = p.parse_args()
    landmarks, seeds, batches, counts, labels = oracle(a.fixture)
    summary = dict(tiles=len(batches), hits=sum(map(len, labels)), seeds=len(seeds),
                   columns=[1, 48], event=187)
    if a.mode == 'reference':
        print(json.dumps(summary))
        return
    header = (a.aie/'Work/temp/packet_ids_c.h').read_text()
    ids = {k:int(v, 0) for k,v in re.findall(r'^#define\s+(\w+)\s+(0x[\da-fA-F]+|\d+)\s*$', header, re.M)}
    for c in range(48):
        if a.mode == 'prepare':
            incoming = [ids[f'array_input_{c}_{i}'] for i in range(10)]
            assert len(set(incoming)) == 10
            with (a.aie/f'input-{c}.txt').open('w') as f:
                write_packet(f, packet_header(incoming[8], 0), embeddings(landmarks))
                for row in range(8):
                    data = embeddings(batches[8*c+row])
                    write_packet(f, packet_header(incoming[row], 0), data + bytes(-len(data)%16))
                seed_data = struct.pack('<I', len(seeds)) + bytes(seeds) + bytes(-len(seeds)%4)
                write_packet(f, packet_header(incoming[9], 2), seed_data)
        else:
            routes = {ids[f'array_output_{c}_{row}']:row for row in range(8)}
            assert len(routes) == 8
            phases = [0]*8
            for packet in read_packets(a.aie/f'sim/output-{c}.txt', 21 if c < 40 else 20):
                row = routes[packet[0] & 31]
                kind = (packet[0] >> 12) & 7
                assert phases[row] < 2 and kind == [0,2][phases[row]], (c,row,kind)
                tile = 8*c+row
                expected = counts[tile] if kind == 0 else labels[tile]
                actual = struct.pack('<%dI' % (len(packet)-1), *packet[1:])
                assert actual == expected + bytes(-len(expected)%4), (c,row,kind)
                phases[row] += 1
            assert phases == [2]*8, (c,phases)
    print(a.mode, json.dumps(summary))

if __name__ == '__main__':
    main()
