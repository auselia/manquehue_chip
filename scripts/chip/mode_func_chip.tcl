###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Functional-mode constraints for the chip floorplan (chip_top, CHIP_FLOORPLAN=1)
###############################################################################

current_mode func

# The constraints of chip-level sign-off (chip_sta.sdc: clocks on the pads, ADC SCLK and QSPI SCK, board I/O delays,
# design rules in every scenario), at the implementation period. Before, this mode had only the two clocks and one
# scenario with design rules, while PrimeTime signed off with the full SDC.
set CHIP_SDC_PERIOD $CLOCK_PERIOD
source [file dirname [info script]]/chip_sta.sdc
