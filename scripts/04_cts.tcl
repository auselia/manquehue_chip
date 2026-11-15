# -----------------------------------------------------------------------------
# This file was created at the Institute of Microelectronic Systems,
# Leibniz University Hannover. It is provided "as is" without
# warranty of any kind, express or implied, including but not
# limited to correctness or fitness for a particular purpose.
#
# Author: Viktor Schneider
# -----------------------------------------------------------------------------

source [file dirname [info script]]/common/open_lib.tcl
open_block synthesis

# design rules of every scenario (common/design_rules.tcl)
source [file dirname [info script]]/common/design_rules.tcl
design_rules

# Clock uncertainty from CTS on, and the extra hold margins while implementing (config/clocks.tcl).
# common/export_signoff.tcl writes the sign-off hold values.
foreach s [get_attribute [get_scenarios] -name name] {
  current_scenario $s
  set_clock_uncertainty -setup $SETUP_UNCERT_CTS [get_clocks clock]
  set_clock_uncertainty -hold $HOLD_UNCERT_IMPL [get_clocks clock]
  set_clock_uncertainty -hold $JTAG_HOLD_UNCERT_IMPL [get_clocks jtag_tck]
}

# SRAM clock pins: a larger hold margin while implementing. export_signoff.tcl removes it.
set SRAM_CLK_PINS [get_pins -quiet -of_objects [get_cells -quiet -hierarchical -filter "ref_name =~ gf180mcu_fd_ip_sram__*"] -filter "is_clock_pin == true"]
if {[sizeof_collection $SRAM_CLK_PINS] > 0} {
  foreach s [get_attribute [get_scenarios] -name name] {
    current_scenario $s
    set_clock_uncertainty -hold $SRAM_HOLD_UNCERT_IMPL $SRAM_CLK_PINS
  }
}

# the ADC SCLK mux is in gates now: no clock gating check on it (common/sclk_gating.tcl)
source [file dirname [info script]]/common/sclk_gating.tcl

# remove early synthesis constraints
set_lib_cell_purpose -include {hold optimization} [get_lib_cells $SYN_IGNORE_CELLS]

# set cells for CTS
set_lib_cell_purpose -exclude cts [get_lib_cells]
set_lib_cell_purpose -include cts [get_lib_cells $CTS_CELLS]

set_app_options -name clock_opt.flow.enable_clock_power_recovery      -value false
set_app_options -name cts.optimize.enable_area_recovery_in_local_skew -value false

clock_opt
# clock_opt connects every IO cell to VDD: the DC-DC segments of the pad ring get their supplies back
if {$CHIP_FLOORPLAN} {
    source [file dirname [info script]]/chip/chip_pg_pads.tcl
    chip_connect_pads
    chip_float_dcdc_pins
}

set ACTIVE_STEP "04_cts"
source [file dirname [info script]]/common/reporting.tcl

save_block -as cts