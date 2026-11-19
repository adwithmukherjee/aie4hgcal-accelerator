set base /design_1_wrapper_sim_wrapper/design_1_wrapper_i/design_1_i/VitisRegion/kan_pl_1/inst/core
set signals {}
foreach leaf {ap_clk ap_rst_n start busy complete fault cycles first_cycles captured stall_cycles accepted_groups out_valid capture_ready accepted out_last base_id mask embeddings} {
 set object [get_objects "$base/$leaf"]
 if {[llength $object]!=1} {error "Missing KAN trace signal $base/$leaf"}
 lappend signals $object
}
open_vcd "$::env(KAN_RESULTS)/pl.vcd"
log_vcd $signals
puts "KAN_TRACE: [llength $signals] signals recorded"
