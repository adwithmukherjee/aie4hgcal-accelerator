# One-column communication scaling

Build 1, 2, 4 or 8 workers in AIE column 24, starting at logical row 0. Each
worker processes **20 distinct hits against the same 128 landmarks**, all 8D
signed INT8. The full column therefore processes 160 hits and 20,480 distances.
The inclusive radius remains `distance_squared <= 645`. Each worker uses the
same arithmetic implementation as the single-tile benchmark in
`aie/density_core.hpp`, including local layout/norm preparation and the cached
INT32 distance matrix. PL norm/layout offload is a separate future experiment.

## Communication and timing

All workers share one 128-bit PL input and one 128-bit PL output at shim column
24. PL sends one landmark packet, which the AIE stream switches multicast to
each worker's landmark window, followed by one distinct hit packet per worker.
Each worker returns a packet containing 128 packed byte density contributions.
The shared return stream serializes packets; PL accepts any tile order and
adds contributions to 128 UINT32 landmark accumulators.

The only timer runs from **raw resident PL embeddings released** until **the
last tile's final density contribution is added in PL**. It includes input
serialization, multicast/distribution, local preparation, distance computation,
radius filtering, return arbitration and accumulation, including backpressure.
There are no kernel timers or timed acknowledgment packets.

After the global endpoint, PL sends a header-only readback request to each tile.
Only then may the tile transmit its cached 2,560 distances. This prevents an
early tile's diagnostic traffic from delaying another tile's density packet.
Scheduling separators bound the blocking request read: the compiler must not
move even the matrix header before it, because that header can reserve a shared
packet route while waiting for data. The generated-code guard checks this order.
CPU reference comparisons, input loading, accumulator clearing and distance
readback are outside the timer. Events do not overlap: this is a latency
experiment, not a measurement of sustained event throughput.

| Workers | Hits | Distances | Timed TX beats | Density RX beats |
|---:|---:|---:|---:|---:|
| 1 | 20 | 2,560 | 76 | 9 |
| 2 | 40 | 5,120 | 87 | 18 |
| 4 | 80 | 10,240 | 109 | 36 |
| 8 | 160 | 20,480 | 153 | 72 |

Counts are accepted 128-bit AXI beats, including packet headers and partially
valid final beats. Per event, timed traffic contains `1028 + 164*N` input bytes
and `132*N` output bytes. Untimed readback adds `N` input beats and `641*N`
output beats. Each build contains exactly N workers and multicast destinations;
compiler-assigned packet IDs are extracted rather than assumed to equal rows.

Compare scaling against the **packetized one-worker build** in this directory.
The earlier single-tile direct-stream benchmark has a different protocol and
is useful as a separate reference, not as the denominator for column scaling.
Keep all clock settings and fixture identities fixed across N. Hardware
emulation results must be labeled as such; they do not establish physical
board latency or PL timing closure.

## Data contract

The host/native tools consume compact 2,304-byte frames in `payloads.bin`:
160 consecutive hit embeddings (1,280 bytes), then 128 common landmark
embeddings (1,024 bytes). An N-worker build uses the first `20*N` hits. No hit
is duplicated across workers. `manifest.json` records event identity, selected
hit/landmark IDs and provenance. The real-event benchmark uses mixed events
187 and 393 in the sequence 187,393,187,393; landmark vectors are unchanged
from the single-tile experiment.

For the RTL test, `payloads.mem` contains the same little-endian 32-bit words.
`expected.mem` contains, for each event then row 0–7, 32 packed density words
followed by 2,560 row-major INT32 distance words. Fixture generation and raw
event/checkpoint artifacts remain outside this source repository.

## Reproduction

Load Vitis 2022.2, XRT and the site's license environment. The optional local
`env.sh` is ignored by Git. Build products, fixtures and results are external.
Build the shared PL image and qualify the full column first:

```bash
source ./env.sh
make -f column/Makefile rtl-test TILES=8
make -f column/Makefile aie aie-gate-test aie-sim host xo TILES=8
make -f column/Makefile link package TILES=8
make -f column/Makefile emu pl-trace TILES=8

for n in 1 2 4; do
    make -f column/Makefile aie aie-gate-test aie-sim host TILES=$n
    make -f column/Makefile package TILES=$n PL_BUILD=$HOME/aie-column-builds/t8
    make -f column/Makefile emu pl-trace TILES=$n
done
```

Override `TILES`, `BUILD`, `AIE_BUILD` and `DATA` as needed. By default the AIE
compiler scratch directory is `/dev/shm/aie-column-tN`; its completed outputs
are copied to `$HOME/aie-column-builds/tN/aie`. System linking and emulation
results remain under the latter build directory. Run integrated emulators
sequentially on the same emulated device.

The PL implementation is identical across tile counts. Once the eight-tile
system is linked, other AIE graphs can reuse that XSA: compile and qualify the
new AIE graph and host, then run `package` with
`PL_BUILD=$HOME/aie-column-builds/t8`. Both PLIOs are fixed at column 24, channel
0, with unchanged names, widths and clocks. Packaging verifies these fields
against the linked interface and records XSA/AIE archive hashes. This follows
AMD's [post-link AIE recompile flow](https://raw.githubusercontent.com/Xilinx/Vitis-Tutorials/2022.2/AI_Engine_Development/Feature_Tutorials/15-post-link-recompile/DirectRecompileMakefile_Flow.md).

`codegen` checks each actual worker placement, local buffers, column routing,
native distance-loop schedule and absence of scalar transpose fallbacks.
`aie-sim` compares every returned density and distance with the integer CPU
reference. The RTL test exercises all four sizes, reverse-order returns,
backpressure, nonzero initial sums, load guards and the single timer endpoint.
The integrated host verifies the accumulated densities through register reads.
In hardware emulation, `pl-trace` compares every returned matrix word with the
CPU reference using the captured PL RX stream, avoiding thousands of slow
diagnostic register transactions. It also verifies packet contents, timing
boundaries, the frozen timer during readback and the measured PL clock.
The RTL test separately checks all matrix storage addresses; the physical-board
host path additionally reads and verifies the stored matrices through registers.
`aie-gate-test` withholds all readback requests in native simulation, runs for
25,000 AIE cycles, and requires all density packets with no matrix output.
This catches premature headers hidden by prequeued tokens.
Withholding requests occurs only in the qualification fixture; integrated
benchmark requests follow the actual global density endpoint immediately.

Results are written to `system/results/validation.json`, with clock evidence
in `system/clock_evidence.json`. Native AIE simulator timestamps are not the
reported end-to-end latency: use the integrated PL counter and trace.
