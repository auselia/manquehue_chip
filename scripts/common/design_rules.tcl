###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Design rules of the implementation, per scenario
###############################################################################

# Library limits only: no design-level max transition, max capacitance or max fanout. With a design-level transition
# limit the macro routed with 2005 DRCs, and with capacitance and fanout limits as well with 6432 (hold and fanout
# buffers in the channel between the SRAMs). A fixed 1.5 ns is far too strict at ss 125 C: 57732 nets go over it.
# A saved block keeps the rules of an earlier run, so design_rules removes them in every scenario.
# 04_cts.tcl and 05_route.tcl call design_rules again, so no step gets them back.
proc design_rules {} {
  set prev [current_scenario]
  foreach_in_collection s [all_scenarios] {
    current_scenario $s
    catch {remove_max_transition [current_design]}
    catch {remove_max_capacitance [current_design]}
    catch {remove_max_fanout [current_design]}
  }
  current_scenario $prev
}
