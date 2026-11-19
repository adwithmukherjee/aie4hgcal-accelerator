# Usage: vivado -mode batch -source implement.tcl -tclargs ROOT GENERATED OUT PART LANES TOP ROUTE
lassign $argv root generated out part lanes top route
set_param general.maxThreads 2
file mkdir $out
cd $out
foreach image [glob $generated/*.mem] {file copy -force $image .}
read_verilog -sv [list $generated/kan_lane.sv $root/stream.sv $root/register_bank.sv $root/event.sv]
set constraints [open target.xdc w]
puts $constraints {create_clock -name clk -period 3.333 [get_ports clk]}
puts $constraints {set_clock_uncertainty 0.100 [get_clocks clk]}
close $constraints
read_xdc target.xdc
synth_design -top $top -part $part -mode out_of_context -generic LANES=$lanes
# External adapters have no timing contract yet. Only internal register paths
# are qualified here; exclude OOC port paths rather than invent I/O delays.
set_false_path -from [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_false_path -to [all_outputs]
report_utilization -file synth-utilization.rpt
report_utilization -hierarchical -file synth-hierarchy.rpt
report_timing_summary -delay_type min_max -file synth-timing.rpt
write_checkpoint -force synth.dcp
if {$route} {
 opt_design
 place_design
 phys_opt_design
 route_design
 phys_opt_design -hold_fix
 route_design
 report_utilization -file route-utilization.rpt
 report_timing_summary -delay_type min_max -report_unconstrained -file route-timing.rpt
 report_route_status -file route-status.rpt
 write_checkpoint -force route.dcp
 set setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
 set hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
 set fh [open timing.json w]
 puts $fh "{\"part\":\"$part\",\"lanes\":$lanes,\"top\":\"$top\",\"period_ns\":3.333,\"uncertainty_ns\":0.100,\"internal_setup_slack_ns\":$setup,\"internal_hold_slack_ns\":$hold,\"external_paths_excluded\":true}"
 close $fh
 if {$setup < 0 || $hold < 0} {error "Internal timing failed: setup=$setup hold=$hold"}
}
