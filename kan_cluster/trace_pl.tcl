set base /design_1_wrapper_sim_wrapper/design_1_wrapper_i/design_1_i/VitisRegion/kan_cluster_pl_1/inst/core
set signals {}
foreach leaf {ap_clk ap_rst_n busy density_done cluster_done fault elapsed_cycles encoder_finished encoder_cycles encoded_count out_valid out_last base_id mask embeddings prefix_ready prepare geometry_started select_seeds/preparing select_seeds/masks_ready force_64 seeds_ready seed_count seed_slots column_density_done column_labels_done column_labels_finishing column_fault tx_data tx_keep tx_valid tx_ready tx_last tx_beats rx_data rx_keep rx_valid rx_ready rx_last rx_beats} {
 set object [get_objects "$base/$leaf"]
 if {[llength $object]!=1} {error "Missing integration trace $base/$leaf"}
 lappend signals $object
}
open_vcd "$::env(KAN_CLUSTER_RESULTS)/pl.vcd"
log_vcd $signals
puts "KAN_CLUSTER_TRACE: [llength $signals] signals recorded"
if {$::env(KAN_CLUSTER_SIM_MEMORY) eq "1"} {
 # Deposits affect only resident raw input registers and their loaded count,
 # before start. Completed capture RAM is read, never modified. No operation
 # in the measured encoding/transport/clustering interval is bypassed.
 set raw_file [open "$::env(KAN_CLUSTER_DATA)/event-00187/wire.mem" r]
 set raw_words [regexp -all -inline {\S+} [read $raw_file]]
 close $raw_file
 if {[llength $raw_words]!=8000} {error "Expected 8000 raw fixture words"}
 proc setup_raw_registers {} {
  global base raw_words
  if {[get_value -radix unsigned "$base/busy"]!=0} {error "Raw deposit attempted during event"}
  for {set i 0} {$i<8000} {incr i} {
   set name [format {%s/encoder/banks[%d].bank/hits[%d]} $base [expr {$i%64}] [expr {$i/64}]]
   set_value -radix hex $name [lindex $raw_words $i]
   if {[string tolower [get_value -radix hex $name]] ne [string tolower [lindex $raw_words $i]]} {error "Raw register deposit mismatch $i"}
  }
  set_value -radix unsigned "$base/encoder/loaded" 8000
  puts "KAN_CLUSTER_SETUP: verified 8000 resident raw registers before release"
 }
 set capture_objects [dict create]
 foreach obj [get_objects "$base/*capture*"] {
  if {[regexp {banks\[([0-9]+)\]\.capture\s*$} $obj -> lane]} {dict set capture_objects $lane $obj}
 }
 if {[dict size $capture_objects]!=64} {error "Expected 64 capture RAM banks"}
 set capture_trial 0
 proc read_completed_capture {} {
  global base capture_objects capture_trial
  if {[get_value -radix unsigned "$base/encoded_count"]!=8000} {error "Incomplete encoder at capture read"}
  set banks [dict create]
  dict for {lane obj} $capture_objects {
   set words [split [get_value -radix hex $obj] ,]
   if {[llength $words]!=125} {error "Capture RAM bank length $lane"}
   dict set banks $lane $words
  }
  set file [open "$::env(KAN_CLUSTER_RESULTS)/capture-$capture_trial.mem" w]
  for {set i 0} {$i<8000} {incr i} {
   set word [lindex [dict get $banks [expr {$i%64}]] [expr {$i/64}]]
   if {![regexp {^[0-9a-fA-F]{16}$} $word]} {error "Unknown capture RAM at $i"}
   puts $file $word
  }
  close $file
  puts "KAN_CLUSTER_CAPTURE: read all 8000 RAM outputs after trial $capture_trial"
  incr capture_trial
 }
 add_condition -notrace "$base/encoder/loaded == 1" {setup_raw_registers}
 add_condition -notrace "$base/cluster_done == 1" {read_completed_capture}
}
