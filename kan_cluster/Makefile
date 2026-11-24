SHELL := /bin/bash
.SHELLFLAGS := -e -o pipefail -c
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SOURCE := $(abspath $(ROOT)/..)
BUILD ?= $(HOME)/kan-cluster-build
DATA ?= $(BUILD)/data
PYTHON ?= python3
TARGET ?= hw_emu
VIVADO_JOBS ?= 1
VIVADO_THREADS ?= 2
ifneq ($(filter $(TARGET),hw hw_emu),$(TARGET))
$(error TARGET must be hw or hw_emu)
endif
AIE_ARCHIVE ?= $(HOME)/aie-landmark-benchmark-runs/vector-assignment-20261118-4254658
PLATFORM ?= /opt/xilinx/platforms/xilinx_vck5000_gen4x8_qdma_2_202220_1/xilinx_vck5000_gen4x8_qdma_2_202220_1.xpfm
ifeq ($(TARGET):$(notdir $(PLATFORM)),hw:xilinx_vck5000_gen4x8_qdma_2_202220_1.xpfm)
PARTPIN_OPT := --vivado.prop "run.impl_1.STEPS.PLACE_DESIGN.TCL.PRE=$(ROOT)/axi_partition_pin.tcl"
endif
RTL := $(BUILD)/generated/kan_lane.sv $(SOURCE)/kan/stream.sv $(SOURCE)/kan/register_bank.sv $(SOURCE)/kan/event.sv $(SOURCE)/array/seed_select.sv $(ROOT)/column.sv $(ROOT)/control.sv
.PHONY: generate rtl-test configure stage-aie xo host link package emu verify hardware resource-check
generate:
	$(PYTHON) $(SOURCE)/kan/tools/export.py $(TABLES) $(BUILD)/generated
resource-check:
	$(PYTHON) $(SOURCE)/kan/tools/resources.py $(BUILD)
rtl-test: resource-check
	mkdir -p $(BUILD)/rtl-test
	cp $(BUILD)/generated/*.mem $(BUILD)/rtl-test/
	cd $(BUILD)/rtl-test && xvlog --sv $(RTL) $(ROOT)/testbench.sv > compile.log 2>&1
	cd $(BUILD)/rtl-test && xelab --mt 2 -generic_top CAPTURE_EMBEDDINGS=$(if $(filter hw,$(TARGET)),0,1) kan_cluster_tb -s kan_cluster_tb --debug typical > elaborate.log 2>&1
	cd $(BUILD)/rtl-test && xsim kan_cluster_tb -runall --testplusarg DATA=$(DATA) > test.log 2>&1
	grep 'PASS: 64-lane KAN to four-column streaming RTL' $(BUILD)/rtl-test/test.log
configure:
	$(PYTHON) $(ROOT)/tools/configure.py $(BUILD) --target $(TARGET) --jobs $(VIVADO_JOBS) --threads $(VIVADO_THREADS)
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
	cd $(BUILD)/system && v++ -l -g --save-temps -t $(TARGET) --platform $(PLATFORM) --kernel_frequency 300 --config $(BUILD)/config/connectivity.cfg $(PARTPIN_OPT) --temp_dir link -o integrated.xsa $(BUILD)/kan_cluster_pl.xo $(BUILD)/libadf.a > link.log 2>&1
ifeq ($(TARGET),hw_emu)
	$(PYTHON) $(SOURCE)/tools/capture_clock.py $(BUILD)
endif
package:
	cd $(BUILD)/system && v++ -p -t $(TARGET) --platform $(PLATFORM) --package.boot_mode=ospi -o integrated.xclbin integrated.xsa $(BUILD)/libadf.a > package.log 2>&1
	! grep -q '^ERROR:' $(BUILD)/system/package.log
ifeq ($(TARGET),hw_emu)
	cd $(BUILD)/system && emconfigutil --platform $(PLATFORM) --od .
endif
emu: resource-check
	BUILD=$(BUILD) DATA=$(DATA) bash $(ROOT)/run_emu.sh
verify:
	$(PYTHON) $(ROOT)/tools/check_trace.py $(BUILD) $(DATA)
hardware:
	$(MAKE) -j1 TARGET=hw xo stage-aie host
	$(MAKE) -j1 TARGET=hw link
	$(MAKE) -j1 TARGET=hw package
