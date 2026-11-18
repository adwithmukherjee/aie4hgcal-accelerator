set base /design_1_wrapper_sim_wrapper/design_1_wrapper_i/design_1_i/VitisRegion/column_pl_1/inst
set signals {}
foreach leaf {ap_rst_n release_strobe busy density_done readback_done fault active_count elapsed_cycles density_mask readback_mask tx_beats rx_beats tx_state tx_tile tx_word rx_words m_axis_tx_tdata m_axis_tx_tkeep m_axis_tx_tlast m_axis_tx_tvalid m_axis_tx_tready s_axis_rx_tdata s_axis_rx_tkeep s_axis_rx_tlast s_axis_rx_tvalid s_axis_rx_tready} {
 set object [get_objects "$base/$leaf"]
 if {[llength $object]!=1} {error "Missing column trace signal $base/$leaf"}
 lappend signals $object
}
open_vcd "$::env(TRANSPORT_RESULTS)/pl.vcd"
log_vcd $signals
puts "COLUMN_TRACE: [llength $signals] signals recorded"
