SHELL := /bin/bash
.SHELLFLAGS := -e -o pipefail -c
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD ?= /dev/shm/aie-landmark-density
DATA ?= $(HOME)/aie-landmark-benchmark-data/density-real-mixed
SIM_OUTPUT ?= $(BUILD)/aie/native-real
SIM_TIMESTAMPS ?= no
MAX_LATENCY_NS ?= 4000
PLATFORM ?= /opt/xilinx/platforms/xilinx_vck5000_gen4x8_qdma_2_202220_1/xilinx_vck5000_gen4x8_qdma_2_202220_1.xpfm
export TMPDIR := $(BUILD)/tmp
export PYTHONDONTWRITEBYTECODE := 1
.DEFAULT_GOAL := aie
.PHONY: aie aie-sim codegen rtl-test xo host link clock-evidence package emu pl-trace
$(BUILD)/tmp:
	mkdir -p $@
aie: $(BUILD)/tmp
	mkdir -p $(BUILD)/aie
	cd $(BUILD)/aie && aiecompiler --target=hw --platform=$(PLATFORM) --stacksize=16384 --heapsize=2048 --pl-freq=300 --constraints=$(ROOT)/aie/constraints.json --include=$(ROOT)/include --include=$(ROOT)/aie --workdir=Work --output-archive=$(BUILD)/libadf.a $(ROOT)/aie/graph.cpp 2>&1 | tee compile.log
	test -f $(BUILD)/libadf.a && grep -q 'Compilation Complete' $(BUILD)/aie/compile.log
	python3 $(ROOT)/tools/check_codegen.py $(BUILD)
codegen:
	python3 $(ROOT)/tools/check_codegen.py $(BUILD)
aie-sim:
	ln -sfn $(DATA)/input.txt $(BUILD)/aie/input.txt
	cd $(BUILD)/aie && DENSITY_EVENTS=$$(python3 -c 'import json; print(len(json.load(open("$(DATA)/manifest.json"))["events"]))') aiesimulator --pkg-dir=Work --output-dir=$(SIM_OUTPUT) --output-time-stamp=$(SIM_TIMESTAMPS) 2>&1 | tee simulate.log
	python3 $(ROOT)/tools/check_aie.py $(DATA) $(SIM_OUTPUT)/output.txt
xo: $(BUILD)/tmp
	mkdir -p $(BUILD)/pl
	cd $(BUILD)/pl && vivado -mode batch -source $(ROOT)/pl/package.tcl -tclargs $(ROOT) $(BUILD)/transport_pl.xo 2>&1 | tee package.log
	test -f $(BUILD)/transport_pl.xo
host: $(BUILD)/tmp
	g++ -std=c++17 -O2 -Wall -Wextra -I$(ROOT)/include -I/opt/xilinx/xrt/include $(ROOT)/host/run.cpp -L/opt/xilinx/xrt/lib -lxrt_coreutil -ldl -o $(BUILD)/density_host
link: codegen $(BUILD)/tmp
	mkdir -p $(BUILD)/system
	cd $(BUILD)/system && v++ -l -g --save-temps -t hw_emu --platform $(PLATFORM) --kernel_frequency 300 --config $(ROOT)/connectivity.cfg --temp_dir link -o density.xsa $(BUILD)/transport_pl.xo $(BUILD)/libadf.a 2>&1 | tee link.log
	python3 $(ROOT)/tools/capture_clock.py $(BUILD)
clock-evidence:
	python3 $(ROOT)/tools/capture_clock.py $(BUILD)
package:
	cd $(BUILD)/system && v++ -p -t hw_emu --platform $(PLATFORM) --package.boot_mode=ospi -o density.xclbin density.xsa $(BUILD)/libadf.a 2>&1 | tee package.log
	! grep -q '^ERROR:' $(BUILD)/system/package.log
	cd $(BUILD)/system && emconfigutil --platform $(PLATFORM) --od .
rtl-test: $(BUILD)/tmp
	mkdir -p $(BUILD)/rtl-test
	cd $(BUILD)/rtl-test && xvlog --sv $(ROOT)/pl/transport_pl.sv $(ROOT)/tests/transport_tb.sv
	cd $(BUILD)/rtl-test && xelab transport_tb -s transport_tb --debug typical
	cd $(BUILD)/rtl-test && xsim transport_tb -runall --testplusarg DATA=$(DATA) 2>&1 | tee test.log
	grep -q 'PASS: four real events' $(BUILD)/rtl-test/test.log
emu:
	BUILD=$(BUILD) DATA=$(DATA) bash $(ROOT)/tools/run_emu.sh
pl-trace:
	python3 $(ROOT)/tools/check_pl_trace.py $(DATA) $(BUILD)/system/results $(MAX_LATENCY_NS)
