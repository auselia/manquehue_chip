###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Design rules of the implementation, per scenario
###############################################################################

# Max transition is 0.9 times the library limit of the corner (gf180mcu_fd_sc_mcu7t5v0: 7.0 ns ss, 4.0 ns tt, 2.6 ns
# ff), so Fusion Compiler fixes the nets that PrimeTime finds just over the library limit. A fixed 1.5 ns is far too
# strict at ss 125 C: 57732 nets go over it.
# No design-level max capacitance or max fanout: with those the macro routed with 6432 DRCs.
# A saved block keeps the rules of an earlier run, so they are removed first.
# 04_cts.tcl and 05_route.tcl call design_rules again, so no step loses them.
proc design_rules {} {
  set prev [current_scenario]
  foreach_in_collection s [all_scenarios] {
    current_scenario $s
    set n [get_object_name $s]
    if {[string match *slow* $n]} { set tran 6.3 } elseif {[string match *fast* $n]} { set tran 2.34 } else { set tran 3.6 }
    set_max_transition $tran [current_design]
    catch {remove_max_capacitance [current_design]}
    catch {remove_max_fanout [current_design]}
  }
  current_scenario $prev
}
