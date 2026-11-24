# Put the crossing on a tile reached by the prior checkpoint's free driver-to-load path.
set pin [get_pins {top_i/ulp/BLP_S_AXI_CTRL_USER_00_awaddr[23]}]
if {[llength $pin] != 1} {error "Expected one AXI address boundary pin"}
set_property HD.PARTPIN_LOCS INT_X6Y263 $pin
puts "AXI bit 23 partition tile [get_property HD.PARTPIN_LOCS $pin]"
