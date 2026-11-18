set base /design_1_wrapper_sim_wrapper/design_1_wrapper_i/design_1_i/VitisRegion/array_pl_1/inst/core
set signals {}
foreach leaf {ap_rst_n release_strobe busy density_done cluster_done fault reduce_valid force_64 elapsed_cycles column_density_done column_labels_done column_fault tx_beats rx_beats tile_density_masks tile_label_masks tx_data tx_keep tx_last tx_valid tx_ready rx_data rx_keep rx_last rx_valid rx_ready} {
 set object [get_objects "$base/$leaf"]
 if {[llength $object]!=1} {error "Missing array trace signal $base/$leaf"}
 lappend signals $object
}
open_vcd "$::env(TRANSPORT_RESULTS)/pl.vcd"
log_vcd $signals
puts "ARRAY_TRACE: [llength $signals] signals recorded"
