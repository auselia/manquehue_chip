# -----------------------------------------------------------------------------
# This file was created at the Institute of Microelectronic Systems,
# Leibniz University Hannover. It is provided "as is" without
# warranty of any kind, express or implied, including but not
# limited to correctness or fitness for a particular purpose.
#
# Author: Viktor Schneider
# -----------------------------------------------------------------------------

source [file dirname [info script]]/common/open_lib.tcl
open_block route

###################################
# FILLER Cell Insertion
###################################

set DCAP_CELLS [get_object_name [sort_collection -descending [get_lib_cells *mcu${STDCELL_TRACK_SIZE}t5v0__fillcap*] area]]
set FILL_CELLS [get_object_name [sort_collection -descending [get_lib_cells *mcu${STDCELL_TRACK_SIZE}t5v0__fill_*] area]]

create_stdcell_fillers -lib_cells $DCAP_CELLS -type_utilization [list $DCAP_CELLS 20]
connect_pg_net -automatic
remove_stdcell_fillers_with_violation
create_stdcell_fillers -lib_cells $FILL_CELLS
connect_pg_net -automatic

route_detail -incremental true

change_names -rules verilog

# -----------------------------------------------------------------------------
# Timestamped, self-archiving GDS / netlist export
# -----------------------------------------------------------------------------
# Everything lands in <repo>/outputs (we run from <repo>/work, so ../outputs).
# Each run produces a unique  <TOP>_<YYYYMMDD_HHMMSS>.{gds,v}, and a stable
# <TOP>.latest.{gds,v} symlink is repointed at the newest one. Consequences:
#   * runs never overwrite each other -> you stop losing old GDS files;
#   * downstream steps (DRC, LVS) can always reference "<TOP>.latest.gds"
#     without knowing the timestamp;
#   * to sign off a *previous* run, just point the tool at its timestamped file.
# -----------------------------------------------------------------------------
set OUTPUTS_DIR [file normalize [file join [file dirname [info script]] .. outputs]]
file mkdir $OUTPUTS_DIR

set RUN_STAMP [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set GDS_OUT   [file join $OUTPUTS_DIR "${TOP_MODULE}_${RUN_STAMP}.gds"]
set VLOG_OUT  [file join $OUTPUTS_DIR "${TOP_MODULE}_${RUN_STAMP}.v"]

write_verilog -include all \
    -exclude_cells [get_cells -of_references [get_lib_cells {*fill_* *filltie* *endcap*}]] \
    $VLOG_OUT

set GDS_FILE_LIST [glob ${PDK_DIR}/gds/*.gds]
write_gds -merge_files $GDS_FILE_LIST -merge_gds_top_cell $TOP_MODULE \
    -layer_map ${ICC2GDS_LAYERMAP} -long_names $GDS_OUT

# Refresh the "latest" pointers. Targets are stored as bare basenames so the
# symlinks stay valid even if the whole outputs/ directory is later moved.
foreach {link tgt} [list \
        [file join $OUTPUTS_DIR "${TOP_MODULE}.latest.gds"] "${TOP_MODULE}_${RUN_STAMP}.gds" \
        [file join $OUTPUTS_DIR "${TOP_MODULE}.latest.v"]   "${TOP_MODULE}_${RUN_STAMP}.v"] {
    catch { file delete -- $link }
    exec ln -sfn $tgt $link
}

puts "INFO: Wrote GDS      -> $GDS_OUT"
puts "INFO: Wrote netlist  -> $VLOG_OUT"
puts "INFO: latest pointers -> ${TOP_MODULE}.latest.gds / ${TOP_MODULE}.latest.v"

set ACTIVE_STEP "06_finish"
source [file dirname [info script]]/common/reporting.tcl

save_block -as finish