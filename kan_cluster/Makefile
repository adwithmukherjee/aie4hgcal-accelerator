SHELL := /bin/bash
.SHELLFLAGS := -e -o pipefail -c
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SOURCE := $(abspath $(ROOT)/..)
BUILD ?= $(HOME)/kan-cluster-build
DATA ?= $(BUILD)/data
PYTHON ?= python3
AIE_ARCHIVE ?= $(HOME)/aie-landmark-benchmark-runs/vector-assignment-20261118-4254658
PLATFORM ?= /opt/xilinx/platforms/xilinx_vck5000_gen4x8_qdma_2_202220_1/xilinx_vck5000_gen4x8_qdma_2_202220_1.xpfm
RTL := $(BUILD)/generated/kan_lane.sv $(SOURCE)/kan/stream.sv $(SOURCE)/kan/register_bank.sv $(SOURCE)/kan/event.sv $(SOURCE)/array/seed_select.sv $(ROOT)/column.sv $(ROOT)/control.sv
.PHONY: generate rtl-test configure stage-aie xo host link package emu verify resource-check
generate:
	$(PYTHON) $(SOURCE)/kan/tools/export.py $(TABLES) $(BUILD)/generated
resource-check:
	$(PYTHON) $(SOURCE)/kan/tools/resources.py $(BUILD)
rtl-test: resource-check
	mkdir -p $(BUILD)/rtl-test
	cp $(BUILD)/generated/*.mem $(BUILD)/rtl-test/
	cd $(BUILD)/rtl-test && xvlog --sv $(RTL) $(ROOT)/testbench.sv > compile.log 2>&1
	cd $(BUILD)/rtl-test && xelab --mt 2 kan_cluster_tb -s kan_cluster_tb --debug typical > elaborate.log 2>&1
	cd $(BUILD)/rtl-test && xsim kan_cluster_tb -runall --testplusarg DATA=$(DATA) > test.log 2>&1
	grep 'PASS: 64-lane KAN to four-column streaming RTL' $(BUILD)/rtl-test/test.log
configure:
	$(PYTHON) $(ROOT)/tools/configure.py $(BUILD)
stage-aie: configure
	$(PYTHON) $(ROOT)/tools/stage_aie.py $(AIE_ARCHIVE) $(BUILD)
xo: configure
	mkdir -p $(BUILD)/pl
	cd $(BUILD)/pl && vivado -mode batch -notrace -nojournal -source $(ROOT)/package.tcl -tclargs $(SOURCE) $(BUILD) > package.log 2>&1
	test -f $(BUILD)/kan_cluster_pl.xo
host:
	g++ -std=c++17 -O2 -Wall -Wextra -I/opt/xilinx/xrt/include $(ROOT)/host.cpp -L/opt/xilinx/xrt/lib -lxrt_coreutil -ldl -o $(BUILD)/kan_cluster_host
link: resource-check
	mkdir -p $(BUILD)/system $(BUILD)/tmp
	cd $(BUILD)/system && v++ -l -g --save-temps -t hw_emu --platform $(PLATFORM) --kernel_frequency 300 --config $(BUILD)/config/connectivity.cfg --temp_dir link -o integrated.xsa $(BUILD)/kan_cluster_pl.xo $(BUILD)/libadf.a > link.log 2>&1
	$(PYTHON) $(SOURCE)/tools/capture_clock.py $(BUILD)
package:
	cd $(BUILD)/system && v++ -p -t hw_emu --platform $(PLATFORM) --package.boot_mode=ospi -o integrated.xclbin integrated.xsa $(BUILD)/libadf.a > package.log 2>&1
	! grep -q '^ERROR:' $(BUILD)/system/package.log
	cd $(BUILD)/system && emconfigutil --platform $(PLATFORM) --od .
emu: resource-check
	BUILD=$(BUILD) DATA=$(DATA) bash $(ROOT)/run_emu.sh
verify:
	$(PYTHON) $(ROOT)/tools/check_trace.py $(BUILD) $(DATA)
