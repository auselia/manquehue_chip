###############################################################################
# Croc SoC Sign-off
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Formality equivalence of the RTL (croc.flist) and the final netlist (called by run_lec.sh)
###############################################################################

# What it needs:
#   - SVF_FILE: the SVF of all six FC sessions (read_rtl to finish) in flow order. It records the phase-inverted
#     flops and the merged and removed registers. Formality still reports "guide_checkpoint rejected" and FM-632
#     and uses the guides anyway.
#   - lec_strip_pg.py: the netlist without PG ports, PG pins and fill cells.
#   - verification_failing_point_limit 0, verification_clock_gate_hold_mode low (232 FC clock-gate latches),
#     set_dont_verify_points -all_bbox_pgpins (the SRAM supply pins).
# Scope: functional mode (testmode_i = 0 on both sides, scan_se_i = 0 on the netlist). The SRAMs are black boxes
# on both sides. The clock-gate latches and the scan ports stay unmatched.
#
# Both sides read the standard-cell, IO and SRAM .db (typical) as technology libraries: the RTL instantiates
# library cells by name (tc_clk.sv) and the SRAM macro (tc_sram.sv). The SRAM simulation model does not parse in
# Formality (FMR_VLOG-206), so the SRAM comes from its .db, a black box with no function.
###############################################################################

foreach v {TOP VLOG FLIST SC_DB IO_DB SRAM_DB REPORT_DIR} {
  if { ![info exists $v] } {
    puts "ERROR: required variable '$v' not set -- see header comment in [info script]."
    exit 1
  }
}
if { ![info exists SVF_FILE] } { set SVF_FILE "" }
# Scan enable, held at 0. scan_se_i is only in the netlist. For a netlist from before the dedicated scan ports,
# set SCAN_SE gpio_i\[1\] (that port is on both sides).
if { ![info exists SCAN_SE] } { set SCAN_SE scan_se_i }

# The default stops after 20 failing points and leaves the rest unverified. 0 = no limit.
set_app_var verification_failing_point_limit 0

file mkdir $REPORT_DIR

# croc.flist has paths relative to work/ (../rtl). Write a copy with absolute paths into the report folder.
set REPO_ROOT [file normalize [file join [file dirname [info script]] .. .. ..]]
# LEC_REL_FLIST 1 keeps the flist as given (run from a folder one level below the repo, as FC's work/), so the
# file names match the ones in the SVF.
if { ![info exists LEC_REL_FLIST] || !$LEC_REL_FLIST } {
  set fh [open $FLIST]
  set flist_txt [read $fh]
  close $fh
  regsub -all {\.\./rtl} $flist_txt "$REPO_ROOT/rtl" flist_txt
  set fh [open $REPORT_DIR/croc_abs.flist w]
  puts $fh $flist_txt
  close $fh
  set FLIST $REPORT_DIR/croc_abs.flist
}

if { $SVF_FILE != "" } {
  puts "INFO: Using SVF guidance: $SVF_FILE"
  set_svf -ordered $SVF_FILE
}

# One power domain and no UPF: PG connectivity is the job of LVS. Without these two settings set_top stops on both
# sides (FM-565, FM-619).
set_app_var hdlin_error_on_supply_type_port false
set_app_var hdlin_allow_partial_pg_netlist true

# Undriven RTL signals (an unused OBI response slot) as synthesis treats them, not as free variables. This and the
# cutpoint and testmode_i constants below come from the time before the SVF. They only change values, not the
# matching, and they can be redundant now.
set verification_set_undriven_signals SYNTHESIS

# The 232 latch clock gates of FC are not in the RTL. Without this every flop behind a gate fails.
set_app_var verification_clock_gate_hold_mode low

# Optional, off by default, no effect with the SVF:
#   LEC_CONST_REG_X 1  registers that a constant keeps disabled give X (verification_propagate_const_reg_x)
#   LEC_MERGE_DUP 1    merge registers with the same inputs (verification_merge_duplicated_registers)
if { [info exists LEC_CONST_REG_X] && $LEC_CONST_REG_X } { set_app_var verification_propagate_const_reg_x true }
if { [info exists LEC_MERGE_DUP] && $LEC_MERGE_DUP } { set_app_var verification_merge_duplicated_registers true }

###############################################################################
# 1. Reference (RTL) side
###############################################################################
read_db -r -technology_library $SC_DB
read_db -r -technology_library $IO_DB
read_db -r -technology_library $SRAM_DB

read_sverilog -r -vcs "-F $FLIST"

# Expected RTL ambiguities (unique/parallel_case overlap, array index out of range). set_top needs them accepted.
set_mismatch_message_filter -warn FMR_ELAB-116
set_mismatch_message_filter -warn FMR_ELAB-147

set_top r:/WORK/$TOP

set XBAR_MGR4_RVALID [get_nets -exact -quiet {r:/WORK/croc_soc/i_croc/i_main_xbar/mgr_ports_rsp_i[4]\[rvalid]}]
if { [sizeof_collection $XBAR_MGR4_RVALID] > 0 } {
  create_cutpoint_blackbox cut_unused_xbar_mgr4_rvalid $XBAR_MGR4_RVALID
} else {
  puts "INFO: mgr_ports_rsp_i\[4\].rvalid not found (name changed, or SVF resolved it already) -- skipping cutpoint."
}

# testmode_i selects the reset synchronizer bypass (rstgen_bypass.sv). 0 in functional mode, as in mode_func.tcl.
set TESTMODE_R [get_ports -quiet r:/WORK/croc_soc/testmode_i]
if { [sizeof_collection $TESTMODE_R] > 0 } { set_constant -type port $TESTMODE_R 0 }

###############################################################################
# 2. Implementation (gate-level) side
###############################################################################
read_db -i -technology_library $SC_DB
read_db -i -technology_library $IO_DB
read_db -i -technology_library $SRAM_DB

# Remove the PG pins, PG ports and fill cells that the RTL does not have (see the script).
exec python3 $REPO_ROOT/scripts/utils/lec_strip_pg.py $VLOG $REPORT_DIR/netlist_lec.v
read_verilog -i -netlist $REPORT_DIR/netlist_lec.v

set_top i:/WORK/$TOP

set TESTMODE_I [get_ports -quiet i:/WORK/croc_soc/testmode_i]
if { [sizeof_collection $TESTMODE_I] > 0 } { set_constant -type port $TESTMODE_I 0 }

# Scan enable 0 on each side that has the port (always the netlist, the RTL only for a shared GPIO).
foreach side {r i} {
  set SE [get_ports -quiet ${side}:/WORK/$TOP/$SCAN_SE]
  if { [sizeof_collection $SE] > 0 } { set_constant -type port $SE 0 }
}

###############################################################################
# 3. Match + verify
###############################################################################
match

redirect -file ${REPORT_DIR}/report_unmatched_points.rpt { report_unmatched_points }
redirect -file ${REPORT_DIR}/report_black_boxes.rpt { report_black_boxes }

# The SRAM VDD and VSS pins are on the RTL side (from the .db) but not in the stripped netlist. No logic.
set_dont_verify_points -all_bbox_pgpins

verify

redirect -file ${REPORT_DIR}/report_verification_status.rpt { report_status }
redirect -file ${REPORT_DIR}/report_failing_points.rpt { report_failing_points }
redirect -file ${REPORT_DIR}/report_passing_points.rpt { report_passing_points }
redirect -file ${REPORT_DIR}/analyze_points_failing.rpt { analyze_points -failing -effort high }

puts "INFO: Formality RTL-vs-gate LEC complete. Reports in $REPORT_DIR"
