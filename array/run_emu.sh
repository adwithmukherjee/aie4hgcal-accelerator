#!/usr/bin/env bash
set -eo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if [[ -f "$root/env.sh" ]]; then source "$root/env.sh" >/dev/null; fi
columns=${COLUMNS:?Set COLUMNS to the compiled column count}
build=${BUILD:-$HOME/aie-cluster-builds/c$columns}
data=${DATA:-$HOME/aie-landmark-benchmark-data/cluster-real-mixed}
seed_mode=${SEED_MODE:-normal}
args=()
case "$seed_mode" in
 normal) ;;
 force64) args+=(--force-64) ;;
 *) echo "SEED_MODE must be normal or force64" >&2; exit 1 ;;
esac
export SDACCEL_EM_RUN_DIR=${SDACCEL_EM_RUN_DIR:-$HOME/aie-landmark-benchmark-runs/runtime/$(basename "$build")-$seed_mode}
export TRANSPORT_RESULTS=${TRANSPORT_RESULTS:-$build/system/results-$seed_mode}
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
"$build/array_host" "$PWD/array.xclbin" "$data" "$build/config" "$TRANSPORT_RESULTS" "$columns" "${args[@]}" 2>&1 | tee "$TRANSPORT_RESULTS/run.log"
