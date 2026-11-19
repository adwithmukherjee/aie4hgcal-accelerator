SHELL := /bin/bash
.SHELLFLAGS := -e -o pipefail -c
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD ?= /tmp/kan-pl-stream
PYTHON ?= python3
LANES ?= 1
.PHONY: generate test
# The model export is an external artifact, never a mutable training dependency.
generate:
	$(PYTHON) $(ROOT)/tools/export.py $(TABLES) $(BUILD)/generated
test:
	mkdir -p $(BUILD)/test-p$(LANES)
	cp $(BUILD)/generated/*.mem $(BUILD)/test-p$(LANES)/
	cd $(BUILD)/test-p$(LANES) && xvlog --sv --define TEST_LANES=$(LANES) $(BUILD)/generated/kan_lane.sv $(ROOT)/stream.sv $(ROOT)/register_bank.sv $(ROOT)/event.sv $(ROOT)/stream_tb.sv $(ROOT)/event_tb.sv > compile.log 2>&1
	cd $(BUILD)/test-p$(LANES) && xelab --mt 2 stream_tb -s stream_tb --debug typical > elaborate-stream.log 2>&1
	cd $(BUILD)/test-p$(LANES) && xsim stream_tb -runall > stream.log 2>&1
	grep 'PASS: stream' $(BUILD)/test-p$(LANES)/stream.log
	cd $(BUILD)/test-p$(LANES) && xelab --mt 2 event_tb -s event_tb --debug typical > elaborate-event.log 2>&1
	cd $(BUILD)/test-p$(LANES) && xsim event_tb -runall > event.log 2>&1
	grep 'PASS: event' $(BUILD)/test-p$(LANES)/event.log

PLATFORM ?= /opt/xilinx/platforms/xilinx_vck5000_gen4x8_qdma_2_202220_1/xilinx_vck5000_gen4x8_qdma_2_202220_1.xpfm
.PHONY: control-test configure xo host link package emu resource-check
control-test:
	mkdir -p $(BUILD)/control-p$(LANES)
	cp $(BUILD)/generated/*.mem $(BUILD)/control-p$(LANES)/
	cd $(BUILD)/control-p$(LANES) && xvlog --sv --define TEST_LANES=$(LANES) $(BUILD)/generated/kan_lane.sv $(ROOT)/stream.sv $(ROOT)/register_bank.sv $(ROOT)/event.sv $(ROOT)/control.sv $(ROOT)/control_tb.sv > compile.log 2>&1
	cd $(BUILD)/control-p$(LANES) && xelab --mt 2 control_tb -s control_tb --debug typical > elaborate.log 2>&1
	cd $(BUILD)/control-p$(LANES) && xsim control_tb -runall > test.log 2>&1
	grep 'PASS: AXI control' $(BUILD)/control-p$(LANES)/test.log
configure:
	$(PYTHON) $(ROOT)/tools/configure.py $(BUILD) $(LANES)
xo: configure
	mkdir -p $(BUILD)/pl
	cd $(BUILD)/pl && vivado -mode batch -notrace -nojournal -source $(ROOT)/package.tcl -tclargs $(ROOT) $(BUILD) > package.log 2>&1
	test -f $(BUILD)/kan_pl.xo
host:
	g++ -std=c++17 -O2 -Wall -Wextra -I/opt/xilinx/xrt/include $(ROOT)/host.cpp -L/opt/xilinx/xrt/lib -lxrt_coreutil -ldl -o $(BUILD)/kan_host
link: resource-check
	mkdir -p $(BUILD)/system $(BUILD)/tmp
	cd $(BUILD)/system && v++ -l -g --save-temps -t hw_emu --platform $(PLATFORM) --kernel_frequency 300 --config $(BUILD)/config/connectivity.cfg --temp_dir link -o kan.xsa $(BUILD)/kan_pl.xo > link.log 2>&1
package:
	cd $(BUILD)/system && v++ -p -t hw_emu --platform $(PLATFORM) --package.boot_mode=ospi -o kan.xclbin kan.xsa > package.log 2>&1
	! grep -q '^ERROR:' $(BUILD)/system/package.log
	cd $(BUILD)/system && emconfigutil --platform $(PLATFORM) --od .
emu: resource-check
	BUILD=$(BUILD) LANES=$(LANES) bash $(ROOT)/run_emu.sh

MIN_AVAILABLE_GIB ?= 16
MIN_FREE_DISK_GIB ?= 6
resource-check:
	$(PYTHON) $(ROOT)/tools/resources.py $(BUILD) --min-memory-gib $(MIN_AVAILABLE_GIB) --min-disk-gib $(MIN_FREE_DISK_GIB)
