SHELL := /bin/bash
.SHELLFLAGS := -e -o pipefail -c
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
COLUMNS ?= 4
BUILD ?= $(HOME)/aie-cluster-builds/c$(COLUMNS)
AIE_BUILD ?= /dev/shm/aie-cluster-c$(COLUMNS)
AIE_JOBS ?= 2
DATA ?= $(HOME)/aie-landmark-benchmark-data/cluster-real-mixed
PLATFORM ?= /opt/xilinx/platforms/xilinx_vck5000_gen4x8_qdma_2_202220_1/xilinx_vck5000_gen4x8_qdma_2_202220_1.xpfm
NATIVE_EVENTS ?= 2
ASSIGNMENT_CASES := $(shell PYTHONDONTWRITEBYTECODE=1 python3 -c 'import sys; sys.path.insert(0,"$(ROOT)/array/tools"); from assignment_cases import ASSIGNMENT_CASE_COUNT; print(ASSIGNMENT_CASE_COUNT)')
SEED_MODE ?= normal
export TMPDIR := $(BUILD)/tmp
export PYTHONDONTWRITEBYTECODE := 1
.DEFAULT_GOAL := aie
.PHONY: configure aie codegen aie-sim aie-gate-test aie-cap-test aie-assignment-test aie-shortlist-test aie-force64-test seed-test rtl-test xo host link package emu pl-trace
configure:
	mkdir -p $(BUILD)/tmp $(BUILD)/aie
	python3 $(ROOT)/array/tools/configure.py $(BUILD) $(COLUMNS)
aie: configure
	mkdir -p $(AIE_BUILD)/aie
	cp $(BUILD)/config/constraints.json $(AIE_BUILD)/constraints.json
	cd $(AIE_BUILD)/aie && aiecompiler --target=hw --platform=$(PLATFORM) --stacksize=20480 --heapsize=2048 --pl-freq=300 --Xelfgen=-j$(AIE_JOBS) --constraints=$(AIE_BUILD)/constraints.json --Xpreproc=-DARRAY_COLUMNS=$(COLUMNS) --include=$(ROOT)/include --include=$(ROOT)/aie --include=$(ROOT)/array --workdir=Work --output-archive=$(AIE_BUILD)/libadf.a $(ROOT)/array/graph.cpp > compile.log 2>&1
	cp $(AIE_BUILD)/libadf.a $(BUILD)/libadf.a
	rsync -a $(AIE_BUILD)/aie/ $(BUILD)/aie/
	grep -q 'Compilation Complete' $(BUILD)/aie/compile.log
	python3 $(ROOT)/array/tools/packet_map.py $(BUILD)
	python3 $(ROOT)/array/tools/check_codegen.py $(BUILD)
codegen:
	python3 $(ROOT)/array/tools/packet_map.py $(BUILD)
	python3 $(ROOT)/array/tools/check_codegen.py $(BUILD)
aie-sim:
	python3 $(ROOT)/array/tools/make_input.py $(DATA) $(BUILD) --events $(NATIVE_EVENTS)
	cd $(BUILD)/aie && DENSITY_EVENTS=$(NATIVE_EVENTS) aiesimulator --pkg-dir=Work --output-dir=$(BUILD)/aie/native-real --output-time-stamp=no > simulate.log 2>&1
	python3 $(ROOT)/array/tools/check_aie.py $(DATA) $(BUILD)/aie/native-real $(BUILD)/config/packet_map.json --events $(NATIVE_EVENTS)
aie-gate-test:
	python3 $(ROOT)/array/tools/make_input.py $(DATA) $(BUILD) --gated
	cd $(BUILD)/aie && DENSITY_EVENTS=1 aiesimulator --pkg-dir=Work --output-dir=$(BUILD)/aie/native-gated --output-time-stamp=yes --simulation-cycle-timeout=25000 > simulate-gated.log 2>&1
	python3 $(ROOT)/array/tools/check_aie.py $(DATA) $(BUILD)/aie/native-gated $(BUILD)/config/packet_map.json --gated
rtl-test: configure
	mkdir -p $(BUILD)/rtl-test
	cd $(BUILD)/rtl-test && xvlog --sv --define TEST_COLUMNS=$(COLUMNS) $(ROOT)/array/seed_select.sv $(ROOT)/array/column_lane.sv $(ROOT)/array/control.sv $(ROOT)/array/testbench.sv
	cd $(BUILD)/rtl-test && xelab array_tb -s array_tb --debug typical
	cd $(BUILD)/rtl-test && xsim array_tb -runall --testplusarg DATA=$(DATA) 2>&1 | tee test.log
	grep -q 'PASS: four-column clustering' $(BUILD)/rtl-test/test.log
xo: configure
	mkdir -p $(BUILD)/pl
	cd $(BUILD)/pl && vivado -mode batch -source $(ROOT)/array/package.tcl -tclargs $(ROOT) $(BUILD) $(COLUMNS) > package.log 2>&1
	test -f $(BUILD)/array_pl.xo
host:
	g++ -std=c++17 -O2 -Wall -Wextra -I/opt/xilinx/xrt/include $(ROOT)/array/host.cpp -L/opt/xilinx/xrt/lib -lxrt_coreutil -ldl -o $(BUILD)/array_host
link: codegen
	mkdir -p $(BUILD)/system
	cd $(BUILD)/system && v++ -l -g --save-temps -t hw_emu --platform $(PLATFORM) --kernel_frequency 300 --config $(BUILD)/config/connectivity.cfg --temp_dir link -o array.xsa $(BUILD)/array_pl.xo $(BUILD)/libadf.a > link.log 2>&1
	python3 $(ROOT)/tools/capture_clock.py $(BUILD)
package:
	cd $(BUILD)/system && v++ -p -t hw_emu --platform $(PLATFORM) --package.boot_mode=ospi -o array.xclbin array.xsa $(BUILD)/libadf.a > package.log 2>&1
	! grep -q '^ERROR:' $(BUILD)/system/package.log
	cd $(BUILD)/system && emconfigutil --platform $(PLATFORM) --od .
	python3 $(ROOT)/array/tools/check_package.py $(BUILD)
emu:
	COLUMNS=$(COLUMNS) BUILD=$(BUILD) DATA=$(DATA) SEED_MODE=$(SEED_MODE) bash $(ROOT)/array/run_emu.sh
pl-trace:
	python3 $(ROOT)/array/tools/check_pl_trace.py $(DATA) $(BUILD) $(SEED_MODE)

seed-test: configure
	mkdir -p $(BUILD)/seed-test
	cd $(BUILD)/seed-test && xvlog --sv $(ROOT)/array/seed_select.sv $(ROOT)/array/seed_testbench.sv
	cd $(BUILD)/seed-test && xelab seed_tb -s seed_tb --debug typical
	cd $(BUILD)/seed-test && xsim seed_tb -runall --testplusarg DATA=$(DATA) 2>&1 | tee test.log
	grep -q 'PASS: seed priority' $(BUILD)/seed-test/test.log

aie-cap-test:
	python3 $(ROOT)/array/tools/make_input.py $(DATA) $(BUILD) --events 2 --assignment-count 64 --ties-last
	cd $(BUILD)/aie && DENSITY_EVENTS=2 aiesimulator --pkg-dir=Work --output-dir=$(BUILD)/aie/native-cap --output-time-stamp=no > simulate-cap.log 2>&1
	python3 $(ROOT)/array/tools/check_aie.py $(DATA) $(BUILD)/aie/native-cap $(BUILD)/config/packet_map.json --events 2 --assignment-count 64 --ties-last

aie-shortlist-test: aie-assignment-test

aie-assignment-test:
	python3 $(ROOT)/array/tools/make_input.py $(DATA) $(BUILD) --events $(ASSIGNMENT_CASES) --assignment-cases
	cd $(BUILD)/aie && DENSITY_EVENTS=$(ASSIGNMENT_CASES) aiesimulator --pkg-dir=Work --output-dir=$(BUILD)/aie/native-assignment --output-time-stamp=no > simulate-assignment.log 2>&1
	python3 $(ROOT)/array/tools/check_aie.py $(DATA) $(BUILD)/aie/native-assignment $(BUILD)/config/packet_map.json --events $(ASSIGNMENT_CASES) --assignment-cases

aie-force64-test:
	python3 $(ROOT)/array/tools/make_input.py $(DATA) $(BUILD) --events 2 --force-64
	cd $(BUILD)/aie && DENSITY_EVENTS=2 aiesimulator --pkg-dir=Work --output-dir=$(BUILD)/aie/native-force64 --output-time-stamp=yes > simulate-force64.log 2>&1
	python3 $(ROOT)/array/tools/check_aie.py $(DATA) $(BUILD)/aie/native-force64 $(BUILD)/config/packet_map.json --events 2 --force-64
