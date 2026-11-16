# Step 4: clock tree synthesis and clock optimization
# Author: Viktor Schneider (IMS, Leibniz University Hannover). Adapted by Nicolás Villegas - Universidad de los Andes
# usage: make cts      (fc_shell in work/)
# in:  block synthesis
# out: block cts
source [file dirname [info script]]/lib/open_lib.tcl
open_block synthesis

source $CONFIG_DIR/sdc/design_rules.tcl
design_rules

# The clock uncertainty after CTS, and a larger hold margin while implementing (config/clocks.tcl).
# lib/export_signoff.tcl writes the sign-off hold values.
foreach s [get_attribute [get_scenarios] -name name] {
  current_scenario $s
  set_clock_uncertainty -setup $SETUP_UNCERT_CTS [get_clocks clock]
  set_clock_uncertainty -hold $HOLD_UNCERT_IMPL [get_clocks clock]
  set_clock_uncertainty -hold $JTAG_HOLD_UNCERT_IMPL [get_clocks jtag_tck]
}

# The SRAM clock pins get a larger hold margin while implementing. lib/export_signoff.tcl removes it.
set SRAM_CLK_PINS [get_pins -quiet -of_objects [get_cells -quiet -hierarchical -filter "ref_name =~ gf180mcu_fd_ip_sram__*"] -filter "is_clock_pin == true"]
if {[sizeof_collection $SRAM_CLK_PINS] > 0} {
  foreach s [get_attribute [get_scenarios] -name name] {
    current_scenario $s
    set_clock_uncertainty -hold $SRAM_HOLD_UNCERT_IMPL $SRAM_CLK_PINS
  }
}

# The ADC SCLK mux is in gates now: no clock gating check on it
source $CONFIG_DIR/sdc/sclk_gating.tcl

# The cells kept out of synthesis may fix hold now. CTS uses only the clock cells of CTS_CELLS.
set_lib_cell_purpose -include {hold optimization} [get_lib_cells $SYN_IGNORE_CELLS]
set_lib_cell_purpose -exclude cts [get_lib_cells]
set_lib_cell_purpose -include cts [get_lib_cells $CTS_CELLS]

set_app_options -name clock_opt.flow.enable_clock_power_recovery      -value false
set_app_options -name cts.optimize.enable_area_recovery_in_local_skew -value false

clock_opt

set ACTIVE_STEP "04_cts"
source [file dirname [info script]]/lib/reporting.tcl

save_block -as cts