###############################################################################
# Croc SoC Chip
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: PrimeTime STA of chip_top at one corner (called by scripts/chip/chip_sta.sh)
###############################################################################

# As sta_corner.tcl, for the whole die. The wafer.space IPs and the DC-DC wrappers have no liberty, so they link as
# black boxes. They have no digital path to croc. Setup at slow and typical, hold at every corner.
# Variables (set with -x): CORNER VLOG SDC_FILE SPEF_FILE SC_DB IO_DB SRAM_DB REPORT_DIR

foreach v {CORNER VLOG SDC_FILE SPEF_FILE SC_DB IO_DB SRAM_DB REPORT_DIR} {
  if { ![info exists $v] } { puts "ERROR: required variable '$v' not set"; exit 1 }
}
file mkdir $REPORT_DIR

set link_library   "* $SC_DB $IO_DB $SRAM_DB"
set target_library "$SC_DB"
set link_create_black_boxes true

read_verilog $VLOG
current_design chip_top
link_design
redirect -file ${REPORT_DIR}/black_boxes.${CORNER}.rpt { report_cell -nosplit [get_cells -hier -filter is_black_box==true] }

source $SDC_FILE
# the SRAM has only a tt view: derated at slow and fast (sram_derate.tcl)
source [file dirname [info script]]/../common/sram_derate.tcl
sram_derate $CORNER
read_parasitics -format SPEF $SPEF_FILE
redirect -file ${REPORT_DIR}/parasitics.${CORNER}.rpt { report_annotated_parasitics -list_not_annotated -max_nets 50 }

update_timing -full

redirect -file ${REPORT_DIR}/check_timing.${CORNER}.rpt { check_timing -verbose }
redirect -file ${REPORT_DIR}/report_clock.${CORNER}.rpt { report_clock -attribute }
redirect -file ${REPORT_DIR}/report_drv.${CORNER}.rpt {
  report_constraint -all_violators -max_transition -max_capacitance -max_fanout
}
redirect -file ${REPORT_DIR}/report_qor.${CORNER}.rpt { report_qor }
if { $CORNER == "slow" || $CORNER == "typical" } {
  redirect -file ${REPORT_DIR}/report_timing_setup.${CORNER}.rpt {
    report_timing -delay_type max -nworst 1 -max_paths 30 -input_pins -capacitance -transition_time
  }
  redirect -file ${REPORT_DIR}/report_io_setup.${CORNER}.rpt {
    report_timing -delay_type max -from [all_inputs] -max_paths 20 -input_pins
    report_timing -delay_type max -to [all_outputs] -max_paths 20 -input_pins
  }
  redirect -file ${REPORT_DIR}/report_constraint_setup.${CORNER}.rpt { report_constraint -all_violators -max_delay }
}
# hold at every corner: the clock tree through the pads is not the same at each one
redirect -file ${REPORT_DIR}/report_timing_hold.${CORNER}.rpt {
  report_timing -delay_type min -nworst 1 -max_paths 30 -input_pins -capacitance -transition_time
}
redirect -file ${REPORT_DIR}/report_constraint_hold.${CORNER}.rpt { report_constraint -all_violators -min_delay }
puts "INFO: chip STA $CORNER complete. Reports in $REPORT_DIR"
exit
