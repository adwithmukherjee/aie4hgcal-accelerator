SHELL := /bin/bash
.SHELLFLAGS := -eo pipefail -c
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO := $(abspath $(ROOT)/..)
BUILD ?= $(HOME)/full-event-384
AIE := $(BUILD)/aie
PLATFORM ?= /opt/xilinx/platforms/xilinx_vck5000_gen4x8_qdma_2_202220_1/xilinx_vck5000_gen4x8_qdma_2_202220_1.xpfm
AIE_JOBS ?= 2
GENERATED ?= $(BUILD)/generated
FIXTURE ?= $(BUILD)/data/event-00187

.PHONY: aie sim vectors rtl-test link package host
aie:
	mkdir -p "$(AIE)"
	python3 "$(ROOT)/pl/constraints.py" "$(AIE)/constraints.json"
	cd "$(AIE)" && aiecompiler --nodot-graph --target=hw --platform="$(PLATFORM)" --stacksize=20480 --heapsize=2048 --pl-freq=300 --Xelfgen=-j$(AIE_JOBS) --constraints=constraints.json --include="$(REPO)/include" --include="$(ROOT)/src/aie" --include="$(ROOT)/src/array" --include="$(REPO)/array" --workdir=Work --output-archive="$(BUILD)/libadf.a" "$(ROOT)/src/array/graph.cpp"

sim:
	python3 "$(ROOT)/verify_event.py" prepare "$(FIXTURE)" "$(AIE)"
	cd "$(AIE)" && DENSITY_EVENTS=1 aiesimulator --pkg-dir=Work --output-dir=sim --output-time-stamp=no
	python3 "$(ROOT)/verify_event.py" verify "$(FIXTURE)" "$(AIE)"

vectors:
	python3 "$(ROOT)/pl/vectors.py" "$(AIE)" "$(FIXTURE)" "$(BUILD)/rtl"

rtl-test: vectors
	cd "$(BUILD)/rtl" && cp "$(FIXTURE)/wire.mem" "$(GENERATED)"/rom_*.mem . && xvlog --sv "$(GENERATED)/kan_lane.sv" "$(ROOT)"/pl/{seed_select,column,control,testbench}.sv && xelab --mt 2 tb -s integrated_tb && xsim integrated_tb -runall | tee test.log
	grep 'PASS PL event 187' "$(BUILD)/rtl/test.log"

link:
	mkdir -p "$(BUILD)/pl" "$(BUILD)/system"
	python3 "$(ROOT)/pl/configure.py" "$(BUILD)"
	cd "$(BUILD)/pl" && vivado -mode batch -source "$(ROOT)/pl/package.tcl" -tclargs "$(ROOT)" "$(BUILD)" "$(GENERATED)"
	cd "$(BUILD)/system" && v++ -l -t hw --platform "$(PLATFORM)" --kernel_frequency 300 --config "$(BUILD)/config/connectivity.cfg" --temp_dir link -o integrated.xsa "$(BUILD)/full_event_pl.xo" "$(BUILD)/libadf.a"

package:
	cd "$(BUILD)/system" && v++ -p -t hw --platform "$(PLATFORM)" --package.boot_mode=ospi -o integrated.xclbin integrated.xsa "$(BUILD)/libadf.a"
	cd "$(BUILD)/system" && xclbinutil --info --input integrated.xclbin >image-info.txt && sha256sum integrated.xclbin >image.sha256

host:
	mkdir -p "$(BUILD)/system"
	g++ -O2 -std=c++17 -I/opt/xilinx/xrt/include "$(ROOT)/pl/host.cpp" -L/opt/xilinx/xrt/lib -lxrt_coreutil -o "$(BUILD)/system/host"
