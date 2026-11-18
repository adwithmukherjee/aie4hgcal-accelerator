SHELL := /bin/bash
.SHELLFLAGS := -e -o pipefail -c
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
TILES ?= 8
BUILD ?= $(HOME)/aie-column-builds/t$(TILES)
PL_BUILD ?= $(BUILD)
AIE_BUILD ?= /dev/shm/aie-column-t$(TILES)
DATA ?= $(HOME)/aie-landmark-benchmark-data/column-real-mixed
SIM_OUTPUT ?= $(BUILD)/aie/native-real
PLATFORM ?= /opt/xilinx/platforms/xilinx_vck5000_gen4x8_qdma_2_202220_1/xilinx_vck5000_gen4x8_qdma_2_202220_1.xpfm
export TMPDIR := $(BUILD)/tmp
export PYTHONDONTWRITEBYTECODE := 1
.DEFAULT_GOAL := aie
.PHONY: configure aie codegen aie-sim aie-gate-test rtl-test xo host link package emu pl-trace
configure:
	mkdir -p $(BUILD)/tmp $(BUILD)/aie
	python3 $(ROOT)/column/tools/configure.py $(BUILD) $(TILES)
aie: configure
	mkdir -p $(AIE_BUILD)/aie
	cp $(BUILD)/config/constraints.json $(AIE_BUILD)/constraints.json
	cd $(AIE_BUILD)/aie && aiecompiler --target=hw --platform=$(PLATFORM) --stacksize=16384 --heapsize=2048 --pl-freq=300 --constraints=$(AIE_BUILD)/constraints.json --Xpreproc=-DCOLUMN_TILES=$(TILES) --include=$(ROOT)/include --include=$(ROOT)/aie --include=$(ROOT)/column --workdir=Work --output-archive=$(AIE_BUILD)/libadf.a $(ROOT)/column/graph.cpp > compile.log 2>&1
	cp $(AIE_BUILD)/libadf.a $(BUILD)/libadf.a
	rsync -a $(AIE_BUILD)/aie/ $(BUILD)/aie/
	test -f $(BUILD)/libadf.a && grep -q 'Compilation Complete' $(BUILD)/aie/compile.log
	python3 $(ROOT)/column/tools/packet_map.py $(BUILD)
	python3 $(ROOT)/column/tools/check_codegen.py $(BUILD)
codegen:
	python3 $(ROOT)/column/tools/packet_map.py $(BUILD)
	python3 $(ROOT)/column/tools/check_codegen.py $(BUILD)
aie-sim:
	python3 $(ROOT)/column/tools/make_input.py $(DATA) $(BUILD)
	cd $(BUILD)/aie && DENSITY_EVENTS=$$(python3 -c 'import json; print(len(json.load(open("$(DATA)/manifest.json"))["events"]))') aiesimulator --pkg-dir=Work --output-dir=$(SIM_OUTPUT) --output-time-stamp=no > simulate.log 2>&1
	python3 $(ROOT)/column/tools/check_aie.py $(DATA) $(SIM_OUTPUT)/output.txt $(BUILD)/config/packet_map.json
aie-gate-test:
	python3 $(ROOT)/column/tools/make_input.py $(DATA) $(BUILD) --gated
	cd $(BUILD)/aie && DENSITY_EVENTS=1 aiesimulator --pkg-dir=Work --output-dir=$(BUILD)/aie/native-gated --output-time-stamp=yes --simulation-cycle-timeout=25000 > simulate-gated.log 2>&1
	python3 $(ROOT)/column/tools/check_aie.py $(DATA) $(BUILD)/aie/native-gated/output.txt $(BUILD)/config/packet_map.json --gated
rtl-test:
	mkdir -p $(BUILD)/tmp $(BUILD)/rtl-test
	cd $(BUILD)/rtl-test && xvlog --sv $(ROOT)/column/pl.sv $(ROOT)/column/testbench.sv
	cd $(BUILD)/rtl-test && xelab column_tb -s column_tb --debug typical
	cd $(BUILD)/rtl-test && xsim column_tb -runall --testplusarg DATA=$(DATA) 2>&1 | tee test.log
	grep -q 'PASS: column packet routing' $(BUILD)/rtl-test/test.log
xo:
	mkdir -p $(BUILD)/tmp $(BUILD)/pl
	cd $(BUILD)/pl && vivado -mode batch -source $(ROOT)/column/package.tcl -tclargs $(ROOT) $(BUILD)/column_pl.xo > package.log 2>&1
	test -f $(BUILD)/column_pl.xo
host:
	g++ -std=c++17 -O2 -Wall -Wextra -I$(ROOT)/include -I/opt/xilinx/xrt/include $(ROOT)/column/host.cpp -L/opt/xilinx/xrt/lib -lxrt_coreutil -ldl -o $(BUILD)/column_host
link: codegen
	mkdir -p $(BUILD)/system
	cp $(BUILD)/aie/Work/reports/compiler_report.json $(BUILD)/system/linked-aie-compiler-report.json
	cd $(BUILD)/system && v++ -l -g --save-temps -t hw_emu --platform $(PLATFORM) --kernel_frequency 300 --config $(ROOT)/column/connectivity.cfg --temp_dir link -o column.xsa $(BUILD)/column_pl.xo $(BUILD)/libadf.a > link.log 2>&1
	python3 $(ROOT)/tools/capture_clock.py $(BUILD)
package:
	mkdir -p $(BUILD)/system
	python3 $(ROOT)/column/tools/check_interface.py $(PL_BUILD) $(BUILD)
	cd $(BUILD)/system && v++ -p -t hw_emu --platform $(PLATFORM) --package.boot_mode=ospi -o column.xclbin $(PL_BUILD)/system/column.xsa $(BUILD)/libadf.a > package.log 2>&1
	! grep -q '^ERROR:' $(BUILD)/system/package.log
	python3 $(ROOT)/column/tools/check_interface.py $(PL_BUILD) $(BUILD) --packaged
	if [[ "$(PL_BUILD)" != "$(BUILD)" ]]; then cp $(PL_BUILD)/system/clock_evidence.json $(BUILD)/system/clock_evidence.json; fi
	cd $(BUILD)/system && emconfigutil --platform $(PLATFORM) --od .
emu:
	TILES=$(TILES) BUILD=$(BUILD) DATA=$(DATA) bash $(ROOT)/column/run_emu.sh
pl-trace:
	python3 $(ROOT)/column/tools/check_pl_trace.py $(DATA) $(BUILD)
