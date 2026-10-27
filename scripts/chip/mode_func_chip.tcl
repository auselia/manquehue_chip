###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Functional-mode constraints for the chip floorplan (chip_top, CHIP_FLOORPLAN=1)
###############################################################################
# Clocks on the chip pads, test mode off. The I/O delays at the pads are not constrained yet.

current_mode func

create_clock -name clock    -period $CLOCK_PERIOD [get_ports $CLOCK_PORT_NAME]
create_clock -name jtag_tck -period 100.0         [get_ports jtag_tck_i]
set_clock_groups -asynchronous -group clock -group jtag_tck

set_case_analysis 0 [get_ports testmode_i]
set_false_path -from [get_ports {rst_ni jtag_trst_ni}]

set_max_transition 1.5 [current_design]
set_max_capacitance 0.3 [current_design]
set_max_fanout 20 [current_design]
