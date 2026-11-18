# Four-column landmark clustering

This extends the qualified density benchmark through PL seed selection, seed-ID
multicast, cached AIE assignment, and original-order label storage in PL. It uses
four independent 128-bit input/output pairs, 32 tiles in columns 24–27, 20 distinct
8D INT8 hits per tile, and the same 128 landmarks from the density experiment.

The single timer starts when raw resident PL hit/landmark registers are released
and stops on the edge storing the final hit label in PL. It includes AIE layout
and norm preparation, distances and density filtering, all communication, global
PL density reduction, seed selection, assignment, and label capture. CPU checks
and host input loading are outside this interval. Landmark sampling/gathering is
also outside this benchmark: fixtures supply the unchanged full-event landmarks.

## Algorithm

* Density counts hits with inclusive squared distance <= 645.
* Candidates are ranked by decreasing density, then increasing original hit ID.
  Landmark slots must be in increasing original hit-ID order; the host checks this.
* Candidates require `5*density >= maximum_density`.
* A seed must have squared distance >= 3267 from every earlier accepted seed.
  At most 64 seeds are retained; an overflow flag indicates additional qualifying
  candidates. All-zero densities still select at least one landmark.
* Every hit is assigned to its nearest selected seed using exact cached INT32
  distances. Equal distances favor the earlier seed. There is no assignment-radius
  rejection, noise label, centroid update, or iterative refinement.
* Outputs are 640 byte labels, 128 UINT32 densities, selected landmark slots, and
  a table mapping cluster labels to original seed hit IDs.

The PL selector implements the greedy rule without materializing a sorted list:
128 parallel separation lanes first prepare a 128 x 128-bit proximity table
while AIE computes densities. Preparation starts at the same input-release edge
as the timer and takes 896 PL clocks (seven clocks per row). Each lane processes
two coordinates per clock through subtraction, square, and accumulation stages.
The seven-stage maximum tree then selects the best unsuppressed candidate; a
synchronous table read supplies its suppression mask on the next clock. Selection
waits for the current event table if densities arrive early. Every row is
overwritten each event, and no precomputation is moved outside the timer. AIE
prepares the nearest 32 landmarks per hit after emitting its density packet and
before reading the seed packet. Native 32-bit compare/shuffle operations sort
packed `(squared_distance << 7) | landmark_slot` keys; four sorted blocks of 32
are merged while retaining only the nearest 32. A block is skipped only when its
smallest packed key cannot enter the current nearest-32 set. The exact distance cache remains
intact. Preparation is inside the timer and can overlap PL selection; any excess
preparation time remains on the critical path.

After seeds arrive, a 128-entry slot-to-label table supports an early-exit search
through each shortlist. The entire nearest selected distance group is checked
to preserve seed-order ties. A missing seed or a winner at the shortlist cutoff
invokes the original four-hit vector scan, so an omitted equal-distance seed
cannot change the answer. The slowest tile still determines full-event latency.
The fallback uses unrolled 1–3-seed handling or the pipelined larger-seed loop.
The native sorting and merging functions store intermediate halves explicitly
in SRAM so separate networks can reuse AIE1 vector registers. Code-generation
checks reject scalar shuffle helpers, unexpected calls, and spills inside those
networks. They retain the 13-bundle density and 12-bundle fallback loop limits
and report the preparation control code, including call and spill overhead.
The 20 KiB stack reservation is checked against the complete dispatcher, kernel,
preparation, and network call chain using each tile’s linker map.
All helper execution and SRAM traffic remain inside the same benchmark timer.
No distance matrix is copied back to PL; the cache remains on AIE for assignment.

## Forced 64-seed latency benchmark

Normal clustering remains the default. Writing `1` to register `0x0040` while
idle enables a stress mode that selects exactly 64 distinct landmarks in density
rank order, with the same original-hit-ID tie rule. It bypasses the density
cutoff and separation rejection, while retaining all 64 selection iterations
and the complete 128-row separation-table preparation. No seeds are preselected on
the host. The mode is latched for selection and cannot be changed while busy.
All 32 AIE tiles receive the same 64 IDs and assign their 20 hits against them.

This is a workload stress test, not a reconstruction-quality result. The cap
overflow flag is set because 64 other candidates remain under the forced rules.
There can be fewer than 64 nonempty clusters even though 64 seeds are selected.
The normal timing endpoints and all communication stay inside the sole timer.

Use `SEED_MODE=force64` for `emu` and `pl-trace`, or pass `--force-64` as the last
argument to `array_host`. Results are kept in `system/results-force64`; normal
mode uses `system/results-normal`. Runtime directories also distinguish modes.

Each column multicasts one seed packet to all eight workers. The packet contains
a header, seed count, and four byte-sized landmark slots per subsequent word.
Each worker returns a header and five words containing its 20 byte labels.
AIE scheduler fences prevent any label packet from preceding the seed request.
The four column receivers gather independently, including under backpressure.

## Validation and reproduction

Use Vitis 2022.2 and the VCK5000 QDMA platform. `COLUMNS=4` is required. Paths can
be overridden with `BUILD`, `AIE_BUILD`, and `DATA`. `AIE_JOBS=2` limits
concurrent ELF compiler workers to avoid exhausting the build VM memory. The source uses separate
clustering build/runtime directories, preserving the earlier density artifacts.

```bash
source env.sh
export DATA=$HOME/aie-landmark-benchmark-data/cluster-real-mixed
# DATA initially contains the original four density payloads/manifest/RTL oracle.
python3 array/tools/clustering_reference.py "$DATA" "$DATA"
python3 array/tools/clustering_reference.py "$DATA" "$DATA" --force-64
make -f array/Makefile seed-test rtl-test host xo
make -f array/Makefile aie
make -f array/Makefile aie-gate-test aie-shortlist-test aie-sim aie-force64-test
make -f array/Makefile link package
make -f array/Makefile emu pl-trace
# Or stress exactly 64 selected seeds on the same real inputs:
make -f array/Makefile emu pl-trace SEED_MODE=force64
```

The selector test covers normal/forced transitions, all 128 exact mask rows,
density arriving before/after table readiness,
threshold equality, density ties, signed endpoints,
duplicate landmarks, zero densities, 64-seed saturation, and repeated events.
The RTL system test checks independent backpressure, skew, reverse tile return
order, seeds, seed identities, labels, load guards, and the exact final-write
counter endpoint. Native AIE tests cover real event-derived seeds, withholding
seed packets, and 64 supplied seed IDs on real embeddings plus a synthetic all-tied event. The shortlist qualification also covers an empty shortlist intersection, a
winning tie outside the cutoff, seed-order ties inside the shortlist, and signed
INT8 extremes. `aie-force64-test` checks the real density-ranked 64-seed lists
against the CPU oracle, outside the integrated performance run. Native checks
establish correctness; their timestamps are not the PL-to-PL benchmark.
The integrated host independently computes every final output using scalar CPU
integer arithmetic; the trace checker also verifies every stream payload and
the complete timer interval. No substage timers are added.

The unchanged fixtures are mixed events 187 and 393, repeated in that order.
They contain hits 0–639 and the same full-event landmarks; their expected seed
counts are 2 and 3. This is a fixed-input hardware benchmark, not a full-event
reconstruction-quality evaluation. Native AIE simulation targets 1.25 GHz;
integrated emulation uses the separately verified model clock (previously 1 GHz
AIE and 300 MHz PL). Emulation does not establish physical timing closure.

## Register map

The control aperture remains 64 KiB. All offsets are bytes.

| Address | Meaning |
|---|---|
| `0x0000` | Write 1: release; write 2: clear densities while idle |
| `0x0004` | Busy, density done, cluster done, fault, cluster done, seeds done (bits 0–5) |
| `0x0008` | Column count (4) |
| `0x0010/14` | Complete latency in PL clocks, low/high |
| `0x0028/2c` | Column density/label completion masks |
| `0x0034/38` | Signature `0x434c5332`, density squared threshold 645 |
| `0x003c` | Seed count (bits 0–6), overflow (bit 7) |
| `0x0040` | Read/write seed mode while idle: 0 normal, 1 force 64 |
| `0x0400+c*0x100` | Column TX/RX beats, tile density/label masks |
| `0x0440+c*0x100` | Ten compiled routing headers: eight hits, landmarks, seeds |
| `0x04a0+c*0x100` | Eight compiled output packet IDs |
| `0x1000..0x127f` | 640 labels packed four per word, original hit order |
| `0x2000..0x21ff` | 128 global densities |
| `0x2400..0x243f` | 64 selected landmark slots, four bytes per word |
| `0x2500..0x25ff` | 64 original seed hit IDs (unused entries zero) |
| `0x3000..0x31ff` | Load 128 original landmark hit IDs before each release |
| `0x4000+c*0x400` | 128 column partial densities |
| `0x8000+c*0x1000` | 576 resident words: column hits then shared landmarks |

Per column, input traffic is 153 initial beats plus
`ceil((2+ceil(seed_count/4))/4)` seed beats. Output is 72 density beats and 16 label
beats. All of these transfers occur inside the timing window.
