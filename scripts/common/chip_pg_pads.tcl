###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Supply pins of the pad ring (CHIP_FLOORPLAN=1)
###############################################################################
# VSS runs around the whole ring (the breakers do not cut it, every dvss pad ties DVSS to VSS): DVSS and VSS go to
# VSS on every IO cell. DVDD and VDD go to the supply net of the ring segment (seg lines of scripts/chip/padring.txt):
# VDD in the CROC segment, one net per DC-DC supply. The DC-DC nets are not routed: the pads and the DC-DC wrappers
# connect by abutment. They name the segments for LVS. connect_pg_net -automatic (also inside clock_opt) puts every IO
# cell on VDD again, so 04, 05 and 06 call this after it.

# IO cells of the CROC segment: the south side, and the west and east sides below the breakers brk_w0 and brk_e0
proc chip_croc_io {} {
    set ring_in 376.0   ;# inner edge of the pad ring: 26 um edge spacing + 350 um pad
    set die [get_attribute [current_block] boundary_bbox]
    set die_w [lindex $die 1 0]
    set yw [lindex [get_attribute [get_cells brk_w0] boundary_bbox] 0 1]
    set ye [lindex [get_attribute [get_cells brk_e0] boundary_bbox] 0 1]
    set croc {}
    foreach_in_collection c [get_cells -filter "ref_name =~ gf180mcu_fd_io__*"] {
        set bb [get_attribute $c boundary_bbox]
        set cx [expr {([lindex $bb 0 0] + [lindex $bb 1 0]) / 2.0}]
        set cy [expr {([lindex $bb 0 1] + [lindex $bb 1 1]) / 2.0}]
        if {$cy < $ring_in || ($cx < $ring_in && $cy < $yw) || ($cx > $die_w - $ring_in && $cy < $ye)} {
            append_to_collection croc $c
        }
    }
    return $croc
}

set CHIP_PADRING [file normalize [file dirname [info script]]/../chip/padring.txt]

# Supply segment net of every IO cell. Pads: the seg lines of padring.txt. Corners: their two neighbour pads.
# IO fillers and breakers: the nearest pad on the same side (a filler never sits across a breaker).
proc chip_segment_nets {} {
    global CHIP_PADRING
    set seg_of_pad [dict create]
    set pad_of_num [dict create]
    set f [open $CHIP_PADRING]
    foreach line [split [read $f] "\n"] {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        switch [lindex $line 0] {
            pad { dict set pad_of_num [lindex $line 1] pad_[lindex $line 2] }
            seg {
                foreach r [lrange $line 2 end] {
                    lassign [split $r -] lo hi
                    if {$hi eq ""} { set hi $lo }
                    for {set n $lo} {$n <= $hi} {incr n} { dict set seg_of_pad $n [lindex $line 1] }
                }
            }
        }
    }
    close $f
    set net_of [dict create]
    set pads {}
    dict for {n inst} $pad_of_num {
        if {![dict exists $seg_of_pad $n]} { error "ERROR: pad $n ($inst) is in no supply segment of padring.txt" }
        dict set net_of $inst [dict get $seg_of_pad $n]
        set bb [get_attribute [get_cells $inst] boundary_bbox]
        lappend pads [list $inst [expr {([lindex $bb 0 0] + [lindex $bb 1 0]) / 2.0}] [expr {([lindex $bb 0 1] + [lindex $bb 1 1]) / 2.0}]]
    }
    # corners SW, NW, SE, NE: between pads 43/44, 1/108, 54/55, 97/98
    foreach {c n} {corner_0 44 corner_1 1 corner_2 55 corner_3 98} {
        dict set net_of $c [dict get $seg_of_pad $n]
    }
    foreach_in_collection c [get_cells -filter "ref_name =~ gf180mcu_fd_io__*"] {
        set inst [get_object_name $c]
        if {[dict exists $net_of $inst]} { continue }
        set bb [get_attribute $c boundary_bbox]
        set cx [expr {([lindex $bb 0 0] + [lindex $bb 1 0]) / 2.0}]
        set cy [expr {([lindex $bb 0 1] + [lindex $bb 1 1]) / 2.0}]
        set best ""
        set dmin 1e9
        foreach p $pads {
            lassign $p pi px py
            # same side: the pad centre shares the cell centre x (west/east) or y (south/north)
            if {abs($px - $cx) > 1.0 && abs($py - $cy) > 1.0} { continue }
            set d [expr {abs($px - $cx) + abs($py - $cy)}]
            if {$d < $dmin} { set dmin $d; set best $pi }
        }
        if {$best eq ""} { error "ERROR: IO cell $inst has no pad on its side" }
        dict set net_of $inst [dict get $net_of $best]
    }
    return $net_of
}

proc chip_connect_pads {} {
    set io [get_cells -filter "ref_name =~ gf180mcu_fd_io__*"]
    set net_of [chip_segment_nets]
    foreach_in_collection p [get_pins -quiet -physical_context -of $io -filter "name == DVDD || name == VDD"] {
        set n [get_nets -quiet -of $p]
        if {[sizeof_collection $n]} { disconnect_net -net $n $p }
    }
    set count [dict create]
    dict for {inst net} $net_of {
        if {[sizeof_collection [get_nets -quiet $net]] == 0} { create_net -power $net }
        set p [get_pins -quiet -physical_context [list $inst/DVDD $inst/VDD]]
        if {[sizeof_collection $p]} { connect_pg_net -net $net $p; dict incr count $net }
    }
    connect_pg_net -net VSS [get_pins -quiet -physical_context -of $io -filter "name == DVSS || name == VSS"]
    puts "INFO: pad ring supplies (IO cells per net): $count"
}

# The core-side inputs of the DC-DC pads stay open: the DC-DC wrappers drive them by abutment. compile_fusion ties
# every floating input to a constant (and placement makes tie cells of it), dont_touch or not, so the steps call
# this after each compile_fusion, clock_opt and route_opt. Tie cells left without a load are removed.
proc chip_float_dcdc_pins {} {
    set dcdc [remove_from_collection [get_cells pad_* -filter "ref_name =~ gf180mcu_fd_io__*"] [chip_croc_io]]
    set pins [get_pins -quiet -of $dcdc -filter "direction == in && name != PAD && name != ASIG5V"]
    set tied {}
    foreach_in_collection p $pins {
        if {[sizeof_collection [get_nets -quiet -of $p]]} { append_to_collection tied $p }
    }
    set drivers [get_cells -quiet -of [get_pins -quiet -leaf -of [get_nets -quiet -of $tied] -filter "direction == out"]]
    if {[sizeof_collection $tied]} { disconnect_net $tied }
    set removed 0
    foreach_in_collection d $drivers {
        set loads [get_pins -quiet -leaf -of [get_nets -quiet -of [get_pins -quiet -of $d -filter "direction == out"]] -filter "direction == in"]
        if {[sizeof_collection $loads] == 0} { remove_cells $d; incr removed }
    }
    puts "INFO: DC-DC pad inputs: [sizeof_collection $tied] of [sizeof_collection $pins] were tied, disconnected, $removed tie cells removed"
}
