# Constraints of the croc_soc macro for the open flow: the functional mode of scripts/common/mode_func.tcl of the
# Fusion Compiler flow, at the 55 ns signoff period, with the setup uncertainty of the signoff SDC.
set CLOCK_PERIOD      55.0
set JTAG_TCK_PERIOD  100.0
set IO_DELAY_FRAC      0.20

create_clock -name clock    -period $CLOCK_PERIOD     [get_ports clk_i]
create_clock -name jtag_tck -period $JTAG_TCK_PERIOD  [get_ports jtag_tck_i]

set_clock_uncertainty -setup 0.7 [get_clocks clock]
set_clock_uncertainty -hold  0.25 [get_clocks clock]
set_clock_uncertainty -setup 2.0 [get_clocks jtag_tck]
set_clock_uncertainty -hold  0.5 [get_clocks jtag_tck]
set_clock_transition 0.4 [get_clocks *]

# clk_i and jtag_tck_i have no phase relationship; the CDC in i_dmi_jtag handles the crossing
set_clock_groups -asynchronous -name async_domains -group [get_clocks clock] -group [get_clocks jtag_tck]

# functional mode
set_case_analysis 0 [get_ports testmode_i]

set_false_path -from [get_ports rst_ni]
set_false_path -from [get_ports jtag_trst_ni]

set IO_DELAY      [expr {$IO_DELAY_FRAC * $CLOCK_PERIOD}]
set JTAG_IO_DELAY [expr {$IO_DELAY_FRAC * $JTAG_TCK_PERIOD}]

set not_func_in [list clk_i jtag_tck_i rst_ni jtag_trst_ni testmode_i jtag_tdi_i jtag_tms_i]
set func_in [list]
foreach p [get_ports -filter "direction == input"] {
    if {[lsearch -exact $not_func_in [get_property $p name]] < 0} { lappend func_in $p }
}
set func_out [list]
foreach p [get_ports -filter "direction == output"] {
    if {[get_property $p name] ne "jtag_tdo_o"} { lappend func_out $p }
}
set_input_delay  -clock clock $IO_DELAY $func_in
set_output_delay -clock clock $IO_DELAY $func_out

# the TAP samples TDI/TMS on the rising edge of TCK and launches TDO on the falling edge
set_input_delay  -clock jtag_tck $JTAG_IO_DELAY [get_ports {jtag_tdi_i jtag_tms_i}]
set_output_delay -clock jtag_tck -clock_fall $JTAG_IO_DELAY [get_ports jtag_tdo_o]

set_input_transition 0.3 [all_inputs]
set_load 0.2 [all_outputs]

set_max_transition 1.5 [current_design]
set_max_capacitance 0.3 [current_design]
set_max_fanout 20 [current_design]
