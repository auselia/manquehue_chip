###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Sign-off DRC ECOs (sourced by 06_finish.tcl)
###############################################################################

# drc_eco_reroute: the FC router knows only the rules of the technology file, so a routed net can break a foundry
# rule (for example V1.3c, CO.6a). Runs the wafer.space KLayout deck on the routing rules, reroutes the signal nets
# under each marker and checks again. A marker that comes back after a reroute moves the logic cell under it to
# the nearest free place in its row (fillers out, cell moved, gap filled again, route_eco).

set DRC_ECO_HELPER [file normalize [file join [file dirname [info script]] .. utils drc_markers.py]]

# Only standard cells move: never a pad (gf180mcu_fd_io__*) or any fixed cell. A marker at a pad is a pad-ring or
# abutment problem (for example a DC-DC wrapper against the pads), not one a cell move can fix.
proc drc_eco_reroute {run_dir} {
  global TOP_MODULE PDK_DIR ICC2GDS_LAYERMAP KLAYOUT_BIN DRC_DECK DRC_ECO_DECKS DRC_ECO_MAX_PASSES DRC_ECO_HELPER
  global DCAP_CELLS FILL_CELLS

  set eco_dir [file join $run_dir drc_eco]
  file mkdir $eco_dir
  set helper $DRC_ECO_HELPER
  set gds_list [glob ${PDK_DIR}/gds/*.gds]
  if {$::CHIP_FLOORPLAN} { set gds_list [chip_gds_files] }
  set site_w [get_attribute [index_collection [get_site_defs] 0] width]
  set prev [list]
  set swapped [dict create]

  for {set pass 1} {$pass <= $DRC_ECO_MAX_PASSES} {incr pass} {
    set gds   [file join $eco_dir pass${pass}.gds]
    set lyrdb [file join $eco_dir pass${pass}.lyrdb]
    write_gds -units 1000 -merge_files $gds_list -merge_gds_top_cell $TOP_MODULE \
        -layer_map ${ICC2GDS_LAYERMAP} -long_names $gds
    catch {exec $KLAYOUT_BIN -b -r $DRC_DECK -rd input=$gds -rd report=$lyrdb -rd variant=D \
        -rd run_mode=deep -rd decks=$DRC_ECO_DECKS > [file join $eco_dir pass${pass}.log] 2>@1}
    file delete $gds
    set markers [split [string trim [exec python3 $helper $lyrdb $TOP_MODULE]] "\n"]
    if {$markers eq ""} {
      puts "INFO: DRC ECO pass $pass: no routing-rule violations"
      return
    }

    # markers that survived a reroute: move the cell under them
    set moved [list]
    foreach m $markers {
      if {$m ni $prev} { continue }
      lassign $m x0 y0 x1 y1 rule
      set d 0.1
      set area [list [list [expr {$x0 - $d}] [expr {$y0 - $d}]] [list [expr {$x1 + $d}] [expr {$y1 + $d}]]]
      set cells [get_cells -hierarchical -intersect $area -quiet \
          -filter "is_hard_macro == false && physical_status != fixed && ref_name !~ gf180mcu_fd_io__* && ref_name !~ *fill* && ref_name !~ *endcap*"]
      if {[sizeof_collection $cells] == 0} {
        puts "WARNING: DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1} repeats and has no logic cell under it"
        continue
      }
      set c [index_collection [sort_collection $cells area] 0]
      set name [get_object_name $c]
      if {$name in $moved} { continue }
      # free the row next to the cell: plain and decap fillers within 6 um (the taps stay)
      set bb [get_attribute $c bbox]
      set row [list [list [expr {[lindex $bb 0 0] - 6.0}] [expr {[lindex $bb 0 1] + 0.5}]] \
                    [list [expr {[lindex $bb 1 0] + 6.0}] [expr {[lindex $bb 1 1] - 0.5}]]]
      set fill [get_objects_by_location -classes cell -intersect $row -quiet]
      if {[sizeof_collection $fill] > 0} {
        set fill [filter_collection $fill "ref_name =~ *fill_* || ref_name =~ *fillcap*"]
        if {[sizeof_collection $fill] > 0} { remove_cells $fill }
      }
      # the nearest free place in the row, 2 to 6 sites left or right of the placement boundary (taps and logic
      # cells stay where they are, a place over one of them would be undone by legalize_placement)
      set pb [get_attribute $c boundary_bbox]
      set dx ""
      foreach k {-2 2 -4 4 -6 6} {
        set nb [list [list [expr {[lindex $pb 0 0] + $k * $site_w + 0.01}] [expr {[lindex $pb 0 1] + 0.5}]] \
                     [list [expr {[lindex $pb 1 0] + $k * $site_w - 0.01}] [expr {[lindex $pb 1 1] - 0.5}]]]
        set hit [remove_from_collection [get_objects_by_location -classes cell -intersect $nb -quiet] $c]
        if {[sizeof_collection $hit] == 0} { set dx $k; break }
      }
      if {$dx eq ""} {
        # no free place: another drive strength of the same function, not wider than the cell, so it stays in its
        # place. Its pins have other metal 1 shapes, the router reaches them in another way (CO.6a on the chip of
        # 7 Nov 2026: an inv_2 that rerouting and moving could not fix).
        set ref [get_attribute $c ref_name]
        set w [get_attribute $c width]
        set alt ""
        foreach lc [get_object_name [sort_collection [get_lib_cells */[regsub {_[0-9]+$} $ref _*]] area]] {
          set lcn [file tail $lc]
          if {$lcn eq $ref || [dict exists $swapped $name,$lcn]} { continue }
          if {[get_attribute [get_lib_cells $lc] width] > $w + 0.001} { continue }
          set alt $lc; dict set swapped $name,$lcn 1; break
        }
        if {$alt eq ""} {
          puts "WARNING: DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1} repeats, no free place and no other size for $name"
        } else {
          puts "INFO: DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1} repeats, no free place: $name $ref -> [file tail $alt]"
          size_cell $c $alt
        }
      } else {
        puts "INFO: DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1} repeats after the reroute, moving $name ([get_attribute $c ref_name]) by $dx sites"
        move_objects -delta [list [expr {$dx * $site_w}] 0] $c
        legalize_placement -cells $c
      }
      set row [list [list [expr {[lindex $bb 0 0] - 6.0}] [lindex $bb 0 1]] [list [expr {[lindex $bb 1 0] + 6.0}] [lindex $bb 1 1]]]
      create_stdcell_fillers -lib_cells $DCAP_CELLS -bboxes $row -prefix eco_dcap
      create_stdcell_fillers -lib_cells $FILL_CELLS -bboxes $row -prefix eco_fill
      connect_pg_net -automatic
      lappend moved $name
    }
    set prev $markers

    set nets [list]
    foreach m $markers {
      lassign $m x0 y0 x1 y1 rule
# 0.3 um around the marker: the routing behind CO.6a (a Metal1 jog at a cell contact) can be a little away.
      set d 0.3
      set area [list [list [expr {$x0 - $d}] [expr {$y0 - $d}]] [list [expr {$x1 + $d}] [expr {$y1 + $d}]]]
# Contact rules involve only Metal1 routing, the other rules any metal.
      set shape_filter [expr {[string match CO.* $rule] ? "layer_name == Metal1" : "layer_name =~ Metal*"}]
      foreach_in_collection s [get_shapes -intersect $area -filter $shape_filter -quiet] {
        set n [get_attribute $s net.name]
        if {$n ne "" && $n ni $nets} { lappend nets $n }
      }
      foreach_in_collection v [get_vias -intersect $area -quiet] {
        set n [get_object_name [get_attribute $v owner]]
        if {$n ne "" && $n ni $nets} { lappend nets $n }
      }
      puts "INFO: DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1}"
    }

    set signal_nets [list]
    foreach n $nets {
      if {[get_attribute [get_nets $n] net_type] eq "signal"} { lappend signal_nets $n }
    }
    if {[llength $signal_nets] == 0 && [llength $moved] == 0} {
      puts "WARNING: DRC ECO pass $pass: [llength $markers] violation(s) but no signal net under them, stopping"
      return
    }
    if {[llength $signal_nets] > 0} {
      puts "INFO: DRC ECO pass $pass: rerouting [llength $signal_nets] net(s): $signal_nets"
      remove_routes -nets [get_nets $signal_nets] -detail_route
    }
    route_eco
    check_routes -drc true -antenna false -open_net true
  }
  puts "WARNING: DRC ECO: violations remain after $DRC_ECO_MAX_PASSES pass(es), see $eco_dir"
}

###############################################################################
# Placement ECO for base-layer rules from two cells in neighbouring rows, for example DF.6_5V: the poly end of a gate
# in one row is 0.395 um from the COMP of a cell in the row above (minimum 0.4 um). Runs the COMP deck of the
# wafer.space rules, moves the smaller logic cell under each marker by two sites, legalizes, repairs the routes and
# checks again. Sourced from 06_finish.tcl before the fillers.
###############################################################################

# Legalization with no site near a cell can send it far away, and that breaks timing and transition limits. It also
# fills the hole of the cell, so a second legalization cannot bring it back. The positions at the start of a pass are
# legal and match the routes, so the cells go back to these exact positions.
proc drc_eco_far_cells {origins limit} {
  set far [list]
  dict for {name o} $origins {
    lassign [get_attribute [get_cells $name] origin] x y
    set dist [expr {abs($x - [lindex $o 0]) + abs($y - [lindex $o 1])}]
    if {$dist > $limit} { lappend far "$name $dist" }
  }
  return $far
}

proc drc_eco_undo_pass {pass origins} {
  set n 0
  dict for {name o} $origins {
    set c [get_cells $name]
    if {[get_attribute $c origin] ne [lrange $o 0 1]} {
      move_objects -to [lrange $o 0 1] $c
      set_attribute $c orientation [lindex $o 2]
      incr n
    }
  }
  puts "WARNING: placement DRC ECO pass $pass: pass undone, $n cell(s) back, ECO stopped, the markers stay open"
}

proc drc_eco_move_cells {eco_dir rules} {
  global TOP_MODULE PDK_DIR ICC2GDS_LAYERMAP KLAYOUT_BIN DRC_DECK DRC_ECO_MAX_PASSES DRC_ECO_HELPER

  file mkdir $eco_dir
  set gds_list [glob ${PDK_DIR}/gds/*.gds]
  if {$::CHIP_FLOORPLAN} { set gds_list [chip_gds_files] }
  set site_w [get_attribute [index_collection [get_site_defs] 0] width]
  # A marker that comes back gets the next cell under it, moved the other way: legalization can put the same cell back.
  set tries [dict create]

  for {set pass 1} {$pass <= $DRC_ECO_MAX_PASSES} {incr pass} {
    set gds   [file join $eco_dir place_pass${pass}.gds]
    set lyrdb [file join $eco_dir place_pass${pass}.lyrdb]
    write_gds -units 1000 -merge_files $gds_list -merge_gds_top_cell $TOP_MODULE \
        -layer_map ${ICC2GDS_LAYERMAP} -long_names $gds
    catch {exec $KLAYOUT_BIN -b -r $DRC_DECK -rd input=$gds -rd report=$lyrdb -rd variant=D \
        -rd run_mode=deep -rd decks=comp > [file join $eco_dir place_pass${pass}.log] 2>@1}
    file delete $gds

    set markers [list]
    foreach m [split [string trim [exec python3 $DRC_ECO_HELPER $lyrdb $TOP_MODULE]] "\n"] {
      if {$m eq ""} { continue }
      set rule [lindex $m 4]
      foreach r $rules { if {[string match $r $rule]} { lappend markers $m; break } }
    }
    if {[llength $markers] == 0} {
      puts "INFO: placement DRC ECO pass $pass: no $rules violations"
      return
    }

    set origins [dict create]
    foreach_in_collection c [get_cells -hierarchical -filter "is_hard_macro == false && physical_status != fixed && ref_name !~ *fill* && ref_name !~ *endcap*"] {
      dict set origins [get_object_name $c] [concat [get_attribute $c origin] [get_attribute $c orientation]]
    }
    set moved [list]
    foreach m $markers {
      lassign $m x0 y0 x1 y1 rule
      set d 0.1
      set area [list [list [expr {$x0 - $d}] [expr {$y0 - $d}]] [list [expr {$x1 + $d}] [expr {$y1 + $d}]]]
      set cells [get_cells -hierarchical -intersect $area -quiet \
          -filter "is_hard_macro == false && physical_status != fixed && ref_name !~ gf180mcu_fd_io__* && ref_name !~ *fill* && ref_name !~ *endcap*"]
      if {[sizeof_collection $cells] == 0} {
        puts "WARNING: placement DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1} has no logic cell under it"
        continue
      }
      set key [format "%.2f_%.2f" $x0 $y0]
      set k [expr {[dict exists $tries $key] ? [dict get $tries $key] : 0}]
      dict set tries $key [expr {$k + 1}]
      # The marker came back once or twice: every cell under it moves 4 and then 6 sites, the other way each time.
      if {$k == 1 || $k == 2} {
        set dir [expr {$k % 2 == 0 ? 1 : -1}]
        foreach_in_collection c $cells {
          move_objects -delta [list [expr {(2 + 2 * $k) * $dir * $site_w}] 0] $c
          lappend moved [get_object_name $c]
        }
        puts "INFO: placement DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1} came back, all cells under it moved by [expr {(2 + 2 * $k) * $dir}] sites"
        continue
      }
      # After three tries the marker stays open for a hand fix. A blockage here sent a flip-flop 1.3 mm away.
      if {$k >= 3} {
        puts "INFO: placement DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1} came back, marker stays open"
        continue
      }
      set sorted [sort_collection $cells area]
      set c [index_collection $sorted [expr {$k % [sizeof_collection $sorted]}]]
      set name [get_object_name $c]
      if {$name in $moved} { continue }
      set dir [expr {$k % 2 == 0 ? 1 : -1}]
      puts "INFO: placement DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1}, moving $name ([get_attribute $c ref_name]) by [expr {2 * $dir}] sites"
      move_objects -delta [list [expr {2 * $dir * $site_w}] 0] $c
      lappend moved $name
    }
    if {[llength $moved] == 0} {
      puts "WARNING: placement DRC ECO pass $pass: [llength $markers] violation(s), no cell to move, stopping"
      return
    }
    set moved [lsort -unique $moved]
    # A blockage can leave a cell with no legal site near it (LGL-055), and that error stops the script. Then the pass
    # is undone, the ECO stops here and the markers stay for the report: the flow goes on.
    if {[catch {legalize_placement -cells [get_cells $moved]} err]} {
      puts "WARNING: placement DRC ECO pass $pass: legalization failed"
      drc_eco_undo_pass $pass $origins
      return
    }
    set far [drc_eco_far_cells $origins 20]
    if {[llength $far] > 0} {
      puts "WARNING: placement DRC ECO pass $pass: cells moved more than 20 um: $far"
      drc_eco_undo_pass $pass $origins
      return
    }
    route_eco
  }
  puts "WARNING: placement DRC ECO: violations remain after $DRC_ECO_MAX_PASSES pass(es), see $eco_dir"
}

# DF.13 / DF.14 after the fillers: a decap filler (fillcap) can have a PMOS in the N-well farther than 15 um from an
# N-well tap. Every fillcap under such a marker is removed, and plain fillers (no devices) fill its place.
proc drc_eco_swap_fillcaps {eco_dir} {
  global TOP_MODULE PDK_DIR ICC2GDS_LAYERMAP KLAYOUT_BIN DRC_DECK DRC_ECO_MAX_PASSES DRC_ECO_HELPER FILL_CELLS

  file mkdir $eco_dir
  set gds_list [glob ${PDK_DIR}/gds/*.gds]
  if {$::CHIP_FLOORPLAN} { set gds_list [chip_gds_files] }

  for {set pass 1} {$pass <= $DRC_ECO_MAX_PASSES} {incr pass} {
    set gds   [file join $eco_dir fill_pass${pass}.gds]
    set lyrdb [file join $eco_dir fill_pass${pass}.lyrdb]
    write_gds -units 1000 -merge_files $gds_list -merge_gds_top_cell $TOP_MODULE \
        -layer_map ${ICC2GDS_LAYERMAP} -long_names $gds
    catch {exec $KLAYOUT_BIN -b -r $DRC_DECK -rd input=$gds -rd report=$lyrdb -rd variant=D \
        -rd run_mode=deep -rd decks=comp > [file join $eco_dir fill_pass${pass}.log] 2>@1}
    file delete $gds

    set boxes [list]
    foreach m [split [string trim [exec python3 $DRC_ECO_HELPER $lyrdb $TOP_MODULE]] "\n"] {
      if {$m eq ""} { continue }
      lassign $m x0 y0 x1 y1 rule
      if {![string match "DF.13_*" $rule] && ![string match "DF.14_*" $rule]} { continue }
      set d 0.1
      set area [list [list [expr {$x0 - $d}] [expr {$y0 - $d}]] [list [expr {$x1 + $d}] [expr {$y1 + $d}]]]
      foreach_in_collection c [get_cells -quiet -intersect $area -filter "ref_name =~ *fillcap*"] {
        lappend boxes [get_attribute $c boundary_bbox]
        puts "INFO: filler DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1}, [get_object_name $c] becomes plain fillers"
        remove_cells $c
      }
    }
    if {[llength $boxes] == 0} {
      puts "INFO: filler DRC ECO pass $pass: no DF.13 / DF.14 marker on a decap filler"
      return
    }
    create_stdcell_fillers -lib_cells $FILL_CELLS -bboxes $boxes -prefix fillcap_swap
    connect_pg_net -automatic
  }
  puts "WARNING: filler DRC ECO: markers remain after $DRC_ECO_MAX_PASSES pass(es), see $eco_dir"
}

###############################################################################
# Hand ECO of the macro on the routed block, before the fillers. Nets over the library limits in PrimeTime get a buffer
# after their driver, so the weak driver sees one small load. Cells under a marker that the automatic ECOs cannot clear
# move far enough to leave the neighbouring cell. Names and positions are from the build of the run in the comments.
###############################################################################
# A cell by its flat name from the sign-off netlist (i_croc_..._reg_17_), at any stage of the hierarchy.
# Chip flow, after the DRC ECO and before the fillers. Two kinds of long wire that the optimization does not fix:
# - the SRAM CLK pins (library limit 1.55 ns, up to 1.82 ns at slow on the chip of 7 Nov 2026): a clkbuf_8 next to
#   each pin, as hand_eco does on the macro route;
# - the core-side inputs A, OE, IE of the IO pads (library limit 1.0 ns, up to 1.25 ns): the pads are IO cells,
#   so compile_fusion does not fix their design rules. A buf_12 at the point of the core area closest to the pin:
#   PrimeTime converts the slew between the thresholds of the standard cell and of the IO library, a buf_4 edge of
#   0.81 ns became 1.12 ns at the pad pin over a 5 fF wire.
# Names and coordinates come from the block, so this works on any chip route.
proc chip_finish_buffers {} {
  set new [list]
  set clkbuf [get_lib_cells */gf180mcu_fd_sc_mcu7t5v0__clkbuf_8]
  foreach_in_collection m [get_cells -filter "ref_name =~ gf180mcu_fd_ip_sram__*"] {
    set p [get_pins [get_object_name $m]/CLK]
    set tag eco_sramclk_[llength $new]
    add_buffer -new_cell_names $tag -lib_cell $clkbuf $p
    set c [get_cells ${tag}*]
    set_cell_location -coordinates [lindex [get_attribute $p bbox] 0] $c
    lappend new [get_object_name $c]
  }
  lassign [get_attribute [current_block] core_area_bbox] cll cur
  set buf [get_lib_cells */gf180mcu_fd_sc_mcu7t5v0__buf_12]
  foreach_in_collection p [get_pins -quiet -of_objects [get_cells -quiet pad_* -filter "ref_name =~ gf180mcu_fd_io__*"] -filter "name == A || name == OE || name == IE"] {
    set net [get_nets -quiet -of_objects $p]
    if {[sizeof_collection $net] == 0} { continue }
    set drv [get_pins -quiet -leaf -of_objects $net -filter "direction == out"]
    if {[sizeof_collection $drv] == 0 || [string match *tie* [get_attribute [get_cells -of_objects $drv] ref_name]]} { continue }
    lassign [lindex [get_attribute $p bbox] 0] x y
    set x [expr {min(max($x, [lindex $cll 0] + 2.0), [lindex $cur 0] - 12.0)}]
    set y [expr {min(max($y, [lindex $cll 1] + 2.0), [lindex $cur 1] - 6.0)}]
    set tag eco_padin_[llength $new]
    add_buffer -new_cell_names $tag -lib_cell $buf $p
    set c [get_cells ${tag}*]
    set_cell_location -coordinates [list $x $y] $c
    lappend new [get_object_name $c]
  }
  legalize_placement
  foreach n $new {
    set c [get_cells $n]
    puts "INFO: chip finish buffer $n ([get_attribute $c ref_name]) at [get_attribute $c origin]"
  }
  route_eco
}

proc hand_eco_cell {flat} {
  set key [string trimright [regsub -all {[^A-Za-z0-9]+} $flat _] _]
  foreach_in_collection c [get_cells -hierarchical -filter "is_hard_macro == false"] {
    if {[string trimright [regsub -all {[^A-Za-z0-9]+} [get_object_name $c] _] _] eq $key} { return $c }
  }
  error "hand ECO: no cell $flat"
}

proc hand_eco {} {
  # Route of croc_soc_20261104_181238. Names and coordinates are valid for that route only.
  # Slow and fast transition over the library limit, on weak drivers with many loads.
  set new [list]
  set buf [get_lib_cells */gf180mcu_fd_sc_mcu7t5v0__buf_4]
  foreach drv {A63704/ZN A63752/ZN A59937/ZN ctmi_58336/Z} {
    set tag eco_drv_[string map {/ _} $drv]
    set bb [get_attribute [get_cells -of_objects [get_pins $drv]] boundary_bbox]
    add_buffer -new_cell_names $tag -lib_cell $buf [get_pins $drv]
    set c [get_cells ${tag}*]
    set_cell_location -coordinates [lindex $bb 0] $c
    lappend new [get_object_name $c]
  }
  # SRAM CLK 1.64 ns against 1.55 ns at slow, from a long wire: a buffer next to each pin.
  set clkbuf [get_lib_cells */gf180mcu_fd_sc_mcu7t5v0__clkbuf_8]
  foreach_in_collection m [get_cells -filter "ref_name =~ gf180mcu_fd_ip_sram__*"] {
    set p [get_pins [get_object_name $m]/CLK]
    set tag eco_sramclk_[llength $new]
    add_buffer -new_cell_names $tag -lib_cell $clkbuf $p
    set c [get_cells ${tag}*]
    lassign [get_attribute $p bbox] ll ur
    set_cell_location -coordinates $ll $c
    lappend new [get_object_name $c]
  }
  # Scan hold at fast, -0.02 ns on two SI pins: a clkbuf_1 (about 0.17 ns) in front of each.
  set dly [get_lib_cells */gf180mcu_fd_sc_mcu7t5v0__clkbuf_1]
  foreach flop {i_user_i_fft_hwpe_i_core_gcnt_q_reg_1_ i_croc_i_dm_top_i_dm_top_i_dm_csrs_progbuf_q_reg_2__28_} {
    set c [hand_eco_cell $flop]
    set tag eco_scanhold_[llength $new]
    add_buffer -new_cell_names $tag -lib_cell $dly [get_pins [get_object_name $c]/SI]
    set b [get_cells ${tag}*]
    set_cell_location -coordinates [lindex [get_attribute $c boundary_bbox] 0] $b
    lappend new [get_object_name $b]
  }
  # A full legalization: with -cells only, the new buffers went up to 340 um away, the rows near them are full.
  legalize_placement
  foreach n $new {
    set c [get_cells $n]
    puts "INFO: hand ECO: $n ([get_attribute $c ref_name]) at [get_attribute $c origin]"
  }
  # DF.6: COMP and poly corners of two cells 0.3995 um apart. One site clears each one, from a search on the GDS. No
  # legalization after this: these sites are free and it could undo the move.
  set site_w [get_attribute [index_collection [get_site_defs] 0] width]
  # One move per marker, the first candidate that overlaps no other cell. Candidates come from a search on the GDS
  # (each one clears the marker). Taps are placed already, the fillers come later. A33481 +1 site was clean, the
  # flip-flop +1 moves overlapped a tap and an and2 (LVS mismatch), A65851 -1 gave a short at its left pin.
  foreach {marker cands} {
    m933 {A33481 1 A33481 2 A33481 3}
    m624 {i_croc_i_dm_top_i_dm_top_i_dm_mem_rdata_q_reg_17_ 1 i_croc_i_dm_top_i_dm_top_i_dm_mem_rdata_q_reg_17_ -1
          i_croc_i_dm_top_i_dm_top_i_dm_mem_rdata_q_reg_17_ -2 A65851 -1}
    m748 {i_user_i_obi_qspi_addr_q_reg_11_ 1 i_user_i_obi_qspi_addr_q_reg_11_ -1 i_user_i_obi_qspi_addr_q_reg_11_ -2
          A62732 -2 A62732 -1}
  } {
    set done 0
    foreach {cell sites} $cands {
      set c [hand_eco_cell $cell]
      move_objects -delta [list [expr {$sites * $site_w}] 0] $c
      lassign [get_attribute $c boundary_bbox] ll ur
      set box [list [list [expr {[lindex $ll 0] + 0.05}] [expr {[lindex $ll 1] + 0.05}]] [list [expr {[lindex $ur 0] - 0.05}] [expr {[lindex $ur 1] - 0.05}]]]
      set hit [remove_from_collection [get_cells -hierarchical -quiet -intersect $box -filter "is_hard_macro == false"] $c]
      if {[sizeof_collection $hit] == 0} {
        puts "INFO: hand ECO: $marker, [get_object_name $c] moved by $sites site(s), now at [get_attribute $c origin]"
        set done 1
        break
      }
      puts "INFO: hand ECO: $marker, [get_object_name $c] by $sites site(s) overlaps [get_object_name $hit], not used"
      move_objects -delta [list [expr {-$sites * $site_w}] 0] $c
    }
    if {!$done} { puts "WARNING: hand ECO: $marker stays open, no free candidate" }
  }
  route_eco
}

###############################################################################
# Max transition and max capacitance after route_opt
###############################################################################
# route_opt leaves weak drivers over the limits (24 nets on the 8 Nov 2026 route, 25 -> 30 during route_opt), FC has
# no fix_eco_drc. Found in the block, so any route gets the fix.
# Nets over max transition or max capacitance in the scenarios that check them: the driver gets the next drive
# strength of the same function (oai32_1 -> oai32_2), or a buf_4 when there is no larger one. Not with little hold slack.
proc finish_drv_nets {} {
  set nets [dict create]
  foreach_in_collection s [get_scenarios -filter "active && name !~ scan_*"] {
    redirect -variable rpt {report_constraints -all_violators -max_transition -max_capacitance -nosplit -scenarios $s}
    foreach line [split $rpt \n] {
      if {![string match *VIOLATED* $line]} { continue }
      # A net is found from its pins (leaf names). Hierarchical net names with [] are no glob pattern, they are escaped.
      set obj [expr {[string match "*PIN :*" $line] ? [lindex $line 2] : [lindex $line 0]}]
      set n [get_nets -quiet -of_objects [get_pins -quiet [string map {[ \\[ ] \\]} $obj]]]
      if {[sizeof_collection $n] == 0} { set n [get_nets -quiet [string map {[ \\[ ] \\]} $obj]] }
      if {[sizeof_collection $n] == 0} { puts "INFO: DRV fix: no net found for $obj"; continue }
      dict set nets [get_object_name $n] 1
    }
  }
  return [dict keys $nets]
}
# Up to 3 passes: an upsized driver can still be too weak, it then gets the next size.
proc finish_drv_fix {} {
  set nets [finish_drv_nets]
  for {set pass 1} {$pass <= 3 && [llength $nets]} {incr pass} {
    puts "INFO: DRV fix pass $pass: [llength $nets] net(s) over max transition or max capacitance"
    finish_drv_pass $nets $pass
    set nets [finish_drv_nets]
  }
  foreach n $nets { puts "INFO: DRV fix: $n stays over the limits" }
}
proc finish_drv_pass {nets pass} {
  set buf [get_lib_cells */gf180mcu_fd_sc_mcu7t5v0__buf_4]
  set new 0
  foreach n $nets {
    set drv [get_pins -quiet -leaf -of_objects [get_nets $n] -filter "direction == out"]
    if {[sizeof_collection $drv] != 1} { puts "INFO: DRV fix: $n has no single cell driver, skipped"; continue }
    set c [get_cells -of_objects $drv]
    set ref [get_attribute $c ref_name]
    if {[get_attribute $c is_hard_macro] || [string match *fd_io__* $ref] || [string match *tie* $ref]} { continue }
    # A driver with little hold margin is left as it is. route_opt hold buffers (clkbuf_1) get their delay from the
    # slow edge that the transition limit flags: sized to clkbuf_2 the path gave -0.12 ns hold at fast, with a buf_4
    # after it -0.40 ns (8 and 9 Nov 2026). PrimeTime checks such a net against the library limit.
    set hold [get_attribute -quiet $drv worst_min_slack]
    set bigger ""
    if {$hold ne "" && $hold < 0.5} {
      puts "INFO: DRV fix: [get_object_name $drv] hold slack $hold ns, net $n left as it is"
      continue
    }
    if {[regexp {^(.*)_([0-9]+)$} $ref -> base x]} {
      foreach lc [get_object_name [get_lib_cells -quiet */${base}_*]] {
        if {[regexp "^${base}_(\[0-9\]+)\$" [file tail $lc] -> y] && $y > $x && ($bigger eq "" || $y < $by)} { set bigger $lc; set by $y }
      }
    }
    if {$bigger ne ""} {
      size_cell $c [get_lib_cells $bigger]
      puts "INFO: DRV fix: [get_object_name $c] $ref -> [file tail $bigger] (net $n)"
    } else {
      set tag eco_drv_${pass}_[incr new]
      add_buffer -new_cell_names $tag -lib_cell $buf $drv
      set_cell_location -coordinates [lindex [get_attribute $c boundary_bbox] 0] [get_cells ${tag}*]
      puts "INFO: DRV fix: buf_4 $tag after [get_object_name $drv] ($ref, net $n)"
    }
  }
  legalize_placement
  route_eco
}
