# Streaming PL KAN into the 32-tile AIE clusterer

This experiment joins the [64-lane integer KAN](../kan/README.md) to the
existing [four-column AIE clusterer](../array/README.md). Each release computes
8,000 four-byte raw input slots in PL, captures all 8,000 eight-byte embeddings,
and streams 640 hit embeddings plus 128 landmark embeddings into 32 AIE workers.
Inputs are raw features, identities and routing metadata; no embeddings are
uploaded. This is a fixed-size first integration experiment.

The qualified graph uses four columns of eight workers, with 20 hits per worker.
That is the configuration being reused, not a demonstrated emulator tile limit.
Expanding clustering to all 8,000 hits is subsequent work.

## Pipeline and timing boundary

The 8,000 raw words reside in the encoder's registers before release. Fixed
landmark identities and the raw-slot ordering are also configured beforehand.
The first 128 slots hold the landmarks; the remaining required hits follow,
then the rest of the event. An explicit inverse map restores the original
640-hit order at the packetizers and original hit identities at seed selection.
A hit that is also a landmark is encoded once and read by both roles.

The 64-lane encoder has no dependency on downstream ready. Its full-event output
is captured in 64 banks. Only the first 768 slots are additionally replicated
into four independently read column caches, with one write and one read per
bank. A 12-bit availability vector releases each 64-slot group as it arrives.
The first column payload can therefore leave before the last embedding exists.
The cache also lets AIE backpressure extend communication without stalling or
discarding the remaining encodings.

Each memory read fetches two complete eight-byte embeddings. A one-word
gearbox packs the header with the first three payload words, then carries the
fourth word into the next beat. Every interior PLIO beat is full width; only
the last beat is partial. Two arbitrary hit sources that share a bank use an
extra read cycle; other pairs can issue every cycle. The elastic output stage
holds data, keep and last stable under backpressure. Broadcast landmarks are
contiguous and use different banks within each pair.

PL seed geometry preparation begins after both landmark groups are available.
The existing two-stage density reduction, seed selector, AIE distance cache
and exact assignment are unchanged. Normal seed selection and the forced
64-seed stress mode use the previous clustering thresholds and identity rules.
The compiled AIE archive and its packet routes are verified against the
provenance manifest at commit `42546581b4cbf7ac4db8fc55b7284ba2b0363b50`.

The global timer starts when raw-register release is accepted and stops on the
last AIE label capture, after all 8,000 embeddings have been captured. This
includes KAN evaluation, landmark gathering, all streaming, PL seed geometry,
density reduction and seed selection, AIE computation, and return traffic.
Raw loading, fixed landmark sampling, raw ordering and host readback are outside
this boundary. The encoder has a separate counter for its own release-to-capture
interval. Hardware emulation does not establish physical resource fit or
timing closure.

## Real-event fixtures

`tools/fixtures.py` reconstructs raw packed inputs from the archived real-event
records, verifies their full-event embeddings against the existing benchmark,
and preserves the prior 640-hit/128-landmark payload byte for byte. It generates
independent integer KAN and clustering references outside the repository.

Event 187 contains 8,222 real hits; the fixture encodes 8,000 distinct real hits
including every required hit and landmark. Event 393 contains 7,793 real hits;
its last 207 slots are explicitly zero padded and are not sent to AIE. Native
RTL validation uses both events in both seed modes. The full platform host uses
event 187 in both modes and reads back all 8,000 embeddings on each release.
These are functional and latency experiments, not a new clustering-quality or
F1 evaluation on 8,000 clustered hits.

## Qualified hardware-emulation results

VCK5000, Vitis/XRT 2022.2; waveform-verified 300 MHz PL and generated 1 GHz AIE
model. Event 187, with 8,000 distinct real raw hits encoded and 640 hits clustered:

| Seed mode | Seeds | Raw release to final label | PL cycles |
|---|---:|---:|---:|
| Normal | 2 | 6.073334 µs | 1,822 |
| Forced 64 | 64 | 7.626667 µs | 2,288 |

In both modes the first embeddings are captured at cycle 13 (43.334 ns),
the first AIE-bound payload is accepted at cycle 15 (50 ns), and all 8,000
embeddings are captured at cycle 137 (456.667 ns). The last hit/landmark input
is accepted by all columns at 613.334 ns in normal mode and 616.667 ns in
forced mode. Seed-control and return packets follow inside the global timer.

Both complete runs passed every embedding, packet, density, seed slot,
original seed identity and label comparison. Independent waveform checks
passed for clock edges, final-label capture, stalled-beat stability and
streaming overlap. The four native real-event/mode regressions also passed.
No OOM occurred; heavy stages ran sequentially. These are emulation results;
physical implementation and resource fit remain unqualified.

## Reproduce

Use the same Vitis/XRT 2022.2 VCK5000 environment as the existing clusterer.
Build outside the source tree and run the following stages sequentially.
The existing qualified AIE archive avoids compiling the 32 workers again.

```sh
source /home/adwith_mukherjee/aie4hgcal-accelerator/env.sh
export BUILD=/home/adwith_mukherjee/kan-cluster-build
export TABLES=/path/to/pinned/tables.npz
export AIE_ARCHIVE=/home/adwith_mukherjee/aie-landmark-benchmark-runs/vector-assignment-20261118-4254658
make -C kan_cluster BUILD="$BUILD" TABLES="$TABLES" generate

python3 kan_cluster/tools/fixtures.py \
  /path/to/real-mixed/source-events.tar.gz \
  /path/to/real-mixed/manifest.json \
  /path/to/four-column-fixtures/manifest.json \
  /path/to/cuts.h "$TABLES" "$BUILD/data"

make -C kan_cluster BUILD="$BUILD" rtl-test
make -C kan_cluster BUILD="$BUILD" AIE_ARCHIVE="$AIE_ARCHIVE" stage-aie
make -C kan_cluster BUILD="$BUILD" xo host
make -C kan_cluster BUILD="$BUILD" link
make -C kan_cluster BUILD="$BUILD" package
make -C kan_cluster BUILD="$BUILD" emu
make -C kan_cluster BUILD="$BUILD" verify
```

The pinned table SHA256 is
`b7856fb8e0e999a1fba6a2890f83a5eea89454a6bd3b434d7303d9923f640317`.
The exporter rejects a different model. `DATA` defaults to `$BUILD/data`.

The default simulation uses direct simulator access for resident raw-register
setup and completed capture-RAM readback, outside the timer. Each deposited raw
register is read back before release. After completion the simulator reads all
64 capture RAM banks without modifying them. The host checks all 8,000 outputs
against the independent oracle, plus nine boundary/bank addresses through AXI.
Metadata, release, status, densities, seeds and labels use actual AXI accesses.
Every KAN operation and PL/AIE packet runs through the compiled design.

Set `KAN_CLUSTER_SIM_MEMORY=0` for full raw-loading and embedding-readback MMIO.
That mode is much slower in the 32-tile model. Native RTL tests cover the full
AXI raw-load and capture-read paths for both real events and both seed modes.

The native regression applies independent column backpressure, checks every
packet word and held beat, and supplies reference density/label replies in
skewed worker order. It checks all captured embeddings, densities, seed slots,
original seed identities, labels, partial-load rejection and timer endpoints.
Those native replies model AIE results; the platform simulation uses the actual
compiled 32-worker AIE graph. Its waveform checker independently verifies every
accepted encoding and TX/RX packet, streaming overlap, stable stalled payloads,
host dumps, direct clock edges and the final-label timer boundary. Clock
evidence is retained from the generated AIE model.

Keep one heavy compiler or emulator active at a time. Platform stages check
for at least 16 GiB available RAM and 6 GiB free disk before starting. Vivado
and XSim are limited to two workers. These checks measure current headroom;
they do not reserve resources against other jobs. Completed emulator runtime
and link scratch can be removed after preserving results and packaged designs.

## Physical hardware build

`TARGET=hw` selects the physical VCK5000 flow. The default remains `hw_emu`.
The hardware flow reuses the hash-verified hardware-targeted AIE archive and
runs synthesis, implementation and packaging through Vitis 2022.2:

```sh
source /home/adwith_mukherjee/lab3/env.sh
make -j1 -C kan_cluster BUILD=/absolute/hardware/build TARGET=hw hardware
```

Prepare the pinned generated ROMs in that build directory first, as in the
reproduction instructions. Keep the hardware build separate from emulation.
Defaults are one synthesis job, one implementation job and two maximum Vivado
threads. Hardware builds omit emulator clock-model extraction and `emconfigutil`.
Successful emulation does not establish physical fit or timing closure.

On the original 32 GB VM, run the build inside a system-level systemd service
with `MemoryAccounting=yes`, `MemoryMax=24G` and `KillMode=control-group`, using
the normal user account. Verify `memory.limit_in_bytes` on the actual memory
controller: user-level systemd units on this VM do not enforce that controller.
The build watchdog is invoked inside that service:

```sh
python3 kan_cluster/tools/watch_build.py \
  --build /absolute/hardware/build --lock "$HOME/.fpga-build.lock" \
  --reserve-memory-gib 6 --max-anon-gib 22 --min-free-disk-gib 2 \
  -- /bin/bash /absolute/build-driver.sh
```

The driver sources the lab environment and invokes the hardware target above.
The watchdog samples every second, holds a shared build lock, refuses to start
alongside an existing compiler/emulator, and stops its own process tree when
a configured resource threshold is reached. `guard-state.json` and
`memory.csv` retain current status, resource peaks and stop reasons. These soft
stops supplement the independently enforced 24 GiB limit. The hard limit can
terminate the build if allocation grows faster than the watchdog can react.

The host supports physical execution with `XCL_EMULATION_MODE` and
`KAN_CLUSTER_SIM_MEMORY` unset. That path uses the physical XRT backend and full
AXI loading/readback, with no simulator memory access. Physical execution is
still unqualified until run on a matching card-equipped host.

## Control map

The kernel is user managed with an 18-bit, 256 KiB AXI-Lite aperture.

| Offset | Purpose |
|---|---|
| `0x0000` | Write 1: release; write 2: clear raw/role loading |
| `0x0004` | Status bits: busy, density done, cluster done, fault, encoder finished, seeds ready, landmarks ready |
| `0x0008`, `0x000c` | Lane count 64; raw slot count 8,000 |
| `0x0010`, `0x0014` | Global elapsed cycles, low/high |
| `0x0018` | Encoder elapsed cycles |
| `0x001c`, `0x0020`, `0x0024` | Raw words loaded; roles loaded; embeddings captured |
| `0x0028`, `0x002c` | Completed column density/label masks |
| `0x0034`, `0x0038` | Signature `0x4b434c31`; squared density radius 645 |
| `0x003c`, `0x0040` | Seed count/overflow; forced-64 mode |
| `0x0400 + c*0x100` | Column TX/RX beat counts and worker masks |
| `0x0440 + c*0x100` | Ten compiled TX route headers |
| `0x04a0 + c*0x100` | Eight compiled RX worker IDs |
| `0x1000` | 640 packed byte labels |
| `0x2000` | 128 global uint32 densities |
| `0x2400`, `0x2500` | 64 byte seed slots; 64 uint32 original seed IDs |
| `0x3000` | 128 uint32 original landmark IDs, configured before release |
| `0x4000 + c*0x400` | 128 partial uint32 densities |
| `0x8000` | Sequential 8,000-word raw load aperture |
| `0x10000` | 8,000 captured uint64 embeddings, readable after completion |
| `0x20000` | Sequential 768-word role map |

A role word contains hit index in bits 9:0, landmark slot in bits 16:10, hit
present in bit 17 and landmark present in bit 18. Upper bits must be zero.
The first 128 words identify the corresponding landmark slots. Every hit and
landmark role must occur exactly once before a release is accepted. Route
configuration can be reused between events; clearing raw loading requires
reloading role and landmark identities. Releasing the same resident raw event
again supports changing the seed mode without a reload.
