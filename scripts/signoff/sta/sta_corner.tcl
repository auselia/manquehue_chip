###############################################################################
# Croc SoC Sign-off
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: PrimeTime STA of one corner (called by make sta-pt for slow, typical and fast)
###############################################################################

# One pt_shell per corner, with that corner's libraries, the func SDC and that corner's SPEF. Setup at slow and
# typical, hold at fast, as in mcmm.tcl.
#
# Known warning: about 330 RC-005 per corner, all on ZCTSNET_114 (clock buffer ZCTSINV_41057_63026, 415 sinks).
# The SPEF of that net is a clean tree. RC-005 comes from the high fanout. PT and FC agree on its slack. To remove
# it, split that fanout in CTS (04_cts.tcl) or extract with StarRC.
#
# Variables (set with -x before this file is sourced):
#   CORNER      slow | typical | fast
#   TOP         top module
#   VLOG        gate-level netlist, outputs/<run>/<TOP>.v
#   SDC_FILE    outputs/<run>/<TOP>_55ns.sdc
#   SPEF_FILE   outputs/<run>/<TOP>.typ_<temp>.spef of this corner
#   SC_DB       standard-cell .db of this corner
#   IO_DB       IO-pad .db of this corner
#   SRAM_DB     SRAM .db (the same tt view at all corners)
#   REPORT_DIR  folder for the reports of this corner
###############################################################################

foreach v {CORNER TOP VLOG SDC_FILE SPEF_FILE SC_DB IO_DB SRAM_DB REPORT_DIR} {
  if { ![info exists $v] } {
    puts "ERROR: required variable '$v' not set -- see header comment in [info script]."
    exit 1
  }
}

file mkdir $REPORT_DIR

###############################################################################
# 1. Libraries
###############################################################################
# The PDK has only a tt SRAM view (25 C, 5.0 V), so every corner links the same one. If ss and ff views come,
# give SRAM_DB per corner as SC_DB and IO_DB.
set link_library   "* $SC_DB $IO_DB $SRAM_DB"
set target_library "$SC_DB"

###############################################################################
# 2. Design
###############################################################################
read_verilog $VLOG
current_design $TOP
link_design

###############################################################################
# 3. Constraints + parasitics
###############################################################################
read_sdc $SDC_FILE
read_parasitics -format SPEF $SPEF_FILE

update_timing -full

###############################################################################
# 4. Reports
###############################################################################
redirect -file ${REPORT_DIR}/check_timing.${CORNER}.rpt { check_timing }
redirect -file ${REPORT_DIR}/report_clock.${CORNER}.rpt { report_clock -attribute }

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

puts "INFO: $CORNER STA complete. Reports in $REPORT_DIR"
