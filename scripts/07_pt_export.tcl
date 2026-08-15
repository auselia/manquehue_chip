# -----------------------------------------------------------------------------
# 07_pt_export.tcl  --  signoff STA/power inputs for PrimeTime / PrimePower
#
# Everything upstream (01_read_rtl.tcl -> tech_setup.tcl -> mcmm.tcl) already
# builds the exact MCMM environment PrimeTime needs: 3 real corners (slow/
# typical/fast, see common/mcmm.tcl) and a real constraint set for mode `func`
# (common/mode_func.tcl). What was missing was exporting that environment as
# standalone files -- PrimeTime has no notion of FC's in-memory design.dlib,
# it only reads Verilog + Liberty + SDC + SPEF from disk.
#
# This step opens the already-finished, already-signed-off `finish` block
# (post stdcell-filler insertion, post final route_detail, post
# change_names -- i.e. exactly what 06_finish.tcl exports to GDS/Verilog) and
# writes the artifacts PT/PP need on top of that same GDS/Verilog:
#   <run>/<TOP>.sdc              -- mode `func` constraints, propagated clocks
#   <run>/<TOP>.typ_125.spef     -- parasitics for the `slow`    scenario (125C)
#   <run>/<TOP>.typ_25.spef      -- parasitics for the `typical` scenario ( 25C)
#   <run>/<TOP>.typ_-40.spef     -- parasitics for the `fast`    scenario (-40C)
#   <run>/<TOP>.spef_scenario    -- FC's own manifest mapping file->scenario
#                                    (kept for traceability, not read by PT)
#
# All three come from ONE write_parasitics call: mcmm.tcl assigns the same
# parasitic spec ("typ" -- the only nxtgrd this PDK kit ships, see pex/;
# there is no separate min/max RC corner deck) to every corner's
# -early_spec/-late_spec, but write_parasitics still extracts once per
# corner because sheet resistance is temperature-dependent -- the 125C/25C/
# -40C split above is real (if small) RC variation, not a copy-paste of one
# file. This is MORE accurate than reusing a single SPEF across corners
# would have been, and it fell out of just calling write_parasitics with
# MCMM active -- no extra looping needed here.
#
# Why here and not inside 06_finish.tcl: keeps the already-validated tapeout
# path (GDS/Verilog export) completely untouched. This step is purely
# additive and can be re-run / iterated on its own via `make pt_export`
# without touching 06_finish.tcl.
# -----------------------------------------------------------------------------

source [file dirname [info script]]/common/open_lib.tcl
open_block finish

# -----------------------------------------------------------------------------
# Locate this run's output folder (the one 06_finish.tcl just created and
# pointed outputs/latest at). Mirrors 06_finish.tcl's own OUTPUTS_DIR logic so
# the SDC/SPEF land right next to that run's GDS/Verilog.
# -----------------------------------------------------------------------------
set OUTPUTS_DIR [file normalize [file join [file dirname [info script]] .. outputs]]
set RUN_DIR      [file normalize [file join $OUTPUTS_DIR latest]]

if { ![file isdirectory $RUN_DIR] } {
  puts "ERROR: outputs/latest does not resolve to a run directory ($RUN_DIR)."
  puts "ERROR: Run 06_finish.tcl (make finish) before make pt_export."
  exit 1
}

set SDC_OUT  [file join $RUN_DIR "${TOP_MODULE}.sdc"]
# Base name only (no .spef extension): write_parasitics appends
# .<spec>_<temperature>.spef per corner itself (e.g. .typ_125.spef for the
# 125C `slow` scenario) -- giving it an extension here would just double up
# ("croc_soc.typ.spef.typ_125.spef"), confirmed 2026-08-15.
set SPEF_BASE [file join $RUN_DIR "${TOP_MODULE}"]

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
write_sdc -output $SDC_OUT

set SDC_FH [open $SDC_OUT r]
set SDC_LINES [split [read $SDC_FH] "\n"]
close $SDC_FH
set SDC_FH [open $SDC_OUT w]
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

# Parasitics extracted from the exact routed+filled geometry using the tech
# already loaded via read_parasitic_tech (tech_setup.tcl). This is FC's own
# built-in extraction engine (not a standalone StarRC co-simulation pass --
# see /usr/synopsys/icvalidator/.../starrc/bin/StarXtract if higher fidelity
# is ever needed); it reads the same PDK-provided nxtgrd/layermap either way,
# so it is real geometric RC, not a wireload-model guess. With MCMM active,
# this single call writes one SPEF per corner (see header comment above).
write_parasitics -output $SPEF_BASE

set ACTIVE_STEP "07_pt_export"
source [file dirname [info script]]/common/reporting.tcl

puts "INFO: Wrote SDC   -> $SDC_OUT"
puts "INFO: Wrote SPEF  -> ${SPEF_BASE}.typ_125.spef (slow)"
puts "INFO: Wrote SPEF  -> ${SPEF_BASE}.typ_25.spef (typical)"
puts "INFO: Wrote SPEF  -> ${SPEF_BASE}.typ_-40.spef (fast)"

save_block -as pt_export
