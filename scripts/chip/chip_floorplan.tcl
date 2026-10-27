###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Chip floorplan on the AC3E pad ring (sourced by 02_floorplan.tcl when CHIP_FLOORPLAN=1)
###############################################################################
# Die 1936 x 5122 um, 108 pads, 12 ring breakers, the 5 wafer.space IPs, the DC-DC wrappers in the north, and the
# croc logic in the south. Pads 75 x 350 um at 26 um from the die edge, corners 355 um.
# The pads and breakers are instances of the netlist top (rtl/chip/chip_top.sv). A pad that is not in the netlist is
# created here, unconnected.

set PAD_EDGE      26.0
set PAD_DEPTH     350.0
set PAD_WIDTH     75.0
set CORNER_SIZE   355.0
set DIE_W         1936.0
set DIE_H         5122.0
set CORE_MARGIN   404.0
# The croc PG ring (power_grid.tcl: 2 + 10 + 2 + 10 um outside the core) fits between the core and the wrappers
set DCDC_GAP      30.0

# DC-DC wrappers: lower-left corner where they were drawn (dcdc_abstract.py)
set dcdc_loc [dict create]
foreach m $CHIP_DCDC_MACROS {
    set f [open chip_abstracts/$m.loc]
    dict set dcdc_loc $m [string trim [read $f]]
    close $f
}

# Core (standard-cell rows) only in the south, up to DCDC_GAP under the lowest wrapper: the croc logic stays there
set croc_top [expr {$DIE_H - $CORE_MARGIN}]
dict for {m xy} $dcdc_loc {
    set y [expr {[lindex $xy 1] - $DCDC_GAP}]
    if {$y < $croc_top} { set croc_top $y }
}
# -core_offset is {left top right bottom}
initialize_floorplan -control_type die -side_length [list $DIE_W $DIE_H] -site_def $SITE_DEF \
    -core_offset [list $CORE_MARGIN [expr {$DIE_H - $croc_top}] $CORE_MARGIN $CORE_MARGIN]
puts "INFO: croc core area [get_attribute [current_block] core_area_bbox]"

# Pads and breakers: scripts/chip/padring.txt, also read by scripts/chip/gen_chip_top.py for the netlist top
set chip_pads {}
set chip_breakers {}
set f [open [file dirname [info script]]/padring.txt]
foreach line [split [read $f] "\n"] {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} { continue }
    switch [lindex $line 0] {
        pad { lappend chip_pads [lrange $line 1 3] }
        brk { lappend chip_breakers [lrange $line 1 2] }
    }
}
close $f

# Side and position of a pad: the lower-left coordinate along its side (y on west/east, x on south/north)
# W/E: 100 um pitch from 423.5; S/N: 104 um pitch from 410.5 (the AC3E padframe rule)
proc pad_side_loc {n} {
    if {$n <= 43} { return [list left   [expr {4623.5 - 100.0 * ($n - 1)}]] }
    if {$n <= 54} { return [list bottom [expr {410.5 + 104.0 * ($n - 44)}]] }
    if {$n <= 97} { return [list right  [expr {423.5 + 100.0 * ($n - 55)}]] }
    return [list top [expr {1450.5 - 104.0 * ($n - 98)}]]
}

# Orientation per side, as the LibreLane pad ring places them (DEF FW, W, N, FS): the DC-DC wrappers connect to
# the pads by abutment and are drawn for this orientation
set side_orient {left MXR90 right R90 bottom R0 top MX}

# Expected lower-left corner of a cell of width w on a side at position loc
proc pad_origin {side loc w} {
    global PAD_EDGE PAD_DEPTH DIE_W DIE_H
    switch $side {
        left   { return [list $PAD_EDGE $loc] }
        right  { return [list [expr {$DIE_W - $PAD_EDGE - $PAD_DEPTH}] $loc] }
        bottom { return [list $loc $PAD_EDGE] }
        top    { return [list $loc [expr {$DIE_H - $PAD_EDGE - $PAD_DEPTH}]] }
    }
}

# Expected placement of every ring cell: inst -> {side loc ref}
set ring_cells [dict create]
foreach p $chip_pads {
    lassign $p n sig cell
    lassign [pad_side_loc $n] side loc
    dict set ring_cells pad_$sig [list $side $loc gf180mcu_fd_io__$cell]
}
foreach b $chip_breakers {
    lassign $b brk n
    lassign [pad_side_loc $n] side loc
    # W counts downwards: the gap after pad n is below it. E counts upwards: the gap is above it.
    if {$side eq "left"} { set bloc [expr {$loc - 15.0}] } else { set bloc [expr {$loc + $PAD_WIDTH + 10.0}] }
    dict set ring_cells $brk [list $side $bloc gf180mcu_fd_io__brk5]
}

# ------------------------------------------------------------------------------
# 1. Pad ring
# ------------------------------------------------------------------------------
dict for {inst v} $ring_cells {
    if {[sizeof_collection [get_cells -quiet $inst]] == 0} {
        create_cell $inst [get_lib_cells */[lindex $v 2]]
    }
}
# Corners SW, NW, SE, NE (DEF N, FS, FN, S)
set ring_corners [list \
    corner_0 [list $PAD_EDGE $PAD_EDGE] R0 \
    corner_1 [list $PAD_EDGE [expr {$DIE_H - $PAD_EDGE - $CORNER_SIZE}]] MX \
    corner_2 [list [expr {$DIE_W - $PAD_EDGE - $CORNER_SIZE}] $PAD_EDGE] MY \
    corner_3 [list [expr {$DIE_W - $PAD_EDGE - $CORNER_SIZE}] [expr {$DIE_H - $PAD_EDGE - $CORNER_SIZE}]] R180 \
]
foreach {inst xy orient} $ring_corners {
    create_cell $inst [get_lib_cells */gf180mcu_fd_io__cor]
}

create_io_ring -name ring -offset $PAD_EDGE -corner_height $CORNER_SIZE

# Guides run clockwise: left from the bottom, top from the left, right from the top, bottom from the right.
# Each cell gets its absolute offset from the guide start (the corner edge), so place_io keeps the exact positions.
foreach side {left top right bottom} {
    set guide_len [expr {($side eq "left" || $side eq "right") ? $DIE_H : $DIE_W}]
    set members {}
    dict for {inst v} $ring_cells {
        lassign $v s loc ref
        if {$s ne $side} { continue }
        set w [get_attribute [get_lib_cells */$ref] width]
        if {$side eq "left" || $side eq "bottom"} {
            if {$side eq "left"} { set off [expr {$loc - $PAD_EDGE - $CORNER_SIZE}] } \
            else                 { set off [expr {$guide_len - $PAD_EDGE - $CORNER_SIZE - $loc - $w}] }
        } else {
            if {$side eq "top"}  { set off [expr {$loc - $PAD_EDGE - $CORNER_SIZE}] } \
            else                 { set off [expr {$guide_len - $PAD_EDGE - $CORNER_SIZE - $loc - $w}] }
        }
        lappend members [list $off $inst]
    }
    set members [lsort -real -index 0 $members]
    set order {}
    set cons {}
    foreach m $members {
        lappend order [lindex $m 1]
        append cons "{{absolute} [lindex $m 1] [lindex $m 0]} "
    }
    add_to_io_guide ring.$side [get_cells $order]
    set_signal_io_constraints -io_guide_object [get_io_guides ring.$side] -constraint $cons
}

place_io

# place_io works on the cell bounding box, which is 0.16 um wider than the pad (lib bbox), and has its own
# orientations. Every ring cell is set to its table position (boundary) and the LibreLane orientation.
set ring_moved 0
dict for {inst v} $ring_cells {
    lassign $v side loc ref
    set c [get_cells $inst]
    set w [get_attribute [get_lib_cells */$ref] width]
    set xy [pad_origin $side $loc $w]
    set orient [dict get $side_orient $side]
    set bb [get_attribute $c boundary_bbox]
    if {abs([lindex $bb 0 0] - [lindex $xy 0]) > 0.001 || abs([lindex $bb 0 1] - [lindex $xy 1]) > 0.001 ||
        [get_attribute $c orientation] ne $orient} {
        incr ring_moved
    }
    set_cell_location -coordinates $xy -orientation $orient $c
}
foreach {inst xy orient} $ring_corners {
    set_cell_location -coordinates $xy -orientation $orient [get_cells $inst]
}
puts "INFO: place_io: $ring_moved of [dict size $ring_cells] ring cells set to the table position or orientation"

# Check: every ring cell at its table position, in the LibreLane orientation
set ring_bad 0
dict for {inst v} $ring_cells {
    lassign $v side loc ref
    set c [get_cells $inst]
    set xy [pad_origin $side $loc [get_attribute [get_lib_cells */$ref] width]]
    set bb [get_attribute $c boundary_bbox]
    if {abs([lindex $bb 0 0] - [lindex $xy 0]) > 0.001 || abs([lindex $bb 0 1] - [lindex $xy 1]) > 0.001 ||
        [get_attribute $c orientation] ne [dict get $side_orient $side]} {
        incr ring_bad
        puts "WARNING: ring cell $inst at $bb [get_attribute $c orientation], expected $xy ($side $loc)"
    }
}
if {$ring_bad > 0} {
    error "ERROR: $ring_bad ring cells are not at the table position"
}
puts "INFO: pad ring: [dict size $ring_cells] cells and 4 corners at the table position"
set_fixed_objects [get_cells [dict keys $ring_cells]]
set_fixed_objects [get_cells corner_*]

# Every top-level port is the bond pad of its pad: its terminal is the PAD (ASIG5V) pin, so the port net needs no
# routing (by default the terminals sit on the die edge and the router runs the pad nets through the ring).
set n_term 0
foreach_in_collection port [get_ports *] {
    set pin [get_pins -quiet -of [get_nets -quiet -of $port] -filter "name == PAD || name == ASIG5V"]
    if {[sizeof_collection $pin] != 1} { error "ERROR: port [get_object_name $port] is not on one pad pin" }
    set old [get_terminals -quiet -of $port]
    if {[sizeof_collection $old]} { remove_terminals $old }
    # the bond pad: the pin shape on the top layer (Metal5; ASIG5V also has a Metal2 shape on the core side)
    set layer [lindex [lsort [get_attribute $pin layer_name]] end]
    set shape [get_shapes -quiet -of_objects $pin -filter "layer_name == $layer"]
    set box [expr {[sizeof_collection $shape] ? [get_attribute [index_collection $shape 0] bbox] : [get_attribute $pin bbox]}]
    set t [create_terminal -port $port -layer $layer -boundary $box]
    set_attribute $t physical_status fixed
    incr n_term
}
puts "INFO: $n_term port terminals on their pad pins"

# IO fillers in every gap between corners, pads and breakers, from the table positions (create_io_filler_cells uses
# the lib bbox, 0.16 um wider than the pad, and misplaces them). Widths 10, 5, 1 and 0.1 um (fillnc) fill every gap
# exactly (the end gaps are 42.5 um).
set fill_cells {100 gf180mcu_fd_io__fill10 50 gf180mcu_fd_io__fill5 10 gf180mcu_fd_io__fill1 1 gf180mcu_fd_io__fillnc}
set n_fill 0
foreach side {left right bottom top} {
    set side_len [expr {($side eq "left" || $side eq "right") ? $DIE_H : $DIE_W}]
    # occupied intervals along the side, in 0.1 um: the two corners and every ring cell
    set iv [list [list 0 [expr {round(($PAD_EDGE + $CORNER_SIZE) * 10)}]] \
                 [list [expr {round(($side_len - $PAD_EDGE - $CORNER_SIZE) * 10)}] [expr {round($side_len * 10)}]]]
    dict for {inst v} $ring_cells {
        lassign $v s loc ref
        if {$s ne $side} { continue }
        set w [get_attribute [get_lib_cells */$ref] width]
        lappend iv [list [expr {round($loc * 10)}] [expr {round(($loc + $w) * 10)}]]
    }
    set iv [lsort -integer -index 0 $iv]
    for {set i 0} {$i < [llength $iv] - 1} {incr i} {
        set pos [lindex $iv $i 1]
        set end [lindex $iv [expr {$i + 1}] 0]
        if {$end < $pos} { error "ERROR: ring cells overlap on $side at [expr {$end / 10.0}] um" }
        foreach {fw ref} $fill_cells {
            while {$end - $pos >= $fw} {
                set c [create_cell io_fill_${side}_[incr n_fill] [get_lib_cells */$ref]]
                set_cell_location -coordinates [pad_origin $side [expr {$pos / 10.0}] [expr {$fw / 10.0}]] \
                    -orientation [dict get $side_orient $side] -fixed $c
                incr pos $fw
            }
        }
    }
}
puts "INFO: $n_fill IO fillers"

# ------------------------------------------------------------------------------
# 2. wafer.space IPs (positions of the wafer.space template, librelane/macros/macros_5v.yaml)
# ------------------------------------------------------------------------------
set ws_ips [list \
    qrcode_id        gf180mcu_ws_ip__qrcode_id  {26 26}       R0 \
    shuttle_id       gf180mcu_ws_ip__shuttle_id {26 175.6}    R270 \
    project_id       gf180mcu_ws_ip__project_id {175.6 26}    R0 \
    wafer_space_logo gf180mcu_ws_ip__logo       [list 26 [expr {$DIE_H - 169.25}]] R0 \
    marker           gf180mcu_ws_ip__marker     [list [expr {$DIE_W - 281}] [expr {$DIE_H - 281}]] R0 \
]
foreach {inst ref xy orient} $ws_ips {
    set c [create_cell $inst [get_lib_cells */$ref]]
    set_cell_location -coordinates $xy -orientation $orient -fixed $c
}

# ------------------------------------------------------------------------------
# 3. DC-DC wrappers: placed where they were drawn, they touch the pads, no routing
# ------------------------------------------------------------------------------
foreach m $CHIP_DCDC_MACROS {
    set c [create_cell u_$m [get_lib_cells */$m]]
    set_cell_location -coordinates [dict get $dcdc_loc $m] -orientation R0 -fixed $c
    puts "INFO: DC-DC $m at [get_attribute $c boundary_bbox]"
}
