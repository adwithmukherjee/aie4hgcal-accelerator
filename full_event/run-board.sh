#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"
source /opt/xilinx/xrt/setup.sh >/dev/null
unset XCL_EMULATION_MODE
printf '[Runtime]\nert=false\n' >xrt.ini
export XRT_INI_PATH="$PWD/xrt.ini"
{
    date -u
    hostname
    sha256sum -c image.sha256
    who
    xbutil examine -d 0000:ca:00.1 -r platform
    state=$(cat /sys/bus/pci/devices/0000:ca:00.1/kdsstat)
    echo "$state"
    awk -F: '/^outstanding execs:/ {idle=($2~/^[[:space:]]*0[[:space:]]*$/)} /^contexts:/ {free=($2~/^[[:space:]]*0[[:space:]]*$/)} /^client pid:/ {empty=($2~/^[[:space:]]*$/)} END {exit !(idle && free && empty)}' <<<"$state" || { echo "Card in use or status unavailable"; exit 75; }
    timeout 120s ./host
    xbutil examine -d 0000:ca:00.1 -r platform
} 2>&1 | tee console.log
