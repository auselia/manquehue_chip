# Stripe vias too close to a macro pin connection (Magic DRC "Via4 width < 0.56").
#
# At the SRAM rings the power grid puts two via arrays on the same Metal5 ring: the macro pin connection from the SRAM
# power route, and a stripe via from a Metal4 stripe that overlaps that route. Where the two arrays are less than
# 0.28 um apart (the Via4 spacing rule is 0.26 um, so KLayout passes them), Magic merges them into one contact area and
# reports its slivers as Via4 width errors. The stripe via adds no connection there: its Metal4 stripe already overlaps
# the SRAM power route. This removes such stripe vias, only on the same cut layer and the same net.
proc pg_via_eco_remove_close_stripe_vias {{min_gap 0.28}} {
  set removed 0
  foreach_in_collection mv [get_vias -filter "shape_use==macro_pin_connect" -quiet] {
    if {![regexp {_Via(\d)_} [get_attribute $mv via_def.name] -> lay]} continue
    set bb  [get_attribute $mv bbox]
    set win [list [list [expr {[lindex $bb 0 0] - $min_gap}] [expr {[lindex $bb 0 1] - $min_gap}]] \
                  [list [expr {[lindex $bb 1 0] + $min_gap}] [expr {[lindex $bb 1 1] + $min_gap}]]]
    set net [get_object_name [get_nets -of_objects $mv -quiet]]
    foreach_in_collection sv [get_vias -intersect $win -filter "shape_use==stripe" -quiet] {
      if {![regexp "_Via${lay}_" [get_attribute $sv via_def.name]]} continue
      if {[get_object_name [get_nets -of_objects $sv -quiet]] ne $net} continue
      set sb  [get_attribute $sv bbox]
      set gap [expr {max(0, [lindex $sb 0 0] - [lindex $bb 1 0], [lindex $bb 0 0] - [lindex $sb 1 0], \
                            [lindex $sb 0 1] - [lindex $bb 1 1], [lindex $bb 0 1] - [lindex $sb 1 1])}]
      if {$gap >= $min_gap} continue
      puts [format "INFO: pg via ECO: removing %s (%s, %s) %.3f um from %s" [get_object_name $sv] \
                   [get_attribute $sv via_def.name] $net $gap [get_object_name $mv]]
      remove_objects $sv
      incr removed
    }
  }
  puts "INFO: pg via ECO: $removed stripe via(s) removed"
  return $removed
}
