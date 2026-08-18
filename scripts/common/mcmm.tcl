###########################################################
# MCMM configuration
###########################################################
remove_scenarios -all
remove_corners -all
remove_modes -all

###########################################################
# Create Corners 
# 
# Corners define combinations of process, voltage, and 
# temperature (PVT) conditions used for timing and power 
# analysis to ensure robust chip behavior under all scenarios.
#
# At least specifiy the following parameters:
#  - set_voltage
#  - set_temperature
###########################################################

# 5.0V-nominal rail (2026-08-18, switched from the 3.0/3.3/3.6V family this
# was previously set to -- gf180mcu_fd_sc_mcu7t5v0 ships all three voltage
# families in the same library, this design's actual target is 5V). This
# also makes the SRAM macro's characterization (gf180mcu_fd_ip_sram__
# sram512x8m8wm1__tt_025C_5v00, the only voltage this PDK kit ships for it)
# finally match the rest of the design instead of being the one 5V outlier
# on an otherwise 3.3V rail -- see scripts/pt/sta_corner.tcl and the
# Makefile's PT_SRAM_LIB comment for that history.
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
# Create Modes
#
# Modes represent different functional or operational 
# configurations of the design (e.g., functional, test, 
# low-power). Each mode may enable different clocks, resets, 
# or I/O behaviors for timing analysis.
# In this case we have only one mode:
#  - func (for normal operation)
###########################################################
create_mode func
# mode details are configured later in mode_func.tcl

###########################################################
# Create Scenarios
#
# Scenarios are a combination of one mode and a corners.
# Since we only have one mode func, we name them all by
# their mode.
###########################################################

create_scenario -name slow -mode func -corner slow
create_scenario -name typical -mode func -corner typical
create_scenario -name fast -mode func -corner fast

############################################################
# Additional setup for corners/modes/scenarios
############################################################

# Add information about parastitics to all corners
foreach_in_collection c [get_corners] {
    current_corner $c
    set_parasitic_parameters -early_spec ${LPE_SPEC} -late_spec ${LPE_SPEC}
}

set_scenario_status -all  -hold false -dynamic_power false -leakage_power false -cell_em false -signal_em false {typical slow}
set_scenario_status -none -hold true  -dynamic_power true  -leakage_power true  -cell_em true  -signal_em true  {fast}

# mode setup needs to know all scenarios
source [file dirname [info script]]/mode_func.tcl
