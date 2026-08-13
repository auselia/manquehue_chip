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
# Each run gets its own folder outputs/<TOP>_<YYYYMMDD_HHMMSS>/ containing
# <TOP>.gds and <TOP>.v, and a stable outputs/latest symlink is repointed at
# the newest run folder. Consequences:
#   * runs never overwrite each other -> you stop losing old GDS files;
#   * downstream steps (DRC, LVS) can always reference outputs/latest/<TOP>.gds
#     without knowing the timestamp, and each writes its results into
#     outputs/<run>/drc/ and outputs/<run>/lvs/ right next to that run's
#     .gds/.v -- one self-contained folder per run;
#   * to sign off a *previous* run, just point the tool at its run folder
#     (make drc RUN=<TOP>_<timestamp>).
# -----------------------------------------------------------------------------
set OUTPUTS_DIR [file normalize [file join [file dirname [info script]] .. outputs]]
file mkdir $OUTPUTS_DIR

set RUN_STAMP [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set RUN_NAME  "${TOP_MODULE}_${RUN_STAMP}"
set RUN_DIR   [file join $OUTPUTS_DIR $RUN_NAME]
file mkdir $RUN_DIR

set GDS_OUT   [file join $RUN_DIR "${TOP_MODULE}.gds"]
set VLOG_OUT  [file join $RUN_DIR "${TOP_MODULE}.v"]

# NOTE: *fillcap* (decoupling-cap fillers, inserted above via DCAP_CELLS)
# is deliberately NOT in this exclude list, unlike *fill_*/*filltie*/
# *endcap*. Those three are pure geometry with no devices, so excluding
# them from the Verilog was always a no-op for LVS. fillcap cells are real
# 2-terminal VDD/VSS capacitors -- excluding them here made every one of
# ~2972 layout instances show up with zero schematic counterpart at all
# (confirmed 2026-08-12: subcircuit_mismatch went 8 -> 2972 the one run
# this was tried), far worse than the handful of mildly-ambiguous instance
# pairings you get by including them normally. Leave them in.
write_verilog -include all \
    -exclude_cells [get_cells -of_references [get_lib_cells {*fill_* *filltie* *endcap*}]] \
    $VLOG_OUT

set GDS_FILE_LIST [glob ${PDK_DIR}/gds/*.gds]
write_gds -merge_files $GDS_FILE_LIST -merge_gds_top_cell $TOP_MODULE \
    -layer_map ${ICC2GDS_LAYERMAP} -long_names $GDS_OUT

# Refresh the "latest" pointer. It targets the bare run-folder name so the
# symlink stays valid even if the whole outputs/ directory is later moved.
set LATEST_LINK [file join $OUTPUTS_DIR "latest"]
catch { file delete -- $LATEST_LINK }
exec ln -sfn $RUN_NAME $LATEST_LINK

puts "INFO: Wrote GDS      -> $GDS_OUT"
puts "INFO: Wrote netlist  -> $VLOG_OUT"
puts "INFO: latest run     -> outputs/latest -> ${RUN_NAME}/"

set ACTIVE_STEP "06_finish"
source [file dirname [info script]]/common/reporting.tcl

save_block -as finish