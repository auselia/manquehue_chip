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

# DF.12 / DF.13: every tap needs a transistor within 15 um. Remove the taps that have none.
set TAP_DEVICE_DISTANCE 15.0
set orphan_taps {}
foreach_in_collection tap [get_cells -physical_context -filter "ref_name =~ *filltie*"] {
  set bbox [get_attribute $tap bbox]
  set area [list [list [expr {[lindex $bbox 0 0] - $TAP_DEVICE_DISTANCE}] [expr {[lindex $bbox 0 1] - $TAP_DEVICE_DISTANCE}]] \
                 [list [expr {[lindex $bbox 1 0] + $TAP_DEVICE_DISTANCE}] [expr {[lindex $bbox 1 1] + $TAP_DEVICE_DISTANCE}]]]
  set nearby [get_objects_by_location -classes cell -intersect $area -quiet]
  if {[sizeof_collection $nearby] > 0} {
    set nearby [filter_collection $nearby "ref_name !~ *filltie* && ref_name !~ *endcap* && ref_name !~ *fill_*"]
  }
  if {[sizeof_collection $nearby] == 0} { lappend orphan_taps $tap }
}
puts "INFO: removing [llength $orphan_taps] taps with no device within $TAP_DEVICE_DISTANCE um"
if {[llength $orphan_taps] > 0} { remove_cells [add_to_collection {} $orphan_taps] }

remove_stdcell_fillers_with_violation
create_stdcell_fillers -lib_cells $FILL_CELLS
connect_pg_net -automatic

route_detail -incremental true

change_names -rules verilog

###################################
# Top-level power pins
###################################
# write_gds writes pin text for terminals, and LVS needs it to name the VDD and VSS ports.
foreach {net pins} $PG_PINS {
  foreach pin $pins {
    lassign $pin layer x0 y0 x1 y1
    set area [list [list $x0 $y0] [list $x1 $y1]]
    if {[sizeof_collection [get_shapes -intersect $area -filter "layer_name == $layer && net.name == $net" -quiet]] == 0} {
      error "power pin $net {$pin} is not on a $layer shape of net $net"
    }
    create_terminal -port [get_ports $net] -boundary $area -layer [get_layers $layer]
  }
}

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

# Reroute nets that violate routing rules FC cannot see (checked with the wafer.space KLayout deck).
source [file dirname [info script]]/common/drc_eco.tcl
drc_eco_reroute $RUN_DIR

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

# The parent flow (LibreLane Magic.StreamOut) reads the macro's bounding box from a PR
# boundary shape in the GDS top cell, which write_gds does not emit for the top block.
create_shape -shape_type rect -layer PR_bndry -boundary [get_attribute [current_block] boundary_bbox]

set GDS_FILE_LIST [glob ${PDK_DIR}/gds/*.gds]
# 1 nm database unit: the wafer.space precheck and LibreLane's Magic step both require it.
write_gds -units 1000 -merge_files $GDS_FILE_LIST -merge_gds_top_cell $TOP_MODULE \
    -layer_map ${ICC2GDS_LAYERMAP} -long_names $GDS_OUT

# Abstract (LEF) for placing croc_soc as a hard macro in the wafer.space chip_top.
# create_frame keeps the pins and turns the rest into zero-spacing blockages. On Metal4 and Metal5
# the blockage starts PG_PIN_BAND um inside the edge, leaving the ring pins open to the parent.
set LEF_OUT [file join $RUN_DIR "${TOP_MODULE}.lef"]
create_frame -block_core_margin [list [list Metal4 $PG_PIN_BAND] [list Metal5 $PG_PIN_BAND]]
write_lef -design [current_block] -include cell $LEF_OUT

# write_lef declares an OVERLAP layer and uses it in the OBS; LibreLane's Magic cannot parse it.
set lef_fh [open $LEF_OUT r]
set lef_text [read $lef_fh]
close $lef_fh
regsub -all {LAYER OVERLAP\n  TYPE OVERLAP ;\nEND OVERLAP\n\n?} $lef_text "" lef_text
regsub -all {    LAYER OVERLAP ;\n(?:      [^\n]*\n)+} $lef_text "" lef_text
set lef_fh [open $LEF_OUT w]
puts -nonewline $lef_fh $lef_text
close $lef_fh

# Refresh the "latest" pointer. It targets the bare run-folder name so the
# symlink stays valid even if the whole outputs/ directory is later moved.
set LATEST_LINK [file join $OUTPUTS_DIR "latest"]
catch { file delete -- $LATEST_LINK }
exec ln -sfn $RUN_NAME $LATEST_LINK

puts "INFO: Wrote GDS      -> $GDS_OUT"
puts "INFO: Wrote netlist  -> $VLOG_OUT"
puts "INFO: Wrote LEF      -> $LEF_OUT"
puts "INFO: latest run     -> outputs/latest -> ${RUN_NAME}/"

set ACTIVE_STEP "06_finish"
source [file dirname [info script]]/common/reporting.tcl

save_block -as finish