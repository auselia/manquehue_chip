###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Synthesis and DFT Insertion
###############################################################################

source [file dirname [info script]]/common/open_lib.tcl
open_block floorplan

# Remove oversized and clock cells from synthesis
set_lib_cell_purpose -include none [get_lib_cells $SYN_IGNORE_CELLS]

# Enables FC's own verification checkpointing (ckpt_pre_map + ckpt_logic_opt)
set_verification_checkpoints

# Run mapping and logic optimization before for DFT insertion.
compile_fusion -to logic_opto

# DFT Insertion
source [file dirname [info script]]/common/dft_scan.tcl

# Resumes compile_fusion till initial opto (last two steps are for timing optimization, done later)
compile_fusion -from initial_place -to initial_opto

set ACTIVE_STEP "03_synthesis"
source [file dirname [info script]]/common/reporting.tcl

save_block -as synthesis
