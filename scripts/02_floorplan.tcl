###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Floorplanning and Power Grid
###############################################################################

source [file dirname [info script]]/common/open_lib.tcl
open_block read_rtl

set SITE_DEF unit

if {$CHIP_FLOORPLAN} {
# Chip floorplan: croc is the whole die, on the AC3E pad ring, with the DC-DC wrappers in the north
# (chip/chip_floorplan.tcl), and the CROC power grid. 03 to 06 continue on work/chip.dlib.
# The reference library stays in chip.dlib after the first chip run
if {[sizeof_collection [get_libs -quiet chip_macros]] == 0} {
    set_ref_libs -add [file normalize chip_macros.ndm]
}
source [file dirname [info script]]/chip/chip_floorplan.tcl
set_dont_touch [get_cells -filter "ref_name =~ gf180mcu_fd_io__* || ref_name =~ gf180mcu_ws_ip__*"] true
foreach m $CHIP_DCDC_MACROS { set_dont_touch [get_cells u_$m] true }

compile_fusion -to initial_map
source [file dirname [info script]]/chip/chip_pg_pads.tcl
chip_float_dcdc_pins
check_design_states -verbose

# Pads connected to croc: Y drives croc logic, A is driven by croc logic (not by a tie cell)
set pads_in {}
set pads_out {}
foreach_in_collection p [get_cells pad_*] {
    set n [get_object_name $p]
    set y [get_pins -quiet $n/Y]
    if {[sizeof_collection $y] && [sizeof_collection [get_nets -quiet -of $y]]} {
        set loads [get_pins -quiet -leaf -of [get_nets -of $y] -filter "direction == in && cell.full_name !~ pad_*"]
        if {[sizeof_collection $loads]} { lappend pads_in $n }
    }
    set a [get_pins -quiet $n/A]
    if {[sizeof_collection $a] && [sizeof_collection [get_nets -quiet -of $a]]} {
        set drv [get_pins -quiet -leaf -of [get_nets -of $a] -filter "direction == out && cell.ref_name !~ *tie*"]
        if {[sizeof_collection $drv]} { lappend pads_out $n }
    }
}
puts "INFO: pads driving croc ([llength $pads_in]): [lsort $pads_in]"
puts "INFO: pads driven by croc ([llength $pads_out]): [lsort $pads_out]"
} else {

set target_utilization 0.7
set slot_width_limit 1130.0
set external_gap 15.0

set macro_width [expr {$slot_width_limit - (2 * $external_gap)}]

# TODO: Probably a better way to do this
redirect -variable area_rpt {report_area}
regexp {Total cell area:\s+([0-9.]+)} $area_rpt full_match total_cell_area

set required_macro_area [expr {$total_cell_area / $target_utilization}]
set macro_height [expr {$required_macro_area / $macro_width}]

puts "INFO: Generating Macro with actual dimensions: ${macro_width}x${macro_height} um"

initialize_floorplan \
    -control_type die \
    -shape R \
    -side_length "1120 1800" \
    -core_offset 25.0

compile_fusion -to initial_map
check_design_states -verbose

# Pins on routing layers only: the parent flow routes from Metal2 up, so a Metal1 pin needs a Via1 pad wider
# than the pin. Left and right edges get horizontal Metal3 pins, top and bottom get vertical Metal2.
set_block_pin_constraints -self -allowed_layers {Metal2 Metal3} -pin_spacing 2

# Pin positions: every pin faces its pad in the AC3E padframe (04_chip_top/padframe/padframe.yaml of
# TO-GF180MCU-AC3E-2026_V1, proposal 2026-10-19_croc_shared_spi). CROC uses pads 35 to 75: the west side counts down,
# the south side runs east, the east side counts up. No CROC pad faces the north edge, so it has no pins.
# Pad centres in the die (1936 um wide, 100 um pitch west and east, 104 um south):
#   west pad n: y = 2461 - 100 (n - 23)   south pad n: x = 448 + 104 (n - 44)   east pad n: y = 461 + 100 (n - 55)
# The macro sits centred in x with its lower edge at croc_lly (the template core origin, to confirm at chip level).
# Pins of one pad (a bidirectional pad has out, in and enable) are spread around the pad centre, pin_step apart.
set die_width 1936.0
set croc_lly  442.0
set croc_llx  [expr {($die_width - $macro_width) / 2.0}]
set pin_step  6.0
set pin_edge  10.0

set pad_pins {
    35 rf_rstn_o
    36 rf_dio0_i
    37 scan_se_i
    38 scan_so_o
    41 scan_si_i
    42 afe_irq_i
    43 spi_sd_i
    44 spi_sd_o
    45 spi_cs1_o
    46 spi_cs0_o
    47 spi_sck_o
    48 {gpio_o[1] gpio_i[1] gpio_out_en_o[1]}
    49 {gpio_o[0] gpio_i[0] gpio_out_en_o[0]}
    52 {qspi_sd_o[3] qspi_sd_i[3] qspi_sd_en_o[3]}
    53 {qspi_sd_o[2] qspi_sd_i[2] qspi_sd_en_o[2]}
    54 {qspi_sd_o[1] qspi_sd_i[1] qspi_sd_en_o[1]}
    55 {qspi_sd_o[0] qspi_sd_i[0] qspi_sd_en_o[0]}
    56 qspi_csn_o[2]
    57 qspi_csn_o[1]
    58 qspi_csn_o[0]
    59 qspi_clk_o
    60 uart_tx_o
    61 uart_rx_i
    62 jtag_tdo_o
    63 jtag_tdi_i
    64 jtag_tms_i
    65 jtag_trst_ni
    66 jtag_tck_i
    67 status_o
    70 testmode_i
    71 ref_clk_i
    72 rst_ni
    73 clk_i
}

# Side numbers run clockwise from the left edge (1 left, 2 top, 3 right, 4 bottom). -offset is measured from where
# the edge starts when going clockwise: the left edge from the bottom, the right edge from the top, the bottom edge
# from the right.
set pin_offsets [dict create]
foreach {pad ports} $pad_pins {
    if {$pad <= 43} {
        set side 1; set pos [expr {2461.0 - 100.0 * ($pad - 23) - $croc_lly}];  set len $macro_height
    } elseif {$pad <= 54} {
        set side 4; set pos [expr {448.0 + 104.0 * ($pad - 44) - $croc_llx}];   set len $macro_width
    } else {
        set side 3; set pos [expr {461.0 + 100.0 * ($pad - 55) - $croc_lly}];   set len $macro_height
    }
    set n [llength $ports]
    set i 0
    foreach port $ports {
        set p [expr {$pos + ($i - ($n - 1) / 2.0) * $pin_step}]
        set p [expr {min(max($p, $pin_edge), $len - $pin_edge)}]
        # distance along the edge from its clockwise start
        set off [expr {$side == 1 ? $p : $len - $p}]
        create_pin_constraint -type individual -ports [get_ports $port] -sides $side -offset [format %.2f $off]
        dict set pin_offsets $port [list $side $p]
        incr i
    }
}
set unpadded [remove_from_collection [remove_from_collection [get_ports *] [get_ports {VDD VSS} -quiet]] \
                  [get_ports [dict keys $pin_offsets]]]
if {[sizeof_collection $unpadded] > 0} {
    puts "ERROR: ports without a pad: [get_object_name $unpadded]"
}

place_pins -self

# every pin against its target position along its edge (macro coordinates)
set pin_dev_max 0.0
dict for {port t} $pin_offsets {
    lassign $t side p
    set bb [get_attribute [get_ports $port] bbox]
    set cx [expr {([lindex $bb 0 0] + [lindex $bb 1 0]) / 2.0}]
    set cy [expr {([lindex $bb 0 1] + [lindex $bb 1 1]) / 2.0}]
    set got [expr {$side == 4 ? $cx : $cy}]
    set pin_dev_max [expr {max($pin_dev_max, abs($got - $p))}]
}
puts [format "INFO: pins placed, largest distance from the pad target %.2f um" $pin_dev_max]

shape_blocks
}

set all_macros [get_cells -hierarchical -filter "is_hard_macro && !is_physical_only && ref_name =~ gf180mcu_fd_ip_sram__*"]
create_keepout_margin -type hard_macro -outer {10 10 10 10} $all_macros
create_keepout_margin -type hard -outer {10 10 10 10} $all_macros

# Places the macros in the floorplan
create_placement -floorplan

# Locks the macros in place so their coordinates don't change
set_fixed_objects [get_flat_cells -filter "is_hard_macro"]

set blocked_layers {Metal1 Metal2 Metal3 Metal4 Metal5}

foreach_in_collection macro $all_macros {
    
    set macro_basename [get_attribute $macro base_name]
    set ref_name       [get_attribute $macro ref_name]

    # Safely extract the bbox list: {{llx lly} {urx ury}}
    set bbox [get_attribute $macro bbox]
    set llx [lindex $bbox 0 0]
    set lly [lindex $bbox 0 1]
    set urx [lindex $bbox 1 0]
    set ury [lindex $bbox 1 1]

    # Shrink by 17.0 total (10um for the keepout margin + 5um for the internal margin)
    set new_llx [expr {$llx + 17}]
    set new_lly [expr {$lly + 17}]
    set new_urx [expr {$urx - 17}]
    set new_ury [expr {$ury - 17}]

    # Ensure the macro is large enough so the math doesn't invert the box
    if {($new_urx > $new_llx) && ($new_ury > $new_lly)} {
        
        set new_boundary [list [list $new_llx $new_lly] [list $new_urx $new_ury]]

        create_routing_blockage -boundary $new_boundary \
                                -layers $blocked_layers \
                                -name_prefix "shrunk_${macro_basename}"
                                
        puts "INFO: Created 5um shrunk routing blockage for SRAM: $macro_basename (Type: $ref_name)"
    } else {
        puts "WARNING: Skipping $macro_basename because its size is too small for a 15um shrink."
    }
}

# 5. Boundary and Tap Cells
set BOUNDARY_CELL [get_lib_cells *mcu${STDCELL_TRACK_SIZE}t5v0__endcap]
set TAP_CELL      [get_lib_cells *mcu${STDCELL_TRACK_SIZE}t5v0__filltie]

set_boundary_cell_rules -left_boundary_cell $BOUNDARY_CELL -right_boundary_cell $BOUNDARY_CELL
compile_targeted_boundary_cells -all_targets

create_tap_cells -lib_cell $TAP_CELL -pattern stagger -distance 40

set_app_options -name place.legalize.enable_advanced_legalizer -value true

if {$CHIP_FLOORPLAN} {
save_block -as floorplan_pre_pg
source [file dirname [info script]]/common/power_grid.tcl
save_block -as floorplan
source [file dirname [info script]]/chip/chip_export.tcl
write_chip_views [file normalize ../outputs/chip_floorplan] chip_floorplan
print_message_info -ids * -summary
return
}

save_block -as floorplan_pre_pg

source [file dirname [info script]]/common/power_grid.tcl

set ACTIVE_STEP "02_floorplan"
source [file dirname [info script]]/common/reporting.tcl

save_block -as floorplan
print_message_info -ids * -summary
