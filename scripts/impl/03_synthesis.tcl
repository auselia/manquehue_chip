# Step 3: synthesis with scan insertion, up to the initial optimization
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: make synthesis      (fc_shell in work/)
# in:  block floorplan
# out: block synthesis
source [file dirname [info script]]/lib/open_lib.tcl
open_block floorplan

set_app_options -name compile.flow.high_effort_timing -value 1
set_app_options -name opt.timing.effort               -value high
set_app_options -name route_opt.flow.enable_ccd       -value true

# No oversized cells and no clock cells in the synthesized data path
set_lib_cell_purpose -include none [get_lib_cells $SYN_IGNORE_CELLS]

# The verification checkpoints of Fusion Compiler (ckpt_pre_map, ckpt_logic_opt) go into the SVF for Formality
set_verification_checkpoints

# Mapping and logic optimization, then the scan insertion, then placement up to the initial optimization.
# The last steps of compile_fusion (timing optimization) run later.
compile_fusion -to logic_opto
source [file dirname [info script]]/lib/dft_scan.tcl
compile_fusion -from initial_place -to initial_opto

set ACTIVE_STEP "03_synthesis"
source [file dirname [info script]]/lib/reporting.tcl

save_block -as synthesis
