set src [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
create_project column_pack ./project -part xcvc1902-vsvd1760-2MP-e-S -force
add_files $src/column/pl.sv
set_property top column_pl [current_fileset]
update_compile_order -fileset sources_1
ipx::package_project -root_dir ./ip -vendor hgcal.org -library benchmark -taxonomy /KernelIP -import_files
set core [ipx::current_core]
set_property name column_pl $core
set_property sdx_kernel true $core
set_property sdx_kernel_type rtl $core
foreach bus {s_axi_control m_axis_tx s_axis_rx} {
 ipx::associate_bus_interfaces -busif $bus -clock ap_clk $core
}
set map [ipx::add_memory_map s_axi_control $core]
set block [ipx::add_address_block registers $map]
set_property range 262144 $block
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
package_xo -force -ctrl_protocol user_managed -xo_path $out -kernel_name column_pl -kernel_xml $src/column/kernel.xml -ip_directory ./ip
close_project
