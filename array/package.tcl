set src [file normalize [lindex $argv 0]]
set build [file normalize [lindex $argv 1]]
set columns [lindex $argv 2]
create_project array_pack ./project -part xcvc1902-vsvd1760-2MP-e-S -force
add_files [list $src/array/column_lane.sv $src/array/control.sv $build/config/array_pl.sv]
set_property top array_pl [current_fileset]
update_compile_order -fileset sources_1
ipx::package_project -root_dir ./ip -vendor hgcal.org -library benchmark -taxonomy /KernelIP -import_files
set core [ipx::current_core]
set_property name array_pl $core
set_property sdx_kernel true $core
set_property sdx_kernel_type rtl $core
ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core
for {set c 0} {$c<$columns} {incr c} {
 ipx::associate_bus_interfaces -busif m_axis_tx_$c -clock ap_clk $core
 ipx::associate_bus_interfaces -busif s_axis_rx_$c -clock ap_clk $core
}
set map [ipx::get_memory_maps s_axi_control -of_objects $core]
set block [ipx::get_address_blocks -of_objects $map]
if {[llength $block]!=1} {error "Expected one inferred AXI-Lite address block"}
set_property range 65536 $block
set_property width 32 $block
set reg [ipx::add_register RELEASE $block]
set_property address_offset 0 $reg
set_property size 32 $reg
set_property slave_memory_map_ref s_axi_control [ipx::get_bus_interfaces s_axi_control -of_objects $core]
set_property supported_families {} $core
set_property auto_family_support_level level_2 $core
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity -kernel $core
ipx::save_core $core
package_xo -force -ctrl_protocol user_managed -xo_path $build/array_pl.xo -kernel_name array_pl -kernel_xml $build/config/kernel.xml -ip_directory ./ip
close_project
