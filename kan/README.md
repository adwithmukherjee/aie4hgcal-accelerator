# Streaming compact KAN in PL

This is the selected epoch-6 **4 → 12 → 8** encoder associated with the
66.2244% mixed-validation top-8000 landmark result. It consumes an already
encoded four-byte hit and emits eight signed INT8 coordinates. Clustering,
raw-feature encoding, landmark selection, and PL-to-AIE transport are external.

The model export is pinned to SHA256
`b7856fb8e0e999a1fba6a2890f83a5eea89454a6bd3b434d7303d9923f640317`.
Generated RTL, ROM images, vectors, logs and implementation results live outside
Git. The exporter rejects any other table file. No retraining or pruning occurs.

## Datapath and interface

`tools/export.py` emits one synchronous distributed-ROM lane with balanced,
explicitly signed pipelined addition trees. A hit uses four input-byte lookups
with 12 responses each, then 12 hidden-address lookups with eight responses each.
The tables total 18,432 bytes logically per lane; physical LUT mapping differs.

The first layer sums four signed bytes, then computes
`clip(floor((sum + 2)/4), -31, 31) + 31` as the hidden address. Address 63 is
unreachable. The second layer sums 12 signed bytes and saturates to [-127,127].
Byte 0 is the least-significant byte, for both inputs and outputs. The input
bytes are codes: signed x/y interpretation and layer/energy preprocessing are
already folded into the exported first-layer tables. No decoding arithmetic
or floating-point normalization belongs in this core.

`kan_stream` accepts `LANES` hits per group, with ten registered stages and an
initiation interval of one cycle when the consumer is ready. Lane l represents
hit `base_id+l` when mask[l] is set. `last` marks the final group of an event.
The output preserves order and carries the same base ID, mask and last flag.
The event wrapper uses resident-slot IDs (0 through N-1). If upstream hit
selection produces noncontiguous original detector-hit IDs, the transport
adapter must retain the slot-to-original-ID mapping; the base ID is not that
external identity. This mapping can remain separate from KAN arithmetic.
Invalid-lane output values are unspecified. A synchronous active-low reset
flushes all valid state; datapath registers and ROMs do not require resetting.

Transfers occur on valid && ready. Producers must hold the complete input
payload while stalled. When a valid output stalls, all lane datapaths and
metadata freeze together; output data remains stable. Each group has independent
flow control and may be instantiated independently for a future wider design.
No global serializer, AIE packet format, or whole-event output buffer is imposed.

## Resident input wrapper

`kan_event` defaults to 8,000 raw hits in PL registers (256,000 payload FFs).
Test loading uses a sequential valid/ready four-byte port while idle. Loading
is outside the event timer. `clear_load` while idle clears the loaded count,
allowing a replacement event; raw storage is not reset or erased. Writes and
clear requests cannot modify a busy event. Reset aborts work and invalidates
the loaded count, so inputs must be reloaded afterward.

`start_valid && start_ready` latches event_count. A start requires a nonzero
count <= MAX_HITS and <= loaded_count. The loaded prefix can be replayed without
reloading. The wrapper processes exactly that prefix, in original order, and
masks unused lanes in its final group. Busy remains asserted until the final
embedding group is accepted. `done` pulses on that edge, and `cycles` freezes
at the number of clocks from start acceptance to final output acceptance,
including every stall. Host loading, readback and future AIE transport are excluded.

Hit i resides in lane bank i % LANES at row floor(i/LANES). Each bank uses a
registered radix-16 selection tree: no read stage selects more than 16 words.
This keeps the raw-register selection path separate from the KAN lookup path.
The register read adds ceil(log16(ceil(MAX_HITS/LANES))) stages (at least one),
while preserving one group per cycle. Pipeline selection registers are additional
storage, not part of the 256,000-bit raw payload count.

For a continuously ready consumer, the wrapper takes
`ceil(event_count/LANES) + READ_STAGES + 10` cycles. With MAX_HITS=8000,
one lane has four read stages; two lanes have three. These are RTL cycle counts,
not physical-board latency measurements.

The wrapper's test loading port is not a proposed production ingress. Its
output can connect to a test capture sink or a future transport adapter. Hit
identity makes later destination mapping and landmark capture possible without
changing KAN arithmetic. Transport bandwidth, landmark availability/order and
full-array AIE storage/placement remain separate integration work.

## Reproduce

Export locally with Python and NumPy, using the selected external tables:

```bash
make -f kan/Makefile generate BUILD=/absolute/build/path \
  TABLES=/absolute/path/to/runs/compact/tables.npz PYTHON=python3
```

With the clustering project's Vitis/Vivado 2022.2 environment on PATH:

```bash
make -f kan/Makefile test BUILD=/absolute/build/path LANES=1
make -f kan/Makefile test BUILD=/absolute/build/path LANES=2
```

Tests cover 8,000 exact vectors (including independent sweeps of all 256 values
in every input channel), input bubbles, prolonged/random backpressure, stable
stalled payloads, ten-stage latency and II, reset during in-flight work,
repeated events, odd tails, empty/oversized/unloaded start rejection, loading
protection and full-capacity register reads. The scalar oracle accumulates with
Python integers and was separately compared with the selected PyTorch integer
export. Event checks include the final acceptance edge of the cycle counter.

Optional internal-core implementation or full-wrapper synthesis:

```bash
vivado -mode batch -source kan/tools/implement.tcl -tclargs \
  /absolute/source/kan /absolute/build/path/generated /absolute/output \
  xcvc1902-vsvd1760-2MP-e-S 2 kan_stream 1
# Replace kan_stream 1 with kan_event 0 for wrapper synthesis only.
```

The script constrains 3.333 ns with 0.100 ns clock uncertainty before synthesis.
External input/output paths are explicitly excluded because no adapter timing
contract exists yet. Routed setup/hold results therefore qualify internal
register paths only. This optional flow requires a device synthesis license.
Physical timing closure and resource fit have not been established by the
standalone RTL tests or hardware-emulation benchmark.

## Qualified emulation results

Vitis/XRT 2022.2, VCK5000 hardware emulation at nominal 300 MHz:

| Lanes | Raw hits | Release to final local capture | PL clocks |
| --- | ---: | ---: | ---: |
| 64 | 8,000 | 0.456667 µs | 137 |
| 128 | 8,000 | 0.250000 µs | 75 |

Each configuration passed 33-hit, full 8,000-hit, stalled-sink 8,000-hit and
seven-hit trials. All captured embeddings matched the pinned integer reference.
The independent waveform check counted PL clock edges, checked every accepted
output lane, verified stable stalled payloads, and matched first/final capture
edges and host readback. Standalone RTL regressions also passed at 1, 2, 64 and
128 lanes; the AXI/capture adapter passed at 64 and 128 lanes.

These measurements include resident raw-register reads, KAN arithmetic and
local capture. Host loading/readback and AIE transfer are excluded. They do not
establish physical timing closure, device fit, reconstruction quality or a
latency-tail distribution. Builds and emulators ran sequentially with two-worker
limits and explicit memory/disk headroom checks. Generated evidence remains
outside this repository.

## Wide VCK5000 hardware-emulation benchmark

The standalone user-managed `kan_pl` adapter instantiates the same register-fed
encoder and a local bank per output lane for capture. It has no AIE graph or
transfer adapter. Raw hits remain in registers; captures are separate banked RAM.
The counter starts on encoder release and stops on the same edge that writes
the final output group. All lanes retain independent raw input values. The core
and register read tree stop advancing when their pipelines are empty; valid work
and pipeline draining retain the original cycle counts and initiation interval.

The 64-lane configuration is qualified first, followed by 128 using identical
vectors and host trials. Full-event uninterrupted RTL expectations are 137 and
75 clocks, respectively (125/63 groups plus two register-read stages and ten
KAN stages). These expectations are not measured platform timing or fit claims.

The AXI-Lite benchmark aperture is 128 KiB:

| Offset | Access | Meaning |
| --- | --- | --- |
| 0x00 | W | 1 releases a loaded event; 2 invalidates loaded inputs while idle |
| 0x04 | R | busy, complete, fault in bits 0, 1, 2 |
| 0x08 | R | compiled lane count |
| 0x0c | RW | number of hits to encode, 1 through 8000 |
| 0x10 | W/R | append a four-byte hit / read loaded count |
| 0x14 | R | final capture latency in PL clocks |
| 0x18 | R | first capture latency in PL clocks |
| 0x1c | R | captured hit count |
| 0x20 | R | cycles with valid output stalled by the test sink |
| 0x24 | R | accepted output groups |
| 0x28 | RW | sink stall period: 0 disables, otherwise a power of two >= 2 |
| 0x2c | R | signature 0x4b414e31 |
| 0x8000..0xfcfc | W | sequential raw-load aperture; address must match next hit |
| 0x10000..0x1f9fc | R | captured INT8 embeddings in original hit order |

Configuration/loading while busy returns an error. AW and W are accepted
independently; B and R responses remain stable under host backpressure. Capture
readback is blocked while busy. A start clears capture counters and fault status;
a successful clear also invalidates capture readback. Output capture RAM contents
are not reset. The sink accepts all lanes together and can deliberately stall
one cycle per configured period to test backpressure; this is not AIE traffic.

Source the existing clustering environment (Vitis/XRT 2022.2 and VCK5000 platform),
export the tables into BUILD/generated, then run with a separate BUILD per lane
count. Keep the source and generated fixtures identical between configurations.

```bash
make -f kan/Makefile test control-test BUILD=/absolute/build/p64 LANES=64
make -f kan/Makefile host xo link package BUILD=/absolute/build/p64 LANES=64
make -f kan/Makefile emu BUILD=/absolute/build/p64 LANES=64
python3 kan/tools/check_trace.py /absolute/build/p64
# Repeat with a fresh build/p128 and LANES=128 after p64 passes.
```

`host.cpp` loads 8,000 words once, then encodes 33 hits, 8,000 hits, 8,000 hits
with sink stalls, and seven hits. Every captured byte is compared with the
independent integer oracle. All loading, polling and readback are outside the
hardware cycle counter. The waveform checker verifies every accepted output
group, first/final capture edges, frozen completion counters and host readback.
It derives the PL clock from waveform timestamps before converting cycles to
microseconds. No physical maximum frequency or resource fit follows from emulation.

The emulation launcher includes the clustering benchmark's sparse NoC backing
file wrapper. It only creates missing zero-filled files before simulated clocks
run, avoiding a large platform initialization write. Existing backing files are
never replaced. This changes host-side initialization cost, not simulated cycles.

Run large platform builds and emulators sequentially. Vivado synthesis,
implementation and XSim elaboration use two workers. The link and emulation
Make targets check for at least 16 GiB MemAvailable and 6 GiB free disk before
starting; these defaults are configurable via MIN_AVAILABLE_GIB and
MIN_FREE_DISK_GIB. This is a headroom check, not a memory reservation. Recheck
that the preceding emulator exited before starting the next lane count.
