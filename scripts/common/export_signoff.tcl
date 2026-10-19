# -----------------------------------------------------------------------------
# export_signoff.tcl  --  sign-off STA/power inputs for PrimeTime / PrimePower
#
# Sourced by 06_finish.tcl after `save_block -as finish`, and by scripts/utils/pt_export.tcl (make pt_export, to
# write the files again from the saved finish block). Needs $RUN_DIR, the run folder of the GDS and netlist.
#
# PrimeTime has no notion of FC's design library, it reads Verilog + Liberty + SDC + SPEF from disk. The MCMM
# environment of the flow (3 corners slow/typical/fast, common/mcmm.tcl, and mode `func`, common/mode_func.tcl)
# is written next to the GDS/Verilog:
#   <run>/<TOP>.sdc              -- mode `func` constraints, propagated clocks (implementation period)
#   <run>/<TOP>_55ns.sdc         -- the same at the sign-off period SPEC_PERIOD (only the clock period differs)
#   <run>/<TOP>_scan.sdc         -- mode `scan` (scan shift), for make scan-sta
#   <run>/<TOP>.typ_125.spef     -- parasitics for the `slow`    scenario (125C)
#   <run>/<TOP>.typ_25.spef      -- parasitics for the `typical` scenario ( 25C)
#   <run>/<TOP>.typ_-40.spef     -- parasitics for the `fast`    scenario (-40C)
#   <run>/<TOP>.spef_scenario    -- FC's own manifest mapping file->scenario
#                                    (kept for traceability, not read by PT)
#
# All three SPEF files come from ONE write_parasitics call: mcmm.tcl assigns the same parasitic spec ("typ", the
# only nxtgrd this PDK kit ships, see pex/) to every corner, but write_parasitics still extracts once per corner
# because sheet resistance is temperature-dependent, so the 125C/25C/-40C split is real (if small) RC variation.
#
# It changes the hold uncertainty of the in-memory block to the sign-off value. 06_finish.tcl sources it after
# save_block, so the saved finish block keeps the implementation constraints.
# -----------------------------------------------------------------------------

if { ![info exists RUN_DIR] || ![file isdirectory $RUN_DIR] } {
  puts "ERROR: export_signoff.tcl needs RUN_DIR, the run folder of the GDS and netlist."
  exit 1
}

set SDC_OUT  [file join $RUN_DIR "${TOP_MODULE}.sdc"]
set SDC_SCAN_OUT [file join $RUN_DIR "${TOP_MODULE}_scan.sdc"]
# Base name only (no .spef extension): write_parasitics appends
# .<spec>_<temperature>.spef per corner itself (e.g. .typ_125.spef for the
# 125C `slow` scenario) -- giving it an extension here would just double up
# ("croc_soc.typ.spef.typ_125.spef"), confirmed 2026-08-15.
set SPEF_BASE [file join $RUN_DIR "${TOP_MODULE}"]

# Sign off with the real hold uncertainty from mode_func.tcl (04_cts.tcl added 0.1 ns while implementing).
foreach s [get_attribute [get_scenarios] -name name] {
  current_scenario $s
  set_clock_uncertainty -hold 0.25 [get_clocks clock]
  set_clock_uncertainty -hold 0.5  [get_clocks jtag_tck]
}

# Constraints are mode-based, not corner-based (mode_func.tcl has no
# per-corner logic), so which scenario is "current" doesn't change what
# write_sdc emits -- picked `typical` for a well-defined, deterministic
# context rather than whatever scenario happened to be current last.
current_scenario typical

# write_sdc emits set_propagated_clock for any clock FC has already
# propagated -- true here since clock_opt (04_cts.tcl) builds and propagates
# the real clock tree, and that state persists through route/finish. Without
# this PrimeTime would fall back to ideal (zero-latency) clocks and report
# fiction, exactly like the pre-drive/load I/O delays mode_func.tcl's own
# header comment warns about.
#
# FC's write_sdc also emits set_clock_latency on `clock`/`jtag_tck` (its own
# useful-skew optimization numbers, "-origin useful_skew" in the comment
# above each line) IN ADDITION TO set_propagated_clock. Per PrimeTime's own
# docs (UITE-305), directly setting clock network latency on an already-
# propagated clock silently converts it back to an IDEAL clock -- PT then
# uses that one fixed FC-internal number for every flop instead of computing
# real per-path latency/skew from the SPEF-annotated clock tree, which is
# the entire point of feeding it real parasitics. Confirmed 2026-08-15: left
# in, every PT corner run logged "Converting a propagated clock 'clock' to
# an ideal clock." write_sdc's own `-exclude clock_latency` is too blunt a
# fix -- confirmed 2026-08-15 it strips set_propagated_clock too (FC files
# both under the same internal category), which is worse: an SDC with
# NEITHER directive defaults every clock to ideal/zero-latency, the exact
# "fiction" the comment above warns about. So write_sdc runs plain, and the
# set_clock_latency lines are stripped from the file afterward, leaving
# set_propagated_clock as the only network-delay directive PT sees -- that's
# what makes its clock analysis genuinely SPEF-driven (real per-path latency
# and skew from the routed tree) instead of a copy of FC's own number.
proc write_pt_sdc { sdc_out } {
  write_sdc -output $sdc_out

  set SDC_FH [open $sdc_out r]
  set SDC_LINES [split [read $SDC_FH] "\n"]
  close $SDC_FH
  set SDC_FH [open $sdc_out w]
  set SKIP_CONTINUATION 0
  foreach line $SDC_LINES {
    if { [regexp {^set_clock_latency\M} $line] } {
      set SKIP_CONTINUATION [expr {[string index $line end] == "\\"}]
      continue
    }
    if { $SKIP_CONTINUATION } {
      set SKIP_CONTINUATION [expr {[string index $line end] == "\\"}]
      continue
    }
    puts $SDC_FH $line
  }
  close $SDC_FH
}

write_pt_sdc $SDC_OUT

# Sign-off constraints: the netlist is implemented at CLOCK_PERIOD and signed off at SPEC_PERIOD (setup.tcl, AUS-9).
# Only the period and the 50 % waveform of `clock` change. The input and output delays keep the values they have
# at the implementation period. PrimeTime setup (make sta-pt) and the timing models read this file.
set SPEC_STR [format %g $SPEC_PERIOD]
set SPEC_SDC [file join $RUN_DIR "${TOP_MODULE}_${SPEC_STR}ns.sdc"]
set SDC_FH [open $SDC_OUT r]
set SDC_TEXT [read $SDC_FH]
close $SDC_FH
set N_CLK [regsub {create_clock -name clock -period [0-9.]+ -waveform \{0 [0-9.]+\}} $SDC_TEXT \
  "create_clock -name clock -period $SPEC_STR -waveform {0 [format %g [expr {$SPEC_PERIOD / 2.0}]]}" SDC_SPEC_TEXT]
if { $N_CLK != 1 } {
  puts "ERROR: expected one 'create_clock -name clock' line in $SDC_OUT, found $N_CLK."
  exit 1
}
set SDC_FH [open $SPEC_SDC w]
puts -nonewline $SDC_FH $SDC_SPEC_TEXT
close $SDC_FH
puts "INFO: sign-off SDC at $SPEC_STR ns -> $SPEC_SDC"

# Scan-shift constraints (mode `scan`: scan_se_i = testmode_i = 1, shift waveforms), written the same
# way for the scan-mode PrimeTime check. The functional sign-off keeps using ${TOP_MODULE}.sdc.
current_scenario scan_typical
write_pt_sdc $SDC_SCAN_OUT
current_scenario typical

# Parasitics extracted from the exact routed+filled geometry using the tech
# already loaded via read_parasitic_tech (tech_setup.tcl). This is FC's own
# built-in extraction engine (not a standalone StarRC co-simulation pass --
# see /usr/synopsys/icvalidator/.../starrc/bin/StarXtract if higher fidelity
# is ever needed); it reads the same PDK-provided nxtgrd/layermap either way,
# so it is real geometric RC, not a wireload-model guess. With MCMM active,
# this single call writes one SPEF per corner (see header comment above).
write_parasitics -output $SPEF_BASE

# Report of the extracted parasitics, with the other reports of the build.
file mkdir [file join $RUN_DIR reports export_signoff]
redirect -file [file join $RUN_DIR reports export_signoff report_parasitics.rpt] { report_parasitics }

puts "INFO: Wrote SDC   -> $SDC_OUT"
puts "INFO: Wrote SDC   -> $SDC_SCAN_OUT (scan shift)"
puts "INFO: Wrote SPEF  -> ${SPEF_BASE}.typ_125.spef (slow)"
puts "INFO: Wrote SPEF  -> ${SPEF_BASE}.typ_25.spef (typical)"
puts "INFO: Wrote SPEF  -> ${SPEF_BASE}.typ_-40.spef (fast)"
