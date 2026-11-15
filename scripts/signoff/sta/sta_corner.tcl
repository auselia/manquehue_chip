# PrimeTime sign-off STA of one corner: setup at slow and typical, hold at fast, as in common/mcmm.tcl
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: pt_shell -x "set CORNER ...; ...; source sta_corner.tcl"      (sta.sh does it for every corner)
# in:  CORNER, TOP, VLOG, SDC_FILE (the sign-off SDC), SPEF_FILE, SC_DB, IO_DB, SRAM_DB, REPORT_DIR
# out: REPORT_DIR/report_*.<corner>.rpt, and <TOP>.typical.sdf for the gate-level simulation with timing
#
# About 330 RC-005 warnings per corner, all on the clock net ZCTSNET_114 (415 sinks): its SPEF is a clean tree,
# and PrimeTime and Fusion Compiler agree on its slack.
source [file dirname [info script]]/pt_design.tcl
require {CORNER TOP VLOG SDC_FILE SPEF_FILE SC_DB IO_DB SRAM_DB REPORT_DIR}
file mkdir $REPORT_DIR

read_design
read_sdc $SDC_FILE
# The SDC of Fusion Compiler has the SCLK gating constraint only for a netlist that Fusion Compiler built
source [file dirname [info script]]/../../common/sclk_gating.tcl
source [file dirname [info script]]/../../common/sram_derate.tcl
sram_derate $CORNER
read_parasitics -format SPEF $SPEF_FILE
update_timing -full

redirect -file ${REPORT_DIR}/check_timing.${CORNER}.rpt { check_timing }
redirect -file ${REPORT_DIR}/report_clock.${CORNER}.rpt { report_clock -attribute }
redirect -file ${REPORT_DIR}/report_drv.${CORNER}.rpt {
  report_constraint -all_violators -max_transition -max_capacitance -max_fanout
}

if { $CORNER == "slow" || $CORNER == "typical" } {
  redirect -file ${REPORT_DIR}/report_timing_setup.${CORNER}.rpt {
    report_timing -delay_type max -nworst 5 -max_paths 20 -input_pins -capacitance -transition_time
  }
  redirect -file ${REPORT_DIR}/report_constraint_setup.${CORNER}.rpt {
    report_constraint -all_violators -max_delay_groups
  }
  redirect -file ${REPORT_DIR}/report_qor.${CORNER}.rpt { report_qor }
}

if { $CORNER == "fast" } {
  redirect -file ${REPORT_DIR}/report_timing_hold.${CORNER}.rpt {
    report_timing -delay_type min -nworst 5 -max_paths 20 -input_pins -capacitance -transition_time
  }
  redirect -file ${REPORT_DIR}/report_constraint_hold.${CORNER}.rpt {
    report_constraint -all_violators -min_delay_groups
  }
  redirect -file ${REPORT_DIR}/report_qor.${CORNER}.rpt { report_qor }
}

if { $CORNER == "typical" } {
  write_sdf -version 3.0 -significant_digits 3 ${REPORT_DIR}/${TOP}.typical.sdf
}

puts "INFO: $CORNER STA complete. Reports in $REPORT_DIR"
