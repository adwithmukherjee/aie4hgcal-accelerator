#!/usr/bin/env bash
set -eo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if [[ -f "$root/env.sh" ]]; then
  source "$root/env.sh" >/dev/null
fi
build=${BUILD:-/dev/shm/aie-landmark-density}
data=${DATA:-$HOME/aie-landmark-benchmark-data/density-real-mixed}
# The platform initializes large DRAM backing files even though this kernel
# transfers from registers. Keep emulator runtime storage off the RAM disk.
export SDACCEL_EM_RUN_DIR=${SDACCEL_EM_RUN_DIR:-$HOME/aie-landmark-benchmark-runs/runtime/$(basename "$build")}
mkdir -p "$SDACCEL_EM_RUN_DIR"
export PATH="$root/tools/wrappers:$PATH"
export TRANSPORT_RESULTS=${TRANSPORT_RESULTS:-$build/system/results}
mkdir -p "$TRANSPORT_RESULTS"
cat > "$build/system/xrt.ini" <<EOF
[Emulation]
debug_mode=batch
user_pre_sim_script=$root/tools/trace_pl.tcl
EOF
cd "$build/system"
export TMPDIR="$build/tmp"
export XCL_EMULATION_MODE=hw_emu EMCONFIG_PATH="$PWD" XRT_INI_PATH="$PWD/xrt.ini"
export USER_PRE_SIM_SCRIPT="$root/tools/trace_pl.tcl"
"$build/density_host" "$PWD/density.xclbin" "$data" "$TRANSPORT_RESULTS" 2>&1 | tee "$TRANSPORT_RESULTS/run.log"
