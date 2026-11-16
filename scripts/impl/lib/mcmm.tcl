# Corners, modes and scenarios: func and scan at every corner of config/corners.tcl, with their constraints
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: source in 01_read_rtl.tcl
# in:  CORNERS and CORNER_<corner>_* of config/corners.tcl, config/sdc/
# out: the scenarios slow, typical, fast and scan_<corner>
remove_scenarios -all
remove_corners -all
remove_modes -all

# Corners
# The corners and their PVT are in config/corners.tcl. The SRAM has a 5 V tt view only, the same one at every
# corner (signoff/sta/sta_corner.tcl).
foreach c $CORNERS {
    create_corner $c
    set_process_label [set CORNER_${c}_PROCESS]
    set_voltage [set CORNER_${c}_VOLTAGE]
    set_temperature [set CORNER_${c}_TEMPERATURE]
}


# Modes and scenarios
# func: normal operation (constraints in mode_func.tcl). scan: scan shift, further below.
create_mode func

foreach c $CORNERS {
    create_scenario -name $c -mode func -corner $c
}

# Same parasitic spec at every corner (the PDK ships one nxtgrd).
foreach_in_collection c [get_corners] {
    current_corner $c
    set_parasitic_parameters -early_spec ${LPE_SPEC} -late_spec ${LPE_SPEC}
}

set_scenario_status -all  -hold false -dynamic_power false -leakage_power false -cell_em false -signal_em false {typical slow}
set_scenario_status -none -hold true  -dynamic_power true  -leakage_power true  -cell_em true  -signal_em true  {fast}
# Design rules at the fast corner too: with -none they were off, and PrimeTime found most slew violations there.
set_scenario_status -max_transition true -max_capacitance true {fast}

# The SRAM has only a tt view: derated at the slow and fast corners (sram_derate.tcl). The derate belongs to the
# corner, so the scan scenarios below get it too.
source $CONFIG_DIR/sdc/sram_derate.tcl
foreach {s c} {slow slow fast fast} { current_scenario $s; sram_derate $c }

# mode_func.tcl constrains all scenarios that exist at this point
source $CONFIG_DIR/sdc/mode_func.tcl

# Scan mode
# The functional scenarios tie scan_se_i and testmode_i to 0, so the shift paths (Q to SI of the next flop) are
# not timed there. These scenarios time and fix hold on them at every corner. Setup, design rules and power are
# off: the shift period is 100 ns. They are created after mode_func.tcl, so its constraints stay on func.
create_mode scan

set scan_scenarios {}
foreach c $CORNERS {
    create_scenario -name scan_$c -mode scan -corner $c
    lappend scan_scenarios scan_$c
}

set_scenario_status $scan_scenarios -setup false -hold true \
  -max_transition false -max_capacitance false \
  -dynamic_power false -leakage_power false -cell_em false -signal_em false

source $CONFIG_DIR/sdc/mode_scan.tcl

current_scenario fast
