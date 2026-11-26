# Step 2: floorplan of the croc_soc macro: outline, pins facing their pads, SRAM placement, taps, power grid
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: make floorplan      (fc_shell in work/)
# in:  block read_rtl, config/padring.txt
# out: blocks floorplan_pre_pg and floorplan
source [file dirname [info script]]/lib/open_lib.tcl
open_block read_rtl

# Macro outline: CROC_MACRO_SIZE (lib/setup.tcl). The cell area of the elaborated netlist (report_area, before mapping)
# gives the utilization of that outline, as a check.
lassign $CROC_MACRO_SIZE macro_width macro_height
redirect -variable area_rpt {report_area}
regexp {Total cell area:\s+([0-9.]+)} $area_rpt full_match total_cell_area
puts [format "INFO: macro %.1f x %.1f um, cell area %.0f um2, utilization %.2f" \
    $macro_width $macro_height $total_cell_area [expr {$total_cell_area / ($macro_width * $macro_height)}]]

initialize_floorplan \
    -control_type die \
    -shape R \
    -side_length [list $macro_width $macro_height] \
    -core_offset $CROC_CORE_OFFSET

compile_fusion -to initial_map
check_design_states -verbose

# Pins on routing layers only: the parent flow routes from Metal2 up, so a Metal1 pin needs a Via1 pad wider
# than the pin. Left and right edges get horizontal Metal3 pins, top and bottom get vertical Metal2.
set_block_pin_constraints -self -allowed_layers {Metal2 Metal3} -pin_spacing 2

# Pin positions: every pin faces its pad on the AC3E ring (config/padring.txt), with the macro lower-left corner at
# CROC_MACRO_LL in the die. The CROC pads are on the west (bottom part), south and east (bottom part) sides, so the
# north edge has no pins. Pins of one pad (a bidirectional pad has out, in and enable) are spread around the pad
# centre, pin_step apart.
source [file dirname [info script]]/lib/padring.tcl
lassign $CROC_MACRO_LL croc_llx croc_lly
set pad_width 75.0
set pin_step  6.0
set pin_edge  10.0

# pad signal -> macro ports
set pad_ports {
    rf_rstn_o rf_rstn_o
    rf_dio0_i rf_dio0_i
    scan_en_i scan_se_i
    scan_out_o scan_so_o
    scan_in_i scan_si_i
    afe_irq_i afe_irq_i
    spi_sd_i spi_sd_i
    spi_sd_o spi_sd_o
    spi_cs1_o spi_cs1_o
    spi_cs0_o spi_cs0_o
    spi_sck_o spi_sck_o
    i2c_scl_io {i2c_scl_oe_o i2c_scl_i}
    i2c_sda_io {i2c_sda_oe_o i2c_sda_i}
    gpio6_io {gpio_o[6] gpio_i[6] gpio_out_en_o[6]}
    gpio5_io {gpio_o[5] gpio_i[5] gpio_out_en_o[5]}
    gpio4_io {gpio_o[4] gpio_i[4] gpio_out_en_o[4]}
    gpio3_io {gpio_o[3] gpio_i[3] gpio_out_en_o[3]}
    gpio2_io {gpio_o[2] gpio_i[2] gpio_out_en_o[2]}
    gpio1_io {gpio_o[1] gpio_i[1] gpio_out_en_o[1]}
    gpio0_io {gpio_o[0] gpio_i[0] gpio_out_en_o[0]}
    qspi_sd3_io {qspi_sd_o[3] qspi_sd_i[3] qspi_sd_en_o[3]}
    qspi_sd2_io {qspi_sd_o[2] qspi_sd_i[2] qspi_sd_en_o[2]}
    qspi_sd1_io {qspi_sd_o[1] qspi_sd_i[1] qspi_sd_en_o[1]}
    qspi_sd0_io {qspi_sd_o[0] qspi_sd_i[0] qspi_sd_en_o[0]}
    qspi_cs2_o qspi_csn_o[2]
    qspi_cs1_o qspi_csn_o[1]
    qspi_cs0_o qspi_csn_o[0]
    qspi_clk_o qspi_clk_o
    uart_tx_o uart_tx_o
    uart_rx_i uart_rx_i
    jtag_tdo_o jtag_tdo_o
    jtag_tdi_i jtag_tdi_i
    jtag_tms_i jtag_tms_i
    jtag_trst_ni jtag_trst_ni
    jtag_tck_i jtag_tck_i
    status_o status_o
    testmode_i testmode_i
    ref_clk_i ref_clk_i
    rst_ni rst_ni
    clk_i clk_i
}

# Side numbers run clockwise from the left edge (1 left, 2 top, 3 right, 4 bottom). -offset counts from where the
# edge starts, going clockwise. The left edge starts at the bottom, the right edge at the top, the bottom edge at the
# right.
set pin_offsets [dict create]
foreach p $chip_pads {
    lassign $p n sig cell
    if {![dict exists $pad_ports $sig]} { continue }
    lassign [pad_side_loc $n] pside loc
    set centre [expr {$loc + $pad_width / 2.0}]
    switch $pside {
        left    { set side 1; set pos [expr {$centre - $croc_lly}]; set len $macro_height }
        bottom  { set side 4; set pos [expr {$centre - $croc_llx}]; set len $macro_width }
        right   { set side 3; set pos [expr {$centre - $croc_lly}]; set len $macro_height }
        default { error "ERROR: CROC pad $n ($sig) on the $pside side" }
    }
    set ports [dict get $pad_ports $sig]
    set k [llength $ports]
    set i 0
    foreach port $ports {
        set q [expr {$pos + ($i - ($k - 1) / 2.0) * $pin_step}]
        set q [expr {min(max($q, $pin_edge), $len - $pin_edge)}]
        # distance along the edge from its clockwise start
        set off [expr {$side == 1 ? $q : $len - $q}]
        create_pin_constraint -type individual -ports [get_ports $port] -sides $side -offset [format %.2f $off]
        dict set pin_offsets $port [list $side $q]
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

set all_macros [get_cells -hierarchical -filter "is_hard_macro && !is_physical_only && ref_name =~ gf180mcu_fd_ip_sram__*"]
create_keepout_margin -type hard_macro -outer {10 10 10 10} $all_macros
create_keepout_margin -type hard -outer {10 10 10 10} $all_macros

# Partial placement blockage where the channel between the SRAM columns meets the gap between the rows: nearly all
# routing DRCs of the macro were there (x 496 to 620, y 1164 to 1293), and the router could not clear them.
create_placement_blockage -type partial -blocked_percentage 50 -boundary {{490 1150} {630 1300}} -name sram_channel_blk

# The DC-DC keepouts (DCDC_KEEPOUTS, die coordinates), clipped to the outline: no cells, no SRAM (a hard placement
# blockage stops standard cells only) and no Metal1 to Metal3
lassign [lindex [get_attribute [current_block] boundary_bbox] 1] block_w block_h
set k 0
foreach box $DCDC_KEEPOUTS {
    lassign $box x0 y0 x1 y1
    set b [list [list [expr {max(0, $x0 - $croc_llx)}] [expr {max(0, $y0 - $croc_lly)}]] \
                [list [expr {min($block_w, $x1 - $croc_llx)}] [expr {min($block_h, $y1 - $croc_lly)}]]]
    create_placement_blockage -type hard -boundary $b -name dcdc_keepout_$k
    create_placement_blockage -type hard_macro -boundary $b -name dcdc_keepout_macro_$k
    create_routing_blockage -boundary $b -layers {Metal1 Metal2 Metal3} -name_prefix dcdc_keepout_$k
    puts "INFO: DC-DC keepout $k at $b (macro coordinates)"
    incr k
}

# No SRAM within SRAM_EDGE_MARGIN of the west, east and south edges
foreach {name b} [list west  [list {0 0} [list $SRAM_EDGE_MARGIN $block_h]] \
                       east  [list [list [expr {$block_w - $SRAM_EDGE_MARGIN}] 0] [list $block_w $block_h]] \
                       south [list {0 0} [list $block_w $SRAM_EDGE_MARGIN]]] {
    create_placement_blockage -type hard_macro -boundary $b -name sram_edge_$name
}

# Places the macros in the floorplan
create_placement -floorplan

# Locks the macros in place so their coordinates do not change
set_fixed_objects [get_flat_cells -filter "is_hard_macro"]

# A routing blockage on all layers over each SRAM, 17 um inside its edge: the router stays off the SRAM and still
# reaches its pins from the edge band.
set blocked_layers {Metal1 Metal2 Metal3 Metal4 Metal5}
set sram_edge_band 17
foreach_in_collection macro $all_macros {
    set macro_basename [get_attribute $macro base_name]
    set ref_name       [get_attribute $macro ref_name]
    set bbox [get_attribute $macro bbox]
    set new_llx [expr {[lindex $bbox 0 0] + $sram_edge_band}]
    set new_lly [expr {[lindex $bbox 0 1] + $sram_edge_band}]
    set new_urx [expr {[lindex $bbox 1 0] - $sram_edge_band}]
    set new_ury [expr {[lindex $bbox 1 1] - $sram_edge_band}]
    if {($new_urx > $new_llx) && ($new_ury > $new_lly)} {
        create_routing_blockage -boundary [list [list $new_llx $new_lly] [list $new_urx $new_ury]] \
                                -layers $blocked_layers -name_prefix "shrunk_${macro_basename}"
        puts "INFO: routing blockage over SRAM $macro_basename ($ref_name), $sram_edge_band um inside its edge"
    } else {
        puts "WARNING: $macro_basename is too small for a routing blockage $sram_edge_band um inside its edge"
    }
}

# Boundary and tap cells
set BOUNDARY_CELL [get_lib_cells *mcu${STDCELL_TRACK_SIZE}t5v0__endcap]
set TAP_CELL      [get_lib_cells *mcu${STDCELL_TRACK_SIZE}t5v0__filltie]

set_boundary_cell_rules -left_boundary_cell $BOUNDARY_CELL -right_boundary_cell $BOUNDARY_CELL
compile_targeted_boundary_cells -all_targets

create_tap_cells -lib_cell $TAP_CELL -pattern stagger -distance 40

set_app_options -name place.legalize.enable_advanced_legalizer -value true

save_block -as floorplan_pre_pg

source [file dirname [info script]]/lib/power_grid.tcl

# The strips between the core edge and an SRAM (SRAM_EDGE_MARGIN, the DC-DC keepout) get blockages from FC
# (auto_generate_blockage*): no cell can sit there, and no Metal4 strap crosses them. Their Metal1 rails connect
# nothing, so check_pg_connectivity reports them as floating. They go.
set removed 0
foreach_in_collection blk [get_placement_blockages -quiet auto_generate_blockage*] {
    lassign [get_attribute $blk bbox] bl bu
    # the rails are lib_cell_pin_connect shapes (not follow_pin); only those that lie inside the strip
    foreach_in_collection rail [get_shapes -intersect [list $bl $bu] -quiet \
        -filter "layer_name == Metal1 && shape_use == lib_cell_pin_connect"] {
        lassign [get_attribute $rail bbox] rl ru
        if {[lindex $rl 0] >= [lindex $bl 0] - 0.001 && [lindex $ru 0] <= [lindex $bu 0] + 0.001 &&
            [lindex $rl 1] >= [lindex $bl 1] - 0.001 && [lindex $ru 1] <= [lindex $bu 1] + 0.001} {
            remove_shapes $rail
            incr removed
        }
    }
}
puts "INFO: removed $removed Metal1 rail pieces in the SRAM edge strips"
check_pg_connectivity -check_std_cell_pins none

# The power pin band (PG_PIN_BAND) along the west, east and south edges: only the mesh stripes on Metal4 and Metal5,
# no signal routing. The LEF leaves these layers open there, for the parent to reach the pins.
foreach {name b} [list west  [list {0 0} [list $PG_PIN_BAND $block_h]] \
                       east  [list [list [expr {$block_w - $PG_PIN_BAND}] 0] [list $block_w $block_h]] \
                       south [list {0 0} [list $block_w $PG_PIN_BAND]]] {
    create_routing_blockage -boundary $b -layers {Metal4 Metal5} -name_prefix pg_pin_band_$name
}

set ACTIVE_STEP "02_floorplan"
source [file dirname [info script]]/lib/reporting.tcl

save_block -as floorplan
print_message_info -ids * -summary
