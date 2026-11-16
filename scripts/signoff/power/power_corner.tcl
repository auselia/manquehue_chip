# PrimePower analysis of one corner: the setup of the STA, switching activity, power reports
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: pt_shell -x "set CORNER ...; ...; source power_corner.tcl"      (power.sh does it)
# in:  CORNER, TOP, VLOG, SDC_FILE, SPEF_FILE, SC_DB, IO_DB, SRAM_DB, REPORT_DIR, PP_TOGGLE_RATE, PP_STATIC_PROB,
#      PP_SAIF (empty: vectorless)
# out: REPORT_DIR/report_switching_activity, report_power_summary, report_power_hierarchy, report_power_top_cells
#
# A vectorless run is an early estimate, not sign-off power.
source [file dirname [info script]]/../sta/pt_design.tcl
require {CORNER TOP VLOG SDC_FILE SPEF_FILE SC_DB IO_DB SRAM_DB REPORT_DIR PP_TOGGLE_RATE PP_STATIC_PROB}
if { ![info exists PP_SAIF] } { set PP_SAIF "" }
file mkdir $REPORT_DIR

# The power commands run in plain pt_shell (pwr_shell has no read_verilog). They stop with PWR-001 without this.
set_app_var power_enable_analysis true

read_design
read_sdc $SDC_FILE
read_parasitics -format SPEF $SPEF_FILE
update_timing -full

# set_switching_activity gives about 17 PSW-161 warnings ("Instance '_sel74' can not be found"). The design has no
# such instance, and the activity is on the input ports (report_switching_activity).
if { $PP_SAIF != "" && [file exists $PP_SAIF] } {
  puts "INFO: $CORNER annotating real switching activity from $PP_SAIF"
  read_saif -input $PP_SAIF -instance_name "" -verbose
} else {
  puts "INFO: $CORNER no SAIF given -- vectorless default: toggle_rate=$PP_TOGGLE_RATE static_probability=$PP_STATIC_PROB on primary inputs"
  set_switching_activity -type inputs -toggle_rate $PP_TOGGLE_RATE -static_probability $PP_STATIC_PROB [all_inputs]
}
update_power

redirect -file ${REPORT_DIR}/report_switching_activity.${CORNER}.rpt { report_switching_activity }
redirect -file ${REPORT_DIR}/report_power_summary.${CORNER}.rpt { report_power }
redirect -file ${REPORT_DIR}/report_power_hierarchy.${CORNER}.rpt { report_power -hierarchy -levels 3 }
redirect -file ${REPORT_DIR}/report_power_top_cells.${CORNER}.rpt {
  report_power -leaf -cell_power -nworst 30 -sort_by total_power -area
}

puts "INFO: $CORNER power analysis complete. Reports in $REPORT_DIR"
