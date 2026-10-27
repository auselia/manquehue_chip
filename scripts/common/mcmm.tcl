###########################################################
# MCMM configuration
###########################################################
remove_scenarios -all
remove_corners -all
remove_modes -all

###########################################################
# Corners
###########################################################
# 5 V rail (4.5 / 5.0 / 5.5 V). The SRAM has a 5 V tt view only, the same one at every corner
# (scripts/signoff/sta/sta_corner.tcl).
create_corner slow
set_process_label ss
set_voltage 4.5
set_temperature 125

create_corner typical
set_process_label tt
set_voltage 5.0
set_temperature 25


create_corner fast
set_process_label ff
set_voltage 5.5
set_temperature -40


###########################################################
# Modes and scenarios
###########################################################
# func: normal operation (constraints in mode_func.tcl). scan: scan shift, further below.
create_mode func

create_scenario -name slow -mode func -corner slow
create_scenario -name typical -mode func -corner typical
create_scenario -name fast -mode func -corner fast

# Same parasitic spec at every corner (the PDK ships one nxtgrd).
foreach_in_collection c [get_corners] {
    current_corner $c
    set_parasitic_parameters -early_spec ${LPE_SPEC} -late_spec ${LPE_SPEC}
}

set_scenario_status -all  -hold false -dynamic_power false -leakage_power false -cell_em false -signal_em false {typical slow}
set_scenario_status -none -hold true  -dynamic_power true  -leakage_power true  -cell_em true  -signal_em true  {fast}

# mode_func.tcl constrains all scenarios that exist at this point. The chip floorplan has its own constraints and no
# scan mode (no scan ports yet).
if {$CHIP_FLOORPLAN} {
    source [file dirname [info script]]/mode_func_chip.tcl
    current_scenario fast
    return
}
source [file dirname [info script]]/mode_func.tcl

###########################################################
# Scan mode
###########################################################
# The functional scenarios tie scan_se_i and testmode_i to 0, so the shift paths (Q to SI of the next flop) are
# not timed there. These scenarios time and fix hold on them at every corner. Setup, design rules and power are
# off: the shift period is 100 ns. They are created after mode_func.tcl, so its constraints stay on func.
create_mode scan

create_scenario -name scan_slow    -mode scan -corner slow
create_scenario -name scan_typical -mode scan -corner typical
create_scenario -name scan_fast    -mode scan -corner fast

set_scenario_status {scan_slow scan_typical scan_fast} -setup false -hold true \
  -max_transition false -max_capacitance false \
  -dynamic_power false -leakage_power false -cell_em false -signal_em false

source [file dirname [info script]]/mode_scan.tcl

current_scenario fast
