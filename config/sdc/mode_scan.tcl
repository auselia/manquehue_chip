# Constraints of the scan shift (mode scan): shift clocks, hold margins, shift state
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: source in lib/mcmm.tcl (the scan scenarios)
# in:  config/clocks.tcl
# out: the constraints of mode scan
# During shift every flop captures the Q of its neighbour one clock later, a flop-to-flop path with no logic.
# Only hold matters (clock skew), so only hold is checked (mcmm.tcl).

current_mode scan

# Shift clocks. Keep the names `clock` and `jtag_tck`: 04_cts.tcl and lib/export_signoff.tcl set the
# uncertainties by name. The waveforms are the ones of dft_scan.tcl: clk_i at 50-70 ns, jtag_tck_i at 75-90 ns of
# 100 ns.
create_clock -name clock -period 100 -waveform {50 70} [get_ports $CLOCK_PORT_NAME]
create_clock -name jtag_tck -period 100 -waveform {75 90} [get_ports $JTAG_TCK_PORT]

# Same hold margins as the functional mode (config/clocks.tcl).
set_clock_uncertainty -mode scan -hold $HOLD_UNCERT      [get_clocks clock]
set_clock_uncertainty -mode scan -hold $JTAG_HOLD_UNCERT [get_clocks jtag_tck]
set_clock_transition $CLOCK_IDEAL_TRAN [get_clocks *]

# No set_clock_groups: the chain crosses between the two clocks (mix_clocks), so these paths are timed.

# Shift state.
set_case_analysis 1 [get_ports scan_se_i]
set_case_analysis 1 [get_ports testmode_i]

# The tester launches scan_si_i and captures scan_so_o with clk_i.
set_input_delay  -clock clock 20.0 [get_ports scan_si_i]
set_output_delay -clock clock 20.0 [get_ports scan_so_o]

# Same drive and load as the functional scenarios.
set previous_scenario [current_scenario]
foreach scenario_name {scan_slow scan_typical scan_fast} {
  current_scenario $scenario_name
  set_input_transition 0.3 [get_ports scan_si_i]
  set_load             0.2 [get_ports scan_so_o]
}
current_scenario $previous_scenario
