###############################################################################
# Croc SoC Chip
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: SPEF of the routed chip for chip-level PrimeTime STA (make chip-sta)
###############################################################################

# Opens the finish block of work/chip.dlib read-only and writes one SPEF per corner next to the chip netlist:
# outputs/chip_final/chip_top.<spec>_<temperature>.spef (typ_125 slow, typ_25 typical, typ_-40 fast).
source [file dirname [info script]]/../common/setup.tcl
open_lib -read chip.dlib
open_block finish
set OUT [file normalize ../outputs/chip_final/chip_top]
write_parasitics -output $OUT
puts "INFO: chip SPEF -> ${OUT}.*.spef"
exit
