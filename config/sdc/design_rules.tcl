# Design rules of every scenario: max transition and max capacitance at 0.9 x the library limit
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: source, then call design_rules (mode_func.tcl, 04_cts.tcl, 05_route.tcl)
# in:  the scenarios
# out: the design rules
# Max transition is 0.9 times the library limit of the corner (gf180mcu_fd_sc_mcu7t5v0: 7.0 ns ss, 4.0 ns tt, 2.6 ns
# ff), so Fusion Compiler fixes the nets that PrimeTime finds just over the library limit. A fixed 1.5 ns is far too
# strict at ss 125 C: 57732 nets go over it.
# The SRAM inputs get 1.4 ns, 0.9 times their limit.
# No design-level max capacitance or max fanout: with those the macro routed with 6432 DRCs.
# A saved block keeps the rules of an earlier run, so they are removed first.
# 04_cts.tcl and 05_route.tcl call design_rules again, so no step loses them.
proc design_rules {} {
  set prev [current_scenario]
  set sram_in [get_pins -quiet -of_objects [get_cells -quiet -hierarchical -filter "ref_name =~ gf180mcu_fd_ip_sram__*"] -filter "direction == in && is_clock_pin == false"]
  set pad_in [get_pins -quiet -of_objects [get_cells -quiet -hierarchical -filter "ref_name =~ gf180mcu_fd_io__*"] -filter "direction == in && name != PAD"]
  foreach_in_collection s [all_scenarios] {
    current_scenario $s
    set n [get_object_name $s]
    if {[string match *slow* $n]} { set tran 6.3 } elseif {[string match *fast* $n]} { set tran 2.34 } else { set tran 3.6 }
    set_max_transition $tran [current_design]
    # the SRAM inputs have their own, tighter limit in the library (1.55 ns), and PrimeTime found them up to 2.24 ns
    if {[sizeof_collection $sram_in] > 0} { set_max_transition 1.4 $sram_in }
    # the core-side inputs of the IO pads (A, OE, IE, ...) have a library limit of 1.0 ns, PrimeTime found them up to
    # 1.23 ns at slow on the chip (7 Nov 2026)
    if {[sizeof_collection $pad_in] > 0} { set_max_transition 0.9 $pad_in }
    catch {remove_max_capacitance [current_design]}
    catch {remove_max_fanout [current_design]}
  }
  current_scenario $prev
}
