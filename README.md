# Single-tile distance and landmark-density benchmark

The [one-column benchmark](column/README.md) extends this implementation to
1, 2, 4 and 8 workers with shared packet transport and PL density accumulation.
The [parallel-column benchmark](array/README.md) adds two and four full columns,
independent streams, and a timed final PL reduction across columns.

For 20 hits and 128 landmarks, each an 8D signed INT8 embedding, compute all
2,560 squared distances, cache them as INT32, and count hits satisfying
`distance_squared <= 645` for each landmark. This is the agreed inclusive
radius 0.2 at the ×127 embedding scale. AIE returns each landmark's contribution
from these 20 hits; PL accumulates the contributions in 128 UINT32 counters.

One PL timer measures **resident input register release → final contribution
added into PL**. There are no AIE cycle reads, checksum passes, input headers,
acknowledgment packets, instrumentation events, or sub-stage timers.
Input loading and CPU correctness checks run outside the timer.

## Computation and storage

The AIE1 kernel uses `aie::mmul<4,8,4,int8,int8,acc48>` for 160 distance blocks.
It computes actual hit and landmark squared norms, then applies
`norm_hit + norm_landmark - 2*dot`. INT32 results safely cover all signed INT8
coordinates, including the maximum squared distance 520,200. The kernel
transposes blocks using three explicit native SIMD shuffles on widened INT16
lanes, with packed loads/stores. It never calls the AIE1 scalar transpose or
byte-interleave fallback. All layout preparation remains in the timed stage.
Compact INT32 norm tables feed native broadcast-and-add instructions. The
two norm operands share one vector operand, and accumulator conversion with
shift -1 produces `2*dot` directly. Comparing `645 >= distance_squared` keeps
the inclusive radius while avoiding a predicate inversion in generated code.
The installed AIE1 compiler schedules each distance block in 13 instruction
bundles, with no explicitly marked spill instructions. Four stack-relative
loads remain per iteration; this is not a claim that the loop has no reloads.
The 32-block inner loops are software pipelined. A 1 KiB constant table converts
two rows of radius predicates into four byte counts; two lookups reduce a
4×4 block without scalar per-hit loops or large temporary vectors.

The worker is pinned to tile `(24,0)`, input SRAM to address `0x6000` on that
tile, and runtime/stack memory to bank 0 on the same tile. The stack reserves
16 KiB and contains the 10,240-byte distance cache, 1,024 bytes of transposed
landmarks, compact norms and packed counts; 2 KiB of heap/runtime storage is
also reserved. The cache is blocked as `[hit_block][landmark_block][4][4]`
for contiguous vector stores. Readback restores the original row-major order
after the timer stops.
Compiler reports must confirm the resulting placement and stack requirements.

The first fixtures are the same compact-KAN real mixed validation events
187 and 393 used for the transport benchmark. The sequence is 187,393,187,393.
Each payload contains original hit IDs 0–19 and landmark IDs
`floor(j * full_event_hits / 128)`. Payload bytes and hashes are unchanged;
only the former transport header has been removed. Separate functional fixtures
exercise distances 644/645/646, identical coordinates, and signed extremes.
Those arithmetic fixtures are not used for the reported real-event latency.

## Wire protocol and timer

The input is exactly 1,184 bytes: 20 contiguous hit rows followed by 128
contiguous landmark rows, with eight signed bytes per row. It occupies
74 complete 128-bit AXI-stream beats. No metadata is transmitted to AIE.

The output starts with 128 unsigned-byte density contributions in landmark
order. Each value is in `[0,20]`; four are packed little-endian into each
32-bit AIE stream word, forming eight 128-bit beats at PL. On each accepted
beat, PL adds 16 contributions to their corresponding UINT32 accumulators.
The final additions and timer stop occur on the same clock edge.

The 2,560 row-major INT32 distances follow as 640 more beats for correctness
readback. PL accepts their first beat after the timed density endpoint and
keeps the timer frozen throughout readback. The input buffer remains locked
until AIE finishes sending these distances, so a later event waits for readback
completion. This benchmark measures latency, not overlapping-event throughput.

The host clears the accumulators before each new event, loads the resident
registers, and releases them. The counter starts at zero on the release edge
and increments every PL edge until the last density accumulation, including
stalls. The clear command is separate so further contributions can be added
without resetting sums; the RTL test exercises accumulation onto nonzero sums.
Full-word input loads and rejection of writes while busy prevent stale data.
These checks do not add a validation pass to the AIE computation.

## Correctness and reproduction

Load your site's Vitis 2022.2 and XRT environment, including its license setup,
before running these commands. A local `env.sh` may provide this setup; it is
ignored by Git because it contains machine-specific paths and license settings.
The emulator launcher loads that helper when present, otherwise it uses the
calling shell's environment.

```bash
cd /home/adwith_mukherjee/aie4hgcal-accelerator
if [[ -f env.sh ]]; then source env.sh; fi
make rtl-test host
make aie
make aie-sim
make xo link package
make emu
make pl-trace
```

Default build scratch is `/dev/shm/aie-landmark-density`; default data is
`$HOME/aie-landmark-benchmark-data/density-real-mixed`. Both can be overridden
with `BUILD` and `DATA`. Data generation, datasets, scratch analysis, generated
builds, logs, and reports remain outside this checkout.

`aie-sim` compares all 2,560 distances and 128 counts against an independent
scalar CPU reference for every event. Set `DATA` to the separate arithmetic
qualification directory to exercise signed extrema and radius boundaries.
It does not report sub-stage timing or collect AIE event traces.

`codegen` checks the actual ELF instruction listing before system linking:
no scalar reshape fallback, no out-of-line kernel calls, no explicitly marked
spills in the distance loop, and at most 13 scheduled issue bundles per 4×4
distance-loop iteration. Its JSON record also counts stack-relative loads and is
compiler evidence, not a substitute for measured end-to-end latency or runtime
stall accounting. The full PL timer remains the performance measurement.
`pl-trace` also requires every full-stage event to complete within 4,000 ns.
The report records correctness and performance separately and fails if either
fails. `MAX_LATENCY_NS` can be set explicitly for a different experiment;
the default regression limit is 4 µs at this benchmark's clocks and shape.

`rtl-test` exercises the real input/reference fixtures, AXI and stream
backpressure, load guards, nonzero accumulation, every distance readback word,
and the final accumulation timer endpoint against independent timestamps.
Its simulated AIE response delay is stimulus, not a measured AIE result.

The integrated host reads and compares all 128 accumulated PL densities.
`pl-trace` independently compares every transmitted input byte, returned
density, and returned distance against the scalar reference. It checks the
counter against the observed release/final-accumulation edges and checks that
the timer remains frozen during distance readback. This uses one PL timebase;
no PL/AIE timestamp correlation or estimated return latency is needed.

This platform's integrated hardware emulator uses a 1.0 GHz AIE model, while
standalone AIE simulation uses 1.25 GHz. The PL timer's frequency is checked
from RTL timestamps and a one-cycle release pulse. The generated integrated
AIE clock model is retained at `BUILD/system/ai_engine.cpp`. Report integrated
emulation and physical-board measurements distinctly.

The VCK5000 PMC starts the graph during PDI load; no host graph-control call
is required. The existing launcher creates missing DRAM backing files as sparse
zero-filled files before simulation to avoid the platform's 14 GiB zero-write
startup exceeding XRT's connection timeout. It preserves existing backing files
and does not alter simulated logic. The original transport kernel's packaged IP
name `transport_pl` is retained to reuse the tested platform interface.

## Register map

| Byte address | Meaning |
|---|---|
| `0x0000` | Write 1: release input; write 2: clear density accumulators while idle |
| `0x0004` | Status: busy, density complete, readback complete, fault (bits 0–3) |
| `0x0010/14` | Full-stage elapsed PL cycles, low/high |
| `0x0020`, `0x0024` | Accepted RX and TX beat counts |
| `0x0034` | Register-map signature `0x44454e31` |
| `0x0038` | Squared-radius threshold, 645 |
| `0x1000..0x149c` | 296 resident input words |
| `0x2000..0x47fc` | 2,560 INT32 distance readback words |
| `0x5000..0x51fc` | 128 UINT32 accumulated landmark densities |

The implementation follows the installed Vitis 2022.2 AIE1 API; AMD documents
its supported matrix shapes in the [2022.2 matrix API](https://download.amd.com/docnav/aiengine/xilinx2022_2/aiengine_api/aie_api/doc/group__group__mmul.html)
and the accumulator conversion's −1..62 shift range in the
[2022.2 SRS intrinsics](https://download.amd.com/docnav/aiengine/xilinx2022_2/aiengine_intrinsics/intrinsics/group__intr__gpvectorconv__srs.html).
Runtime placement follows [reserved-memory constraints](https://docs.amd.com/r/2022.2-English/ug1079-ai-engine-kernel-coding/Reserved-Memory-Constraint).
