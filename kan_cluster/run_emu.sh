#!/usr/bin/env bash
set -eo pipefail
root=$(cd "$(dirname "$0")" && pwd)
build=${BUILD:?Set BUILD}
data=${DATA:?Set DATA}
export PATH="$root/../kan/tools/wrappers:$PATH"
export SDACCEL_EM_RUN_DIR="$build/runtime"
export KAN_CLUSTER_RESULTS="$build/system/results"
export KAN_CLUSTER_DATA="$data"
export KAN_CLUSTER_SIM_MEMORY="${KAN_CLUSTER_SIM_MEMORY:-1}"
mkdir -p "$SDACCEL_EM_RUN_DIR" "$KAN_CLUSTER_RESULTS" "$build/tmp"
for output in events.json pl.vcd trace-validation.json capture-0.mem capture-1.mem embeddings-0.bin embeddings-1.bin density-0.bin density-1.bin labels-0.bin labels-1.bin; do
  rm -f "$KAN_CLUSTER_RESULTS/$output"
done
cat > "$build/system/xrt.ini" <<EOF
[Emulation]
debug_mode=batch
user_pre_sim_script=$root/trace_pl.tcl
EOF
cd "$build/system"
export TMPDIR="$build/tmp"
export XCL_EMULATION_MODE=hw_emu EMCONFIG_PATH="$PWD" XRT_INI_PATH="$PWD/xrt.ini"
export USER_PRE_SIM_SCRIPT="$root/trace_pl.tcl"
"$build/kan_cluster_host" "$PWD/integrated.xclbin" "$data" "$build/config" "$KAN_CLUSTER_RESULTS" 2>&1 | tee "$KAN_CLUSTER_RESULTS/run.log"
grep -q 'PASS: integrated raw KAN and AIE clustering' "$KAN_CLUSTER_RESULTS/run.log"
