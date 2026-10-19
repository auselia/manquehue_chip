###############################################################################
# Croc SoC Sign-off
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: PrimePower analysis of one corner (called by make power-pp)
###############################################################################

# The same setup as sta_corner.tcl, then switching activity and power reports. make power-pp runs fast only by
# default (PP_CORNERS), the scenario with power analysis in mcmm.tcl: 5.5 V gives the highest switching and
# leakage power, more than the leakage drop at -40 C takes away.
#
# Without PP_SAIF the activity is vectorless: a default toggle rate and static probability on the primary inputs,
# which PrimePower propagates through the design. This is an early estimate, not sign-off power.
#
# Variables (set with -x before this file is sourced):
#   CORNER      slow | typical | fast
#   TOP         top module
#   VLOG        gate-level netlist, outputs/<run>/<TOP>.v
#   SDC_FILE    outputs/<run>/<TOP>.sdc
#   SPEF_FILE   outputs/<run>/<TOP>.typ_<temp>.spef of this corner
#   SC_DB       standard-cell .db of this corner
#   IO_DB       IO-pad .db of this corner
#   SRAM_DB     SRAM .db (the same tt view at all corners)
#   REPORT_DIR  folder for the reports of this corner
#   PP_TOGGLE_RATE   default toggle rate of the primary inputs (for example 0.1)
#   PP_STATIC_PROB   default static probability of the primary inputs (for example 0.5)
#   PP_SAIF          optional SAIF file, empty for the vectorless default
###############################################################################

foreach v {CORNER TOP VLOG SDC_FILE SPEF_FILE SC_DB IO_DB SRAM_DB REPORT_DIR \
           PP_TOGGLE_RATE PP_STATIC_PROB} {
  if { ![info exists $v] } {
    puts "ERROR: required variable '$v' not set -- see header comment in [info script]."
    exit 1
  }
}
if { ![info exists PP_SAIF] } { set PP_SAIF "" }

file mkdir $REPORT_DIR

# The power commands are in plain pt_shell (pwr_shell disables read_verilog). They stop with PWR-001 until this is
# true.
set_app_var power_enable_analysis true

###############################################################################
# 1. Libraries, design, constraints, parasitics (as in sta_corner.tcl)
###############################################################################
set link_library   "* $SC_DB $IO_DB $SRAM_DB"
set target_library "$SC_DB"

read_verilog $VLOG
current_design $TOP
link_design

read_sdc $SDC_FILE
read_parasitics -format SPEF $SPEF_FILE

update_timing -full

###############################################################################
# 2. Switching activity
###############################################################################
# Known warning: about 17 PSW-161 "Instance '_sel74' can not be found" from set_switching_activity. The design has
# no such instance, and the activity lands on the real input ports (report_switching_activity). Harmless.
if { $PP_SAIF != "" && [file exists $PP_SAIF] } {
  puts "INFO: $CORNER annotating real switching activity from $PP_SAIF"
  read_saif -input $PP_SAIF -instance_name "" -verbose
} else {
  puts "INFO: $CORNER no SAIF given -- vectorless default: toggle_rate=$PP_TOGGLE_RATE static_probability=$PP_STATIC_PROB on primary inputs"
  set_switching_activity -type inputs \
    -toggle_rate $PP_TOGGLE_RATE -static_probability $PP_STATIC_PROB \
    [all_inputs]
}

update_power

###############################################################################
# 3. Reports
###############################################################################
redirect -file ${REPORT_DIR}/report_switching_activity.${CORNER}.rpt {
  report_switching_activity
}

redirect -file ${REPORT_DIR}/report_power_summary.${CORNER}.rpt {
  report_power
}

redirect -file ${REPORT_DIR}/report_power_hierarchy.${CORNER}.rpt {
  report_power -hierarchy -levels 3
}

redirect -file ${REPORT_DIR}/report_power_top_cells.${CORNER}.rpt {
  report_power -leaf -cell_power -nworst 30 -sort_by total_power -area
}

puts "INFO: $CORNER power analysis complete. Reports in $REPORT_DIR"
