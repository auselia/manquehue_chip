###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Design rules of the implementation, per scenario
###############################################################################

# Max transition is 0.9 times the library limit of the corner (gf180mcu_fd_sc_mcu7t5v0: 7.0 ns ss, 4.0 ns tt, 2.6 ns
# ff), so Fusion Compiler fixes the nets that PrimeTime finds just over the library limit. A fixed 1.5 ns is far too
# strict at ss 125 C: 57732 nets go over it.
# Max transition only: with max capacitance 0.3 pF and max fanout 20 enforced as well, the macro routed with 6432
# DRCs (hold and fanout buffers in the channel between the SRAMs). The library limits of capacitance stay, and
# PrimeTime finds no capacitance or fanout violation in the macro.
# The rules belong to a scenario. 04_cts.tcl and 05_route.tcl call design_rules again, so no step loses them.
proc design_rules {} {
  set prev [current_scenario]
  foreach_in_collection s [all_scenarios] {
    current_scenario $s
    set n [get_object_name $s]
    if {[string match *slow* $n]} { set tran 6.3 } elseif {[string match *fast* $n]} { set tran 2.34 } else { set tran 3.6 }
    # test 2 Nov: library limits only, no design-level transition limit
    catch {remove_max_transition [current_design]}
    # a block saved with the earlier rules keeps them: remove them
    catch {remove_max_capacitance [current_design]}
    catch {remove_max_fanout [current_design]}
  }
  current_scenario $prev
}
