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

proc drc_eco_reroute {run_dir} {
  global TOP_MODULE PDK_DIR ICC2GDS_LAYERMAP KLAYOUT_BIN DRC_DECK DRC_ECO_DECKS DRC_ECO_MAX_PASSES DRC_ECO_HELPER
  global DCAP_CELLS FILL_CELLS

  set eco_dir [file join $run_dir drc_eco]
  file mkdir $eco_dir
  set helper $DRC_ECO_HELPER
  set gds_list [glob ${PDK_DIR}/gds/*.gds]
  set site_w [get_attribute [index_collection [get_site_defs] 0] width]
  set prev [list]

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
          -filter "is_hard_macro == false && ref_name !~ *fill* && ref_name !~ *endcap*"]
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
        puts "WARNING: DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1} repeats, no free place for $name within 6 sites"
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

proc drc_eco_move_cells {eco_dir rules} {
  global TOP_MODULE PDK_DIR ICC2GDS_LAYERMAP KLAYOUT_BIN DRC_DECK DRC_ECO_MAX_PASSES DRC_ECO_HELPER

  file mkdir $eco_dir
  set gds_list [glob ${PDK_DIR}/gds/*.gds]
  set site_w [get_attribute [index_collection [get_site_defs] 0] width]

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

    set moved [list]
    foreach m $markers {
      lassign $m x0 y0 x1 y1 rule
      set d 0.1
      set area [list [list [expr {$x0 - $d}] [expr {$y0 - $d}]] [list [expr {$x1 + $d}] [expr {$y1 + $d}]]]
      set cells [get_cells -hierarchical -intersect $area -quiet \
          -filter "is_hard_macro == false && ref_name !~ *fill* && ref_name !~ *endcap*"]
      if {[sizeof_collection $cells] == 0} {
        puts "WARNING: placement DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1} has no logic cell under it"
        continue
      }
      set c [index_collection [sort_collection $cells area] 0]
      set name [get_object_name $c]
      if {$name in $moved} { continue }
      puts "INFO: placement DRC ECO pass $pass: $rule at {$x0 $y0 $x1 $y1}, moving $name ([get_attribute $c ref_name]) by 2 sites"
      move_objects -delta [list [expr {2 * $site_w}] 0] $c
      lappend moved $name
    }
    if {[llength $moved] == 0} {
      puts "WARNING: placement DRC ECO pass $pass: [llength $markers] violation(s), no cell to move, stopping"
      return
    }
    legalize_placement -cells [get_cells $moved]
    route_eco
  }
  puts "WARNING: placement DRC ECO: violations remain after $DRC_ECO_MAX_PASSES pass(es), see $eco_dir"
}
