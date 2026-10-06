###############################################################################
# Signoff-driven DRC ECO: reroute the nets that the real DRC deck flags.
# Fusion Compiler's router only knows the rules in the technology file, so some foundry
# rules (e.g. V1.3c, Via1 end-of-line overlap) can be violated by a routed net without FC
# noticing. This runs the wafer.space KLayout deck on the routing rules, reroutes the signal
# nets under any marker, and checks again. Sourced from 06_finish.tcl after detail routing.
###############################################################################

set DRC_ECO_HELPER [file normalize [file join [file dirname [info script]] .. utils drc_markers.py]]

proc drc_eco_reroute {run_dir} {
  global TOP_MODULE PDK_DIR ICC2GDS_LAYERMAP KLAYOUT_BIN DRC_DECK DRC_ECO_DECKS DRC_ECO_MAX_PASSES DRC_ECO_HELPER

  set eco_dir [file join $run_dir drc_eco]
  file mkdir $eco_dir
  set helper $DRC_ECO_HELPER
  set gds_list [glob ${PDK_DIR}/gds/*.gds]

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

    set nets [list]
    foreach m $markers {
      lassign $m x0 y0 x1 y1 rule
      # Look 0.3 um around the marker: the routing that causes a rule such as CO.6a (a Metal1 jog next to
      # a cell contact) can sit a fraction of a um away from where the deck puts the marker.
      set d 0.3
      set area [list [list [expr {$x0 - $d}] [expr {$y0 - $d}]] [list [expr {$x1 + $d}] [expr {$y1 + $d}]]]
      # Contact rules involve only Metal1 routing; the other rules can involve any metal.
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
    if {[llength $signal_nets] == 0} {
      puts "WARNING: DRC ECO pass $pass: [llength $markers] violation(s) but no signal net under them, stopping"
      return
    }
    puts "INFO: DRC ECO pass $pass: rerouting [llength $signal_nets] net(s): $signal_nets"
    remove_routes -nets [get_nets $signal_nets] -detail_route
    route_eco
    check_routes -drc true -antenna false -open_net true
  }
  puts "WARNING: DRC ECO: violations remain after $DRC_ECO_MAX_PASSES pass(es), see $eco_dir"
}
