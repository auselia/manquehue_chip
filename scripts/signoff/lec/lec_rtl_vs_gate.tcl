# Formality equivalence of the RTL (flists/croc.flist) and the final netlist of a run, in functional mode
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: fm_shell -x "set TOP ...; ...; source lec_rtl_vs_gate.tcl"      (run_lec.sh does it)
# in:  TOP, VLOG, FLIST, SC_DB, IO_DB, SRAM_DB, REPORT_DIR, SVF_FILE (the six SVF files in flow order)
# out: REPORT_DIR/report_verification_status.rpt and the other reports
#
# Scope: functional mode (testmode_i = 0 on both sides, scan_se_i = 0 on the netlist). The SRAMs are black boxes on
# both sides. The clock-gate latches and the scan ports stay unmatched.
# Both sides read the cell, IO and SRAM .db as technology libraries: the RTL instantiates library cells by name
# (tc_clk.sv) and the SRAM macro (tc_sram.sv). The SRAM simulation model does not parse in Formality (FMR_VLOG-206).
# Formality reports "guide_checkpoint rejected" and FM-632 for the SVF, and still uses its guides.

foreach name {TOP VLOG FLIST SC_DB IO_DB SRAM_DB REPORT_DIR SVF_FILE} {
  if { ![info exists $name] } {
    puts "ERROR: variable '$name' is not set. run_lec.sh sets it with fm_shell -x."
    exit 1
  }
}
set REPO_ROOT [file normalize [file join [file dirname [info script]] .. .. ..]]
file mkdir $REPORT_DIR

set_app_var verification_failing_point_limit 0   ;# the default stops after 20 failing points

# croc.flist has paths relative to work/ (../rtl): a copy with absolute paths goes into the report folder
set fh [open $FLIST]
set flist_text [read $fh]
close $fh
regsub -all {\.\./rtl} $flist_text "$REPO_ROOT/rtl" flist_text
set fh [open $REPORT_DIR/croc_abs.flist w]
puts $fh $flist_text
close $fh

puts "INFO: Using SVF guidance: $SVF_FILE"
set_svf -ordered $SVF_FILE

# One power domain and no UPF: the supply connections are the job of LVS. set_top stops without these (FM-565, FM-619).
set_app_var hdlin_error_on_supply_type_port false
set_app_var hdlin_allow_partial_pg_netlist true
# Undriven RTL signals (an unused OBI response slot) take the value that synthesis gives them, not a free value
set verification_set_undriven_signals SYNTHESIS
# The latch clock gates of Fusion Compiler are not in the RTL. Without this every flop behind a gate fails.
set_app_var verification_clock_gate_hold_mode low

# Reference side: the RTL
read_db -r -technology_library $SC_DB
read_db -r -technology_library $IO_DB
read_db -r -technology_library $SRAM_DB
read_sverilog -r -vcs "-F $REPORT_DIR/croc_abs.flist"
# Known RTL ambiguities (unique/parallel_case overlap, array index out of range): set_top needs them as warnings
set_mismatch_message_filter -warn FMR_ELAB-116
set_mismatch_message_filter -warn FMR_ELAB-147
set_top r:/WORK/$TOP

set xbar_mgr4_rvalid [get_nets -exact -quiet {r:/WORK/croc_soc/i_croc/i_main_xbar/mgr_ports_rsp_i[4]\[rvalid]}]
if { [sizeof_collection $xbar_mgr4_rvalid] > 0 } {
  create_cutpoint_blackbox cut_unused_xbar_mgr4_rvalid $xbar_mgr4_rvalid
} else {
  puts "INFO: mgr_ports_rsp_i\[4\].rvalid not found (name changed, or SVF resolved it already) -- skipping cutpoint."
}
# testmode_i selects the reset synchronizer bypass (rstgen_bypass.sv): 0 in functional mode, as in mode_func.tcl
set testmode_ref [get_ports -quiet r:/WORK/croc_soc/testmode_i]
if { [sizeof_collection $testmode_ref] > 0 } { set_constant -type port $testmode_ref 0 }

# Implementation side: the netlist without supply pins and physical-only cells (lec_strip_pg.py)
read_db -i -technology_library $SC_DB
read_db -i -technology_library $IO_DB
read_db -i -technology_library $SRAM_DB
exec python3 $REPO_ROOT/scripts/utils/lec_strip_pg.py $VLOG $REPORT_DIR/netlist_lec.v
read_verilog -i -netlist $REPORT_DIR/netlist_lec.v
set_top i:/WORK/$TOP

set testmode_impl [get_ports -quiet i:/WORK/croc_soc/testmode_i]
if { [sizeof_collection $testmode_impl] > 0 } { set_constant -type port $testmode_impl 0 }
# Scan enable 0 on each side that has the port
foreach side {r i} {
  set scan_enable [get_ports -quiet ${side}:/WORK/$TOP/scan_se_i]
  if { [sizeof_collection $scan_enable] > 0 } { set_constant -type port $scan_enable 0 }
}

# Match and verify
match
redirect -file ${REPORT_DIR}/report_unmatched_points.rpt { report_unmatched_points }
redirect -file ${REPORT_DIR}/report_black_boxes.rpt { report_black_boxes }
# The SRAM VDD and VSS pins come from the .db on the RTL side only, and carry no logic
set_dont_verify_points -all_bbox_pgpins
verify

redirect -file ${REPORT_DIR}/report_verification_status.rpt { report_status }
redirect -file ${REPORT_DIR}/report_failing_points.rpt { report_failing_points }
redirect -file ${REPORT_DIR}/report_passing_points.rpt { report_passing_points }
redirect -file ${REPORT_DIR}/analyze_points_failing.rpt { analyze_points -failing -effort high }

puts "INFO: Formality RTL-vs-gate LEC complete. Reports in $REPORT_DIR"
