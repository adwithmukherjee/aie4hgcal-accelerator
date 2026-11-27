# VCK5000 full-event encoder and clusterer

The PL encodes 8,000 raw hits and selects seeds from 128 landmarks. The AIE graph clusters the same 8,000 hits on columns 1–48. Each of the first 320 workers processes 21 hits and each of the remaining 64 processes 20. The extra hit uses the vector distance kernel with a mask on its density contribution.

On the VCK5000, event 187 produced four seeds and 8,000 byte-exact labels in 2,442 PL cycles on three runs at the reported 278 MHz data clock (8.784 µs). The previous scalar implementation used 4,405 cycles (15.845 µs). Host input loading through label readback took 4.96–5.02 ms on the optimized runs.

## Build and verification

Source the lab Vitis 2022.2 and XRT environment. Use absolute paths for BUILD, FIXTURE (the event-00187 directory from kan_cluster/tools/fixtures.py) and GENERATED (the compact KAN export from kan/tools/export.py). The Makefile expects the VCK5000 QDMA platform and a licensed AIE compiler.

```sh
export BUILD="$HOME/full-event-384"
make aie
make sim
make rtl-test
make link
make package host
```

The native simulation compares all per-tile densities and labels to a CPU reference. The RTL test checks the generated AIE packet streams and global densities, seed packet and labels. Transfer the packaged image and its checksum, the XRT host (or compile it on the board), the fixture's wire.bin, and rtl/routes.bin and rtl/labels.bin to one directory on the board host with run-board.sh. Run the script there. The host's device time conversion assumes the validated 278 MHz image. For a new implementation use the printed cycle count and the data clock reported after programming. Host timing excludes programming, route configuration and reference comparison.
