###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Scan-shift constraints for croc_soc (mode `scan`)
###############################################################################
#
# Why this mode exists: in functional mode scan_se_i and testmode_i are pinned to 0, so the
# scan path (Q -> SI of the next flop) is not timed at all and clock_opt/route_opt never fix
# it. During shift scan_se_i = testmode_i = 1 and every flop captures its neighbour's Q one
# clock later, a pure flop-to-flop path with no logic, so hold is set by clock skew alone.
# Timing it here lets the same hold optimization that closes the functional paths close the
# shift paths. Only hold is checked in this mode (see mcmm.tcl); setup at the 100 ns shift
# period is not a concern.

current_mode scan

# Shift clocks. Names must stay `clock` and `jtag_tck`: 04_cts.tcl and common/export_signoff.tcl set the
# uncertainties by those names in every scenario. Period and waveforms are the ones declared to
# the DFT tool (set_dft_signal -type ScanClock in dft_scan.tcl): both clocks pulse inside one
# 100 ns shift cycle, clk_i at 50-70 ns and jtag_tck_i at 75-90 ns.
create_clock -name clock -period 100 -waveform {50 70} [get_ports clk_i]
create_clock -name jtag_tck -period 100 -waveform {75 90} [get_ports jtag_tck_i]

# Same margins as mode_func.tcl (hold only; setup is not analysed in this mode).
set_clock_uncertainty -mode scan -hold 0.25 [get_clocks clock]
set_clock_uncertainty -mode scan -hold 0.5  [get_clocks jtag_tck]
set_clock_transition 0.4 [get_clocks *]

# No set_clock_groups: unlike functional mode the two clocks are not asynchronous while
# shifting, the chain crosses between them (clock_mixing mix_clocks) and those paths must be
# timed against the waveforms above.

# Shift state.
set_case_analysis 1 [get_ports scan_se_i]
set_case_analysis 1 [get_ports testmode_i]

# Tester side of the chain: scan_si_i is launched and scan_so_o is captured by the clk_i domain.
set_input_delay  -clock clock 20.0 [get_ports scan_si_i]
set_output_delay -clock clock 20.0 [get_ports scan_so_o]

# Same drive and load as the functional scenarios, set in each scan scenario.
set previous_scenario [current_scenario]
foreach scenario_name {scan_slow scan_typical scan_fast} {
  current_scenario $scenario_name
  set_input_transition 0.3 [get_ports scan_si_i]
  set_load             0.2 [get_ports scan_so_o]
}
current_scenario $previous_scenario
