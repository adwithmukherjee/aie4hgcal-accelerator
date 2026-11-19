"""Export the pinned compact KAN; generate deterministic independent integer oracles."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np

SHA256 = 'b7856fb8e0e999a1fba6a2890f83a5eea89454a6bd3b434d7303d9923f640317'


def reference(x, tables):
    # Deliberately scalar by edge/output, with wide Python integer accumulation.
    result = []
    for hit in x:
        hidden = []
        for j in range(12):
            total = sum(int(tables[0][i, int(hit[i]), j]) for i in range(4))
            hidden.append(max(-31, min(31, (total + 2) // 4)) + 31)
        result.append([max(-127, min(127, sum(int(tables[1][i, hidden[i], j])
                                            for i in range(12)))) for j in range(8)])
    return np.asarray(result, dtype=np.int8)


def packed(path, values):
    path.write_text(''.join(row[::-1].tobytes().hex() + '\n' for row in values))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('tables', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    assert hashlib.sha256(args.tables.read_bytes()).hexdigest() == SHA256
    args.output.mkdir(parents=True, exist_ok=True)
    with np.load(args.tables, allow_pickle=False) as f:
        tables = [f['table_0'], f['table_1']]
    assert [t.shape for t in tables] == [(4, 256, 12), (12, 64, 8)]
    assert all(t.dtype == np.int8 for t in tables)
    lines = ['`timescale 1ns/1ps', '// Generated from the SHA256-pinned epoch-6 integer export.',
             'module kan_lane(input wire clk, ce, input wire [31:0] din, output wire [63:0] dout);']
    inputs = [f'din[{8*i}+:8]' for i in range(4)]
    stages = 0
    for layer, table in enumerate(tables):
        ins, states, outs = table.shape
        leaves = []
        for i, address in enumerate(inputs):
            name = f'rom_{layer}_{i}'
            packed(args.output / (name + '.mem'), table[i])
            lines += [f'(* rom_style="distributed" *) reg [{outs*8-1}:0] {name} [0:{states-1}];',
                      f'initial $readmemh("{name}.mem", {name});',
                      f'reg [{outs*8-1}:0] q_{layer}_{i};',
                      f'always @(posedge clk) if(ce) q_{layer}_{i} <= {name}[{address}];']
            leaves.append([f'$signed(q_{layer}_{i}[{8*j}+:8])' for j in range(outs)])
        stages += 1
        inputs = []
        for j in range(outs):
            terms = [v[j] for v in leaves]
            # Pad to a power of two, ensuring every path has identical stage depth.
            terms += ["8'sd0"] * ((1 << (ins-1).bit_length()) - ins)
            level = 0
            while len(terms) > 1:
                new = []
                for k in range(0, len(terms), 2):
                    name = f'sum_{layer}_{j}_{level}_{k//2}'
                    width = 9 + level
                    # Extend operands explicitly before addition: no implicit sizing.
                    def extend(term):
                        return f"{width}'($signed({term}))"
                    lines += [f'reg signed [{width-1}:0] {name};',
                              f'always @(posedge clk) if(ce) {name} <= {extend(terms[k])} + {extend(terms[k+1])};']
                    new.append(name)
                terms = new
                level += 1
            total = terms[0]
            if layer == 0:
                name = f'address_{j}'
                lines += [f'reg [5:0] {name};',
                          f'always @(posedge clk) if(ce) {name} <= {total} < -122 ? 0 : {total} >= 122 ? 62 : (32\'($signed({total})) + 126) >>> 2;']
                inputs.append(name)
            else:
                lines += [f'reg signed [7:0] out_{j};',
                          f'always @(posedge clk) if(ce) out_{j} <= {total} > 127 ? 127 : {total} < -127 ? -127 : {total};',
                          f'assign dout[{8*j}+:8] = out_{j};']
        stages += level + 1
    lines += ['endmodule']
    assert stages == 10
    (args.output/'kan_lane.sv').write_text('\n'.join(lines)+'\n')
    rng = np.random.default_rng(20261119)
    x = rng.integers(0, 256, (8000, 4), dtype=np.uint8)
    # Sweep every byte value independently, with the other channels at endpoints.
    for i in range(4):
        for endpoint in (0, 255):
            start = (i*2 + (endpoint == 255))*256
            x[start:start+256] = endpoint
            x[start:start+256, i] = np.arange(256)
    x[2048:2050] = [[0, 0, 0, 0], [255, 255, 255, 255]]
    packed(args.output/'wire.mem', x)
    packed(args.output/'expected.mem', reference(x, tables))
    (args.output/'manifest.json').write_text(json.dumps(dict(
        tables_sha256=SHA256, shape=[4,12,8], selected_epoch=6, stages=stages,
        ii=1, table_bytes=sum(t.nbytes for t in tables), vectors=len(x),
        artifacts={p.name:hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in sorted(args.output.iterdir()) if p.suffix in ('.sv','.mem')}), indent=2)+'\n')


if __name__ == '__main__':
    main()
