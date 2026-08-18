###############################################################################
# scripts/pt/sta_corner.tcl -- PrimeTime signoff STA for ONE MCMM corner
#
# Runs a single, classic (non -multi_scenario) pt_shell session against one
# PVT corner: read netlist, link the corner's own liberty views, read the
# mode `func` SDC (shared across corners -- constraints don't vary by PVT),
# back-annotate that corner's SPEF, then report setup/hold.
#
# Why 3 separate pt_shell sessions instead of PT's own -multi_scenario mode:
# -multi_scenario is built for distributing scenarios across a farm (each
# scenario gets its own common_data/specific_data script pair and can run on
# a different host via -affinity). For 3 corners on one box that machinery
# buys nothing but extra script plumbing, so scripts/sta-pt (the Makefile
# target) just loops this script 3 times and diffs the worst slack. Same
# signoff math (each corner still gets its own fully independent link+SDC+
# SPEF), less to maintain.
#
# Why setup only for slow/typical and hold only for fast: mirrors the
# existing FC in-design MCMM setup in scripts/common/mcmm.tcl exactly
# (set_scenario_status ... {typical slow} for setup, {fast} for hold) --
# that split is the standard industry choice (setup is worst at the
# slowest/highest-delay corner, hold is worst at the fastest/lowest-delay
# corner) and was already validated for this design in FC; PT reproduces it
# rather than inventing a different convention.
#
# Known warning worth flagging (not silently ignored): PT logs ~330 RC-005
# "Failed to compute the RC network delay" warnings per corner, all on ONE
# net (ZCTSNET_114, driven by clock buffer ZCTSINV_41057_63026, ~415 CLK-pin
# sinks). Investigated 2026-08-15 by parsing that net's SPEF *RES graph
# directly: it is a clean spanning tree (414 resistors over 415 nodes, zero
# cycle-forming edges, every sink pin reachable from the driver) -- so this
# is NOT a malformed/looped extraction, it matches RC-005's documented
# "extremely under-driven network" cause (PT's delay-calc convergence
# threshold, not the RC data, is what's failing for this one unusually
# high-fanout CTS branch). Impact is bounded and cross-checked, not
# hand-waved: PT's resulting hold WNS at the fast corner (+0.10ns / +0.01ns
# jtag_tck) matches FC's own in-design QoR snapshot (Hold WNS: 0.01) almost
# exactly, and setup WNS at slow (-1.39ns) is within ~0.08ns of FC's -1.31ns
# -- both computed independently, from real per-path SPEF-derived clock
# latency (see the -exclude/no-clock_latency note in 07_pt_export.tcl for
# why that comparison is meaningful and not just two copies of the same
# number). If this ever needs tightening: split ZCTSINV_41057_63026's fanout
# with an extra CTS buffering level (04_cts.tcl), or extract with real
# standalone StarRC (-reduction options) instead of FC's built-in engine.
#
# Required Tcl variables (set via -x before sourcing this file):
#   CORNER      slow | typical | fast
#   TOP         design top module name
#   VLOG        gate-level Verilog netlist (outputs/<run>/<TOP>.v)
#   SDC_FILE    outputs/<run>/<TOP>.sdc
#   SPEF_FILE   outputs/<run>/<TOP>.typ_<temp>.spef for this corner
#   SC_DB       standard-cell liberty .db for this corner
#   IO_DB       IO-pad liberty .db for this corner
#   SRAM_DB     SRAM macro liberty .db (see header note below -- same file
#               reused across all 3 corners, this PDK kit ships only one)
#   REPORT_DIR  where to write this corner's .rpt files
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
# NOTE on SRAM_DB: this PDK kit ships exactly one SRAM characterization,
# gf180mcu_fd_ip_sram__sram512x8m8wm1__tt_025C_5v00 (nom_voltage 5.0V) -- no
# ss/ff corner views. This design's MCMM corners were switched to the
# 5.0V-nominal rail (2026-08-18, see scripts/common/mcmm.tcl), so this SRAM
# view now matches the rest of the design's actual operating voltage instead
# of being a mismatch against a 3.0/3.3/3.6V rail. Every corner below still
# links the SAME tt/25C/5V SRAM view, because SS/FF SRAM characterizations
# still don't exist in this PDK kit -- that part remains a real PDK-IP gap.
# If GlobalFoundries/a future kit ships ss/ff SRAM corners, swap SRAM_DB per
# corner exactly like SC_DB/IO_DB.
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
