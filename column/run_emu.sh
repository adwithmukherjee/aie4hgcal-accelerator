#!/usr/bin/env bash
set -eo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if [[ -f "$root/env.sh" ]]; then source "$root/env.sh" >/dev/null; fi
tiles=${TILES:?Set TILES to the compiled column size}
build=${BUILD:-$HOME/aie-column-builds/t$tiles}
data=${DATA:-$HOME/aie-landmark-benchmark-data/column-real-mixed}
export SDACCEL_EM_RUN_DIR=${SDACCEL_EM_RUN_DIR:-$HOME/aie-landmark-benchmark-runs/runtime/column-t$tiles}
export TRANSPORT_RESULTS=${TRANSPORT_RESULTS:-$build/system/results}
mkdir -p "$SDACCEL_EM_RUN_DIR" "$TRANSPORT_RESULTS"
export PATH="$root/tools/wrappers:$PATH"
cat > "$build/system/xrt.ini" <<EOF
[Emulation]
debug_mode=batch
user_pre_sim_script=$root/column/trace_pl.tcl
EOF
cd "$build/system"
export TMPDIR="$build/tmp"
export XCL_EMULATION_MODE=hw_emu EMCONFIG_PATH="$PWD" XRT_INI_PATH="$PWD/xrt.ini"
export USER_PRE_SIM_SCRIPT="$root/column/trace_pl.tcl"
"$build/column_host" "$PWD/column.xclbin" "$data" "$build/config" "$TRANSPORT_RESULTS" "$tiles" 2>&1 | tee "$TRANSPORT_RESULTS/run.log"
