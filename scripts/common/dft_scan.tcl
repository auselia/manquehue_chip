###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Scan Chain Insertion (one internal chain, no compression)
###############################################################################

# Sourced by 03_synthesis.tcl between compile_fusion -to logic_opto and -from initial_place, as in the FC DFT
# User Guide (chapter 1, figure 1). One multiplexed flip-flop chain lets a bring-up engineer stop the chip and
# shift the full flop state in and out on a few pins. Results and ATPG: docs/dft_atpg.md.

# Sections 1 to 3 (test pins, clocks and reset, AutoFix): scripts/dft/dft_spec.tcl, also read by the STIL export.
source [file dirname [info script]]/../dft/dft_spec.tcl

###############################################################################
# 4. Insertion
###############################################################################
# AutoFix needs two passes: insert_dft -autofix adds the gates, the second insert_dft stitches the chain.
create_test_protocol

dft_drc
preview_dft
insert_dft -autofix

dft_drc
preview_dft
insert_dft

# Expected warnings: S22 (two shift clocks), C5, C8, C26 (rst_ni used as data), D10 (clock into a data pin).
dft_drc
