# Stage 01: floorplan, SRAM placement, taps and power grid of croc_soc.
# Structure after pulp-platform/croc openroad/scripts/01_floorplan.tcl (Apache-2.0); GF180MCU, macro (no pad ring).
source scripts/startup.tcl

read_verilog $netlist
link_design $top_design
read_sdc src/constraints.sdc

# ---- global power connections (std cells, SRAM, taps) ----
add_global_connection -net VDD -inst_pattern {.*} -pin_pattern {^VDD$} -power
add_global_connection -net VDD -inst_pattern {.*} -pin_pattern {^VNW$} -power
add_global_connection -net VSS -inst_pattern {.*} -pin_pattern {^VSS$} -ground
add_global_connection -net VSS -inst_pattern {.*} -pin_pattern {^VPW$} -ground
set_voltage_domain -name CORE -power VDD -ground VSS

# ---- die and core ----
# macro height from total cell area (std cells + SRAM) / target utilization, as the FC flow does
set total_area 0.0
foreach inst [[ord::get_db_block] getInsts] {
    set total_area [expr {$total_area + double([[$inst getMaster] getWidth]) * [[$inst getMaster] getHeight] / ([[ord::get_db_block] getDbUnitsPerMicron] * [[ord::get_db_block] getDbUnitsPerMicron])}]
}
set die_h [expr {ceil($total_area / $target_util / $die_w)}]
utl::report "total cell area $total_area um2 -> die ${die_w} x ${die_h} um"
initialize_floorplan -die_area "0 0 $die_w $die_h" \
    -core_area "$core_margin $core_margin [expr {$die_w - $core_margin}] [expr {$die_h - $core_margin}]" \
    -site $site_name
make_tracks

# ---- SRAM macros: 2 x 2 block at the top of the core ----
set block [ord::get_db_block]
set dbu [$block getDbUnitsPerMicron]
set srams [list]
foreach inst [$block getInsts] {
    if {[[$inst getMaster] getName] eq $sram_cell} { lappend srams $inst }
}
set srams [lsort -command {apply {{a b} {string compare [$a getName] [$b getName]}}} $srams]
set sw [expr {[[lindex $srams 0 ] getMaster] eq "" ? 0 : double([[[lindex $srams 0] getMaster] getWidth]) / $dbu}]
set sh [expr {double([[[lindex $srams 0] getMaster] getHeight]) / $dbu}]
set halo 30.0
# flush with the left and top edge of the core: a gap narrower than a cell would be an unusable row sliver
set core_bb [$block getCoreArea]
set x0 [expr {double([$core_bb xMin]) / $dbu}]
set y0 [expr {double([$core_bb yMax]) / $dbu - 2*$sh - $halo}]
set i 0
foreach inst $srams {
    set col [expr {$i % 2}]
    set row [expr {$i / 2}]
    set x [expr {$x0 + $col * ($sw + $halo)}]
    set y [expr {$y0 + $row * ($sh + $halo)}]
    $inst setOrient R0
    $inst setLocation [expr {int($x * $dbu)}] [expr {int($y * $dbu)}]
    $inst setPlacementStatus FIRM
    utl::report "SRAM [$inst getName] at $x $y"
    incr i
}
# no standard-cell rows within 5 um of a macro (rows are cut around the placed SRAMs before taps are inserted)
cut_rows -endcap_master $endCap -halo_width_x 5.0 -halo_width_y 5.0

# ---- taps and endcaps ----
tapcell -tapcell_master $tapCell -endcap_master $endCap -distance 40
global_connect

# ---- power grid: main ring M4/M5 (10 um), mesh M4/M5 (3 um, pitch 40), M1 rails; SRAM pins via Metal3 ----
define_pdn_grid -name core_grid -voltage_domains CORE
add_pdn_ring -grid core_grid -layers {Metal4 Metal5} -widths {10.0 10.0} -spacings {2.0 2.0} -core_offset {2.0 2.0}
add_pdn_stripe -grid core_grid -layer Metal1 -followpins -width 0.6
add_pdn_stripe -grid core_grid -layer Metal4 -width 3.0 -pitch 40.0 -offset 20.0 -extend_to_core_ring
add_pdn_stripe -grid core_grid -layer Metal5 -width 3.0 -pitch 40.0 -offset 20.0 -extend_to_core_ring
add_pdn_connect -grid core_grid -layers {Metal1 Metal4}
add_pdn_connect -grid core_grid -layers {Metal4 Metal5}
define_pdn_grid -macro -name sram_grid -cells $sram_cell -grid_over_boundary
add_pdn_connect -grid sram_grid -layers {Metal3 Metal4}
pdngen

setDefaultParasitics
save_checkpoint 01_${proj_name}.floorplan
write_def ${save_dir}/01_${proj_name}.floorplan.def
