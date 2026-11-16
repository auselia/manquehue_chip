# PrimeTime STA of the scan shift at one corner: the paths that end at a scan input
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: pt_shell -x "set CORNER ...; ...; source scan_sta_corner.tcl"      (scan_sta.sh does it for every corner)
# in:  CORNER, TOP, VLOG, SDC_FILE (the scan SDC), SPEF_FILE, SC_DB, IO_DB, SRAM_DB, REPORT_DIR
# out: "RESULT corner=..." lines on stdout, REPORT_DIR/worst_hold.<corner>.rpt
source [file dirname [info script]]/pt_design.tcl
require {CORNER TOP VLOG SDC_FILE SPEF_FILE SC_DB IO_DB SRAM_DB REPORT_DIR}

read_design
read_sdc $SDC_FILE
read_parasitics -format SPEF $SPEF_FILE
update_timing -full

# A shift path ends at SI of a scan flop, or at D of a plain flop of the chain (its scan multiplexer is a separate
# cell, or it is a shift register stage). Every D of a plain flop is timed: the plain flops outside the chain also
# clock during the shift, so their hold slack matters too.
set si [get_pins -hierarchical */SI]
set dplain [get_pins -quiet -of_objects [get_cells -hierarchical -filter "ref_name =~ *__dff*"] -filter "lib_pin_name == D"]
puts "RESULT corner=$CORNER SI_pins=[sizeof_collection $si] plain_D_pins=[sizeof_collection $dplain]"
set si [add_to_collection $si $dplain]

foreach {kind delay_type} {hold min setup max} {
  set all  [get_timing_paths -delay_type $delay_type -to $si -max_paths 100000 -nworst 1 -slack_lesser_than 1000]
  set viol [get_timing_paths -delay_type $delay_type -to $si -max_paths 100000 -nworst 1 -slack_lesser_than 0]
  set worst [get_timing_paths -delay_type $delay_type -to $si -max_paths 1]
  puts "RESULT corner=$CORNER $kind: timed_endpoints=[sizeof_collection $all] violators=[sizeof_collection $viol] worst_slack=[get_attribute $worst slack]"
}
redirect -file $REPORT_DIR/worst_hold.$CORNER.rpt {
  report_timing -delay_type min -to $si -max_paths 3 -input_pins -transition_time
}
exit
