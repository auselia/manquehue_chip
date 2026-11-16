# Sign-off DRC ECOs in 06_finish.tcl: reroute under KLayout markers, cell moves, filler swaps, SRAM clock
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: source in 06_finish.tcl, then call the procs
# in:  the KLayout deck of setup.tcl (DRC_DECK, DRC_ECO_DECKS), utils/drc_markers.py
# out: the ECOs in the block, <run>/drc_eco/ (the DRC runs of every pass)
# drc_eco_reroute: the FC router knows only the rules of the technology file, so a routed net can break a foundry
# rule (for example V1.3c, CO.6a). Runs the wafer.space KLayout deck on the routing rules, reroutes the signal nets
# under each marker and checks again. A marker that comes back after a reroute moves the logic cell under it to
# the nearest free place in its row (fillers out, cell moved, gap filled again, route_eco).

set DRC_ECO_HELPER [file normalize [file join [file dirname [info script]] .. .. utils drc_markers.py]]

# Only standard cells move, never a fixed cell or a pad cell.
proc drc_eco_reroute {run_dir} {
  global TOP_MODULE PDK_DIR ICC2GDS_LAYERMAP KLAYOUT_BIN DRC_DECK DRC_ECO_DECKS DRC_ECO_MAX_PASSES DRC_ECO_HELPER
  global DCAP_CELLS FILL_CELLS

  set eco_dir [file join $run_dir drc_eco]
  file mkdir $eco_dir
  set helper $DRC_ECO_HELPER
  set gds_list [glob ${PDK_DIR}/gds/*.gds]
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
# Placement ECO for base-layer rules from two cells in neighbouring rows, for example DF.6_5V: the poly end of a gate
# in one row is 0.395 um from the COMP of a cell in the row above (minimum 0.4 um). Runs the COMP deck of the
# wafer.space rules, swaps the smaller logic cell under each marker with its neighbour in the row (the two cells
# trade footprints, so both stay legal), repairs the routes and checks again. A marker that comes back gets the moves
# by sites. In a full row a move does not work: legalization puts the cell back in its own hole. A flip does not work
# either: the site has no symmetry, so legalization turns a mirrored cell back.
# Sourced from 06_finish.tcl before the fillers.

# Legalization with no site near a cell can send it far away, and that breaks timing and transition limits. It also
# fills the hole of the cell, so a second legalization cannot bring it back. The positions at the start of a pass are
# legal and match the routes, so the cells go back to these exact positions. A position is the lower-left corner of
# the cell and its orientation: the origin of a mirrored (MX) cell is not its lower-left corner.
proc drc_eco_far_cells {origins limit} {
  set far [list]
  dict for {name o} $origins {
    lassign [lindex [get_attribute [get_cells $name] boundary_bbox] 0] x y
    set dist [expr {abs($x - [lindex $o 0]) + abs($y - [lindex $o 1])}]
    if {$dist > $limit} { lappend far "$name $dist" }
  }
  return $far
}

proc drc_eco_undo_pass {pass origins} {
  set n 0
  dict for {name o} $origins {
    set c [get_cells $name]
    if {[lindex [get_attribute $c boundary_bbox] 0] ne [lrange $o 0 1] || [get_attribute $c orientation] ne [lindex $o 2]} {
      set_cell_location -coordinates [lrange $o 0 1] -orientation [lindex $o 2] $c
      incr n
    }
  }
  puts "WARNING: placement DRC ECO pass $pass: pass undone, $n cell(s) back, ECO stopped, the markers stay open"
}

# drc_eco_row_neighbour <cell>: the movable logic cell that abuts the cell in its row, on the right, else on the left
proc drc_eco_row_neighbour {c} {
  lassign [get_attribute $c boundary_bbox] lo hi
  set y [expr {[lindex $lo 1] + 1}]
  set filter "is_hard_macro == false && physical_status != fixed && ref_name !~ *fill* && ref_name !~ *endcap* && ref_name !~ *tap*"
  foreach x [list [expr {[lindex $hi 0] + 0.1}] [expr {[lindex $lo 0] - 0.2}]] {
    set n [get_cells -hierarchical -quiet -intersect [list [list $x $y] [list [expr {$x + 0.1}] [expr {$y + 1}]]] -filter $filter]
    if {[sizeof_collection $n] == 1} { return $n }
  }
  return ""
}

# drc_eco_swap <a> <b>: two abutting cells of one row trade places, each keeps its orientation
proc drc_eco_swap {a b} {
  lassign [get_attribute $a boundary_bbox] alo ahi
  lassign [get_attribute $b boundary_bbox] blo bhi
  set left [expr {min([lindex $alo 0], [lindex $blo 0])}]
  set y [lindex $alo 1]
  if {[lindex $alo 0] < [lindex $blo 0]} {
    set first $b; set second $a; set w [expr {[lindex $bhi 0] - [lindex $blo 0]}]
  } else {
    set first $a; set second $b; set w [expr {[lindex $ahi 0] - [lindex $alo 0]}]
  }
  set_cell_location -coordinates [list $left $y] -orientation [get_attribute $first orientation] $first
  set_cell_location -coordinates [list [expr {$left + $w}] $y] -orientation [get_attribute $second orientation] $second
}

proc drc_eco_move_cells {eco_dir rules} {
  global TOP_MODULE PDK_DIR ICC2GDS_LAYERMAP KLAYOUT_BIN DRC_DECK DRC_ECO_MAX_PASSES DRC_ECO_HELPER

  file mkdir $eco_dir
  set gds_list [glob ${PDK_DIR}/gds/*.gds]
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
      dict set origins [get_object_name $c] [concat [lindex [get_attribute $c boundary_bbox] 0] [get_attribute $c orientation]]
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
      set sorted [sort_collection $cells area]
      # First try: the smaller cell swaps with the cell next to it in the row (right, else left)
      if {$k == 0} {
        set c [index_collection $sorted 0]
        set name [get_object_name $c]
        if {$name in $moved} { continue }
        set n [drc_eco_row_neighbour $c]
        if {$n ne "" && [get_object_name $n] ni $moved} {
          drc_eco_swap $c $n
          puts "INFO: placement DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1}, swapping $name ([get_attribute $c ref_name]) with [get_object_name $n] ([get_attribute $n ref_name])"
          lappend moved $name [get_object_name $n]
          continue
        }
        # no neighbour to swap with: the 2-site move of the next try
        set k 1
        dict set tries $key 2
      }
      # The marker came back twice or three times: every cell under it moves 4 and then 6 sites, the other way each time.
      if {$k == 2 || $k == 3} {
        set dir [expr {$k % 2 == 0 ? -1 : 1}]
        foreach_in_collection c $cells {
          move_objects -delta [list [expr {(2 * $k) * $dir * $site_w}] 0] $c
          lappend moved [get_object_name $c]
        }
        puts "INFO: placement DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1} came back, all cells under it moved by [expr {(2 * $k) * $dir}] sites"
        continue
      }
      # After four tries the marker stays open for a hand fix. A blockage here sent a flip-flop 1.3 mm away.
      if {$k >= 4} {
        puts "INFO: placement DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1} came back, marker stays open"
        continue
      }
      # The marker came back once: the smaller cell moves 2 sites
      set c [index_collection $sorted 0]
      set name [get_object_name $c]
      if {$name in $moved} { continue }
      set dir 1
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

# finish_sram_clk_buffers: a clkbuf_8 next to the CLK pin of every SRAM, then route_eco. Without it the long clock
# wire to the pin breaks the slew limit of the SRAM (1.55 ns), and the optimization does not fix it.
proc finish_sram_clk_buffers {} {
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
  legalize_placement
  foreach n $new {
    set c [get_cells $n]
    puts "INFO: SRAM clock buffer $n ([get_attribute $c ref_name]) at [get_attribute $c origin]"
  }
  route_eco
}

# Scan-shift hold
# In scan shift every flop captures the Q of its neighbour, mostly a straight Q to SI wire. route_opt leaves some of
# them with negative hold in the scan scenarios (up to -0.70 ns at slow and -0.49 ns at fast, clock skew of up to
# 2.4 ns between neighbours in the chain). Found in the block, so any route gets the fix: each scan end point (SI
# pin, or D pin of a plain flop of the chain) with scan hold slack under the margin (0.05 ns: Fusion Compiler
# is about 0.1 ns more pessimistic than PrimeTime on these paths) gets a delay cell in front of it,
# next to the flop. The cell steps up the list until the slack is met, a second cell is added after the last one.
# A D pin is also a functional path: it gets a cell only with enough functional setup slack.
proc scan_hold_slack {pin scen} {
  set p [get_timing_paths -delay_type min -scenarios $scen -to $pin -max_paths 1]
  if {[sizeof_collection $p] == 0} { return 1000.0 }
  return [get_attribute $p slack]
}
proc finish_scan_hold_fix {{margin 0.05} {setup_keep 2.0}} {
  set scen [get_scenarios -quiet scan_*]
  if {[sizeof_collection $scen] == 0} { puts "INFO: scan hold fix: no scan scenarios"; return }
  set func [get_scenarios -quiet $::CORNERS]
  set ends [get_pins -quiet -hierarchical */SI]
  set dplain [get_pins -quiet -of_objects [get_cells -quiet -hierarchical -filter "ref_name =~ *__dff*"] -filter "lib_pin_name == D"]
  set ends [add_to_collection $ends $dplain]
  update_timing
  set todo [dict create]
  foreach_in_collection p [get_timing_paths -delay_type min -scenarios $scen -to $ends -slack_lesser_than $margin -max_paths 100000 -nworst 1] {
    set e [get_object_name [get_attribute $p endpoint]]
    set s [get_attribute $p slack]
    if {![dict exists $todo $e] || $s < [dict get $todo $e]} { dict set todo $e $s }
  }
  puts "INFO: scan hold fix: [dict size $todo] end point(s) under $margin ns"
  set steps [list]
  foreach n {clkbuf_1 dlya_1 dlyb_1 dlyc_1 dlyd_1} { lappend steps [get_lib_cells */gf180mcu_fd_sc_mcu7t5v0__$n] }
  set new [list]
  set i 0
  dict for {pn s0} $todo {
    set pin [get_pins $pn]
    set flop [get_cells -of_objects $pin]
    if {[get_attribute $pin lib_pin_name] eq "D"} {
      set sp [get_timing_paths -delay_type max -scenarios $func -to $pin -max_paths 1]
      set ss [expr {[sizeof_collection $sp] ? [get_attribute $sp slack] : 1000.0}]
      if {$ss < $setup_keep} { puts "WARNING: scan hold fix: $pn hold $s0 ns, functional setup slack $ss ns, left as it is"; continue }
    }
    set org [lindex [get_attribute $flop boundary_bbox] 0]
    set tag eco_scanhold_[incr i]
    add_buffer -new_cell_names $tag -lib_cell [lindex $steps 0] $pin
    set c [get_cells ${tag}*]
    set_cell_location -coordinates $org $c
    lappend new [get_object_name $c]
    set k 0
    set ncell 1
    set s [scan_hold_slack $pin $scen]
    while {$s < $margin} {
      if {$k < [llength $steps] - 1} {
        incr k
        size_cell $c [lindex $steps $k]
      } elseif {[llength $new] < 4 * [dict size $todo]} {
        set tag eco_scanhold_[incr i]
        add_buffer -new_cell_names $tag -lib_cell [lindex $steps 0] $pin
        set c [get_cells ${tag}*]
        set_cell_location -coordinates $org $c
        lappend new [get_object_name $c]
        set k 0
        incr ncell
      } else { break }
      set s [scan_hold_slack $pin $scen]
    }
    puts "INFO: scan hold fix: $pn [format %.3f $s0] -> [format %.3f $s] ns ($ncell cell(s), last [get_attribute $c ref_name])"
  }
  if {[llength $new] == 0} { return }
  # A full legalization: with -cells only, the new buffers went up to 340 um away, the rows near them are full.
  legalize_placement
  route_eco
  update_timing
  set w [get_timing_paths -delay_type min -scenarios $scen -to $ends -max_paths 1]
  puts "INFO: scan hold fix: [llength $new] cell(s), scan hold WNS after route_eco [format %.3f [get_attribute $w slack]] ns"
}

# Max transition and max capacitance after route_opt
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
