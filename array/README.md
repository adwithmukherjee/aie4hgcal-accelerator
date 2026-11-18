# Parallel full-column density benchmark

Two columns use 16 AIE tiles and 320 real hits; four columns use 32 tiles and
640 real hits. Every tile receives 20 distinct 8D signed INT8 hits and the same
128 landmarks. The inclusive filter is `distance_squared <= 645`. The qualified
kernel from `column/kernel.cpp` is reused, including its native SIMD layout
preparation, squared norms and optimized distance loop.

Each column has an independent 128-bit input/output pair at 300 MHz. Workers
occupy rows 0–7 in physical columns 24 onward, with a shim interface in the same
column. Compiler checks require column-local routes and the qualified native
instruction schedule. Each input broadcasts the landmarks to its eight workers
and distributes distinct hit packets. AIE returns 128 byte-sized counts per
worker; its column's PL receiver adds these into 128 UINT32 partial sums.

Once all columns finish, PL combines their partial sums with a registered adder
tree. All 128 landmarks are reduced in parallel. Two columns take one PL cycle;
four columns take two. There is one global timer, from the common release edge
of the resident raw input registers through the edge that registers the final
128 global sums. It includes the slowest column and the entire final reduction.
Layout and norm preparation remain on AIE and remain inside this interval.

There are no substage timers or timed acknowledgement/checksum passes. The
per-column count registers clear in parallel on the release edge. The final
sum is overwritten for each event. A host clear command is also available
outside the timing window. Event processing does not overlap: diagnostic
distance readback must finish before a new event is released.

After the global sum is ready, PL requests each worker's cached 2,560 INT32
distances. The scheduler fences around the AIE readback gate are essential:
they prevent a matrix header from occupying the shared return path before all
densities have returned. No readback requests are issued before global timer
completion. Diagnostic matrices are retained in PL for register readback.

## Real data and qualification

The external fixture manifest identifies the unchanged compact-KAN checkpoint,
full embedding arrays and landmark selections for mixed events 187 and 393.
The four integrated trials are 187,393,187,393. Payloads contain 640 hit rows
(original IDs 0–639) followed by the original 128 landmark rows. Two columns
use IDs 0–319; four use 0–639. No hits are duplicated between tiles. Both sizes
therefore preserve the first full column's inputs from the earlier benchmark.
Generated fixtures, reports, binaries and exploratory scripts stay outside Git.

`rtl-test` checks exact input packets, all matrix storage, independent stream
backpressure, skewed column completion, reversed tile return order, AXI control
backpressure, input load guards, fresh-event sums and the precise timer endpoint.
Its response timing is test stimulus, not an AIE latency measurement.

`aie-gate-test` withholds all diagnostic requests and requires every density to
return with no matrix output. `aie-sim` checks every worker's distances and
counts against the independent scalar CPU reference for both distinct events.
`codegen` checks placement, routes, packet IDs and the optimized instruction
loops. `package` checks the actual packaged graph and interface and hashes the
measured system's components.

The integrated host compares all 128 final densities after completion. In
hardware emulation, `pl-trace` checks every input byte, every returned distance
and density count, and the observed global timer interval. It also verifies
simultaneous input starts, final reduction depth, and diagnostic traffic after
the timer has stopped. Full matrix reads via emulated AXI registers are avoided;
the trace contains every received matrix word and saves the verified matrices.
On a physical board, the host reads the matrices from PL registers instead.

The integrated model uses 1 GHz AIE and 300 MHz PL. Native AIE simulation uses
1.25 GHz and is used for correctness only. Integrated clock evidence is saved
from the generated model, and the PL period is checked against trace timestamps.
Hardware emulation results are not physical-board timing-closure measurements.

## Reproduction

With Vitis 2022.2, the VCK5000 platform and XRT configured:

```bash
source env.sh  # optional machine-local environment, ignored by Git
make -f array/Makefile rtl-test host COLUMNS=2
make -f array/Makefile aie COLUMNS=2
make -f array/Makefile aie-gate-test aie-sim COLUMNS=2
make -f array/Makefile xo link package COLUMNS=2
make -f array/Makefile emu pl-trace COLUMNS=2
# Repeat with COLUMNS=4; each stream topology requires its own linked system.
```

Defaults are `$HOME/aie-array-builds/cN`, `/dev/shm/aie-array-cN` for compiler
scratch, and `$HOME/aie-landmark-benchmark-data/array-real-mixed` for fixtures.
Override `BUILD`, `AIE_BUILD` and `DATA` as needed. Native qualification defaults
to the two unique fixtures; integrated emulation runs every fixture in the file.
Run large system links and emulations sequentially on memory-constrained hosts.

## Register map

The AXI-Lite aperture is 64 KiB, matching the VCK5000 linker allocation.
All addresses are byte offsets. Untimed matrix readback selects one tile at a
time; this keeps the complete control interface within one allocated segment.

| Address | Meaning |
|---|---|
| `0x0000` | Write 1: release all columns; write 2: clear final sums while idle |
| `0x0004` | Busy, global density complete, diagnostic complete, fault (bits 0–3) |
| `0x0008` | Compiled column count |
| `0x0010/14` | Global elapsed PL cycles, low/high |
| `0x0028/2c` | Column density/readback completion masks |
| `0x0034/38` | Signature `0x41525231`, squared radius 645 |
| `0x003c` | Diagnostic matrix selector: `column*8+row`, writable while idle |
| `0x0400+c*0x100` | Column TX/RX beat counts, tile density/readback masks (four words) |
| `0x0440+c*0x100` | 17 compiled routing headers: eight hits, landmarks, eight readback requests |
| `0x04a0+c*0x100` | Eight compiled output packet IDs |
| `0x2000` | 128 final UINT32 landmark densities |
| `0x4000+c*0x400` | 128 column partial sums |
| `0x8000+c*0x1000` | 576 resident words: 160 hit rows followed by 128 landmark rows |
| `0xc000..0xe7fc` | Selected tile's 2,560 INT32 distances, hit/landmark order |

Each column sends 153 timed input beats and receives 72 density beats per event.
Untimed readback adds eight request beats and 5,128 matrix beats, for total
column counts of 161 TX and 5,200 RX.
