# Called by XRT's USER_PRE_SIM_SCRIPT in the VCK5000 hardware emulator.
set base /design_1_wrapper_sim_wrapper/design_1_wrapper_i/design_1_i/VitisRegion/transport_pl_1/inst
set signals {}
foreach leaf {ap_rst_n release_strobe busy density_done readback_done fault tx_index rx_index elapsed_cycles m_axis_tx_tdata m_axis_tx_tvalid m_axis_tx_tready s_axis_rx_tdata s_axis_rx_tvalid s_axis_rx_tready} {
 set object [get_objects "$base/$leaf"]
 if {[llength $object]!=1} {error "Missing transport trace signal $base/$leaf"}
 lappend signals $object
}
open_vcd "$::env(TRANSPORT_RESULTS)/pl.vcd"
log_vcd $signals
# Do not dump a free-running clock during emulated host register accesses.
# release_strobe is exactly one clock wide, providing a measured PL period.
puts "TRANSPORT_TRACE: [llength $signals] signals recorded"
