#!/usr/bin/env bash
set -eo pipefail
root=$(cd "$(dirname "$0")" && pwd)
build=${BUILD:?Set BUILD}
export PATH="$root/tools/wrappers:$PATH"
export SDACCEL_EM_RUN_DIR="$build/runtime"
export KAN_RESULTS="$build/system/results"
mkdir -p "$SDACCEL_EM_RUN_DIR" "$KAN_RESULTS" "$build/tmp"
cat > "$build/system/xrt.ini" <<EOF
[Emulation]
debug_mode=batch
user_pre_sim_script=$root/trace_pl.tcl
EOF
cd "$build/system"
export TMPDIR="$build/tmp"
export XCL_EMULATION_MODE=hw_emu EMCONFIG_PATH="$PWD" XRT_INI_PATH="$PWD/xrt.ini"
export USER_PRE_SIM_SCRIPT="$root/trace_pl.tcl"
"$build/kan_host" "$PWD/kan.xclbin" "$build/generated" "$KAN_RESULTS" "${LANES:?Set LANES}" 2>&1 | tee "$KAN_RESULTS/run.log"
grep -q 'PASS: integrated KAN PL hardware emulation' "$KAN_RESULTS/run.log"
