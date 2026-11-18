#!/usr/bin/env bash
set -eo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if [[ -f "$root/env.sh" ]]; then source "$root/env.sh" >/dev/null; fi
columns=${COLUMNS:?Set COLUMNS to the compiled column count}
build=${BUILD:-$HOME/aie-cluster-builds/c$columns}
data=${DATA:-$HOME/aie-landmark-benchmark-data/cluster-real-mixed}
export SDACCEL_EM_RUN_DIR=${SDACCEL_EM_RUN_DIR:-$HOME/aie-landmark-benchmark-runs/runtime/cluster-c$columns}
export TRANSPORT_RESULTS=${TRANSPORT_RESULTS:-$build/system/results}
mkdir -p "$SDACCEL_EM_RUN_DIR" "$TRANSPORT_RESULTS"
export PATH="$root/tools/wrappers:$PATH"
cat > "$build/system/xrt.ini" <<EOF
[Emulation]
debug_mode=batch
user_pre_sim_script=$root/array/trace_pl.tcl
EOF
cd "$build/system"
export TMPDIR="$build/tmp"
export XCL_EMULATION_MODE=hw_emu EMCONFIG_PATH="$PWD" XRT_INI_PATH="$PWD/xrt.ini"
export USER_PRE_SIM_SCRIPT="$root/array/trace_pl.tcl"
"$build/array_host" "$PWD/array.xclbin" "$data" "$build/config" "$TRANSPORT_RESULTS" "$columns" 2>&1 | tee "$TRANSPORT_RESULTS/run.log"
