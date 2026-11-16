# Write the PrimeTime inputs of a run: SDC, sign-off SDC, scan SDC, SPEF of every corner
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: source in 06_finish.tcl after save_block, and in utils/pt_export.tcl
# in:  RUN_DIR, the finish block
# out: <run>/croc_soc.sdc, croc_soc_55ns.sdc, croc_soc_scan.sdc, croc_soc.<spef>.spef
# Sourced by 06_finish.tcl after save_block -as finish, and by scripts/utils/pt_export.tcl (make pt_export). Needs
# RUN_DIR, the run folder of the GDS and netlist. Writes:
#   <run>/<TOP>.sdc              mode func, propagated clocks, implementation period
#   <run>/<TOP>_55ns.sdc         the same at SPEC_PERIOD, for make sta-pt (only the clock period differs)
#   <run>/<TOP>_scan.sdc         mode scan, for make scan-sta
#   <run>/<TOP>.<spef>.spef      parasitics per corner (CORNER_<corner>_SPEF in config/corners.tcl)
#   <run>/<TOP>.spef_scenario    file-to-scenario map of FC (not read by PrimeTime)
# The PDK has one nxtgrd (typ). The three SPEF files still differ: the sheet resistance depends on the temperature.
# The script sets the sign-off hold uncertainty in the open block. After save_block, the saved block keeps the
# implementation values.

if { ![info exists RUN_DIR] || ![file isdirectory $RUN_DIR] } {
  puts "ERROR: export_signoff.tcl needs RUN_DIR, the run folder of the GDS and netlist."
  exit 1
}

set SDC_OUT  [file join $RUN_DIR "${TOP_MODULE}.sdc"]
set SDC_SCAN_OUT [file join $RUN_DIR "${TOP_MODULE}_scan.sdc"]
# Base name only: write_parasitics adds .<spec>_<temperature>.spef per corner (.typ_125.spef for slow).
set SPEF_BASE [file join $RUN_DIR "${TOP_MODULE}"]

# Sign off with the hold uncertainty of config/clocks.tcl (04_cts.tcl adds a margin while implementing).
foreach s [get_attribute [get_scenarios] -name name] {
  current_scenario $s
  set_clock_uncertainty -hold $HOLD_UNCERT      [get_clocks clock]
  set_clock_uncertainty -hold $JTAG_HOLD_UNCERT [get_clocks jtag_tck]
  # the extra hold margin at the SRAM clock pins of 04_cts.tcl is for implementation only
  set sram_clk [get_pins -quiet -of_objects [get_cells -quiet -hierarchical -filter "ref_name =~ gf180mcu_fd_ip_sram__*"] -filter "is_clock_pin == true"]
  if {[sizeof_collection $sram_clk] > 0} { catch {remove_clock_uncertainty -hold $sram_clk} }
}

# The constraints depend on the mode, not the corner: typical as a fixed choice.
current_scenario typical

# write_sdc writes set_propagated_clock (the clock tree of 04_cts.tcl) and also set_clock_latency with the
# useful-skew numbers of FC. In PrimeTime set_clock_latency turns a propagated clock back into an ideal one
# (UITE-305), so the SPEF clock tree would not count. -exclude clock_latency also drops set_propagated_clock.
# So the set_clock_latency lines are removed from the written file.
proc write_pt_sdc { sdc_out } {
  write_sdc -output $sdc_out

  set SDC_FH [open $sdc_out r]
  set SDC_LINES [split [read $SDC_FH] "\n"]
  close $SDC_FH
  set SDC_FH [open $sdc_out w]
  # The max transition limits at 0.9 x library of one scenario are for implementation: PrimeTime checks every corner
  # on its library limit. A dropped command takes all its lines with it: write_sdc continues a long pin list on new
  # lines inside braces, with no backslash, so the command ends where it is complete for Tcl.
  set dropped ""
  foreach line $SDC_LINES {
    if { $dropped != "" } {
      append dropped "\n" $line
      if { [info complete $dropped] } { set dropped "" }
      continue
    }
    if { [regexp {^(set_max_transition|set_clock_latency)\M} $line] } {
      if { ![info complete $line] } { set dropped $line }
      continue
    }
    puts $SDC_FH $line
  }
  close $SDC_FH
}

write_pt_sdc $SDC_OUT

# Sign-off constraints: the netlist is implemented at CLOCK_PERIOD and signed off at SPEC_PERIOD (config/clocks.tcl, AUS-9).
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

# Scan-shift constraints (mode `scan`) for make scan-sta, written the same way.
current_scenario scan_typical
write_pt_sdc $SDC_SCAN_OUT
current_scenario typical

# FC extraction of the routed and filled block (nxtgrd of tech_setup.tcl). With MCMM, one call writes one SPEF per
# corner.
write_parasitics -output $SPEF_BASE

# Report of the extracted parasitics, with the other reports of the build.
file mkdir [file join $RUN_DIR reports export_signoff]
redirect -file [file join $RUN_DIR reports export_signoff report_parasitics.rpt] { report_parasitics }

puts "INFO: Wrote SDC   -> $SDC_OUT"
puts "INFO: Wrote SDC   -> $SDC_SCAN_OUT (scan shift)"
foreach c $CORNERS {
  puts "INFO: Wrote SPEF  -> ${SPEF_BASE}.[set CORNER_${c}_SPEF].spef ($c)"
}
