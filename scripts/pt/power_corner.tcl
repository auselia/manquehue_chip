###############################################################################
# scripts/pt/power_corner.tcl -- PrimePower analysis for ONE MCMM corner
#
# Same link/read_verilog/link_design/read_sdc/read_parasitics setup as
# scripts/pt/sta_corner.tcl (see that file's header for why 3 separate
# classic pwr_shell sessions instead of -multi_scenario), then adds
# switching-activity setup and power reporting on top.
#
# Which corner(s) actually get run is a Makefile decision (PP_CORNERS,
# default "fast" only) that mirrors scripts/common/mcmm.tcl's own
# set_scenario_status exactly: mcmm.tcl enables dynamic_power/leakage_power
# ONLY for the `fast` scenario (disabled for typical/slow) -- that's the
# existing, already-validated FC in-design convention for this design, not a
# new choice made here. `fast` = FF/5.5V/-40C: highest voltage in the MCMM
# set (5.0V-nominal rail, switched 2026-08-18 -- see scripts/common/
# mcmm.tcl), which dominates both switching power (P ~ CV^2f) and leakage current
# (roughly exponential in V) enough to outweigh the low-temperature leakage
# reduction, so it is the right worst-case power corner despite not being
# the highest-temperature one.
#
# Vectorless (statistical) switching activity, not simulation-derived: this
# environment has no gate-level VCD/SAIF from a real workload run yet (sim/
# only has scripts + sw sources, no captured activity dump). Default input
# toggle rate / static probability are applied to primary inputs and
# propagated through the design by PrimePower's own algorithm; registers and
# internal nets get their activity from that propagation, not from observed
# switching. This is a real, standard PrimePower analysis mode (it is what
# "vectorless power estimation" means), but it is an early/averaged
# estimate, not simulation-derived signoff power -- flagged explicitly in
# the session summary. Set PP_SAIF to a real activity file to upgrade this
# once one exists (see the read_saif branch below).
#
# Required Tcl variables (set via -x before sourcing this file):
#   CORNER      slow | typical | fast
#   TOP         design top module name
#   VLOG        gate-level Verilog netlist (outputs/<run>/<TOP>.v)
#   SDC_FILE    outputs/<run>/<TOP>.sdc
#   SPEF_FILE   outputs/<run>/<TOP>.typ_<temp>.spef for this corner
#   SC_DB       standard-cell liberty .db for this corner
#   IO_DB       IO-pad liberty .db for this corner
#   SRAM_DB     SRAM macro liberty .db (same file reused across all 3
#               corners -- see sta_corner.tcl's header note; this PDK kit
#               ships only one SRAM characterization)
#   REPORT_DIR  where to write this corner's .rpt files
#   PP_TOGGLE_RATE     default primary-input toggle rate (e.g. 0.1)
#   PP_STATIC_PROB     default primary-input static probability (e.g. 0.5)
#   PP_SAIF            optional: path to a real SAIF activity file; empty
#                       string means "use the vectorless default above"
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

# Power commands exist in plain pt_shell (same binary family as PrimeTime --
# confirmed 2026-08-15 report_power/set_switching_activity/update_power are
# all present without -multi_scenario or the separate pwr_shell launcher;
# pwr_shell in fact disables read_verilog, so it expects to attach to an
# already-built session rather than start one), but every power command
# errors with PWR-001 "Power analysis is disabled" until this is set true.
set_app_var power_enable_analysis true

###############################################################################
# 1. Libraries, design, constraints, parasitics -- identical to sta_corner.tcl
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
# Known warning worth flagging: the vectorless set_switching_activity call
# below logs ~17 "Instance '_sel74' can not be found in netlist" (PSW-161)
# plus one informational note about -type no longer expanding
# hierarchically. Investigated 2026-08-15: this is NOT applying activity to
# the wrong objects in THIS design -- [all_inputs] still resolves to the
# real primary input ports (confirmed: report_switching_activity shows
# non-zero, sane toggle rates on them, and the resulting power numbers are
# non-zero/plausible with clock_network dominating as expected for a
# default-activity estimate). "_sel74" looks like a generic internal/
# library-default lookup PT/PP attempts regardless of design (croc_soc has
# no cell or net by that name at all -- grep the netlist yourself to check),
# not something this design or this script did wrong. Harmless as observed;
# revisit only if a future PT version's release notes mention PSW-161
# meaning something design-specific.
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
