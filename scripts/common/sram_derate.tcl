###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Timing derate of the SRAM macros at the slow and fast corners
###############################################################################

# The PDK has only a tt view of the SRAM (25 C, 5.0 V), so every corner links it. The standard cells of the same PDK
# are 1.79 times slower at ss 125 C 4.5 V (median over 2060 arcs, at most 1.92) and 0.64 times as fast at ff -40 C
# 5.5 V (at least 0.60). The SRAM is taken to scale the same way:
#   slow  delays and timing checks late x 1.9 (setup)
#   fast  delays early x 0.6 (the SRAM outputs come earlier: the worst case for hold). The hold checks keep their tt
#         values, which is the pessimistic side.
# usage: sram_derate <corner>   (slow | typical | fast), in PrimeTime and in Fusion Compiler (current scenario)
proc sram_derate {corner} {
  set srams [get_cells -quiet -hierarchical -filter "ref_name =~ gf180mcu_fd_ip_sram__*"]
  if {[sizeof_collection $srams] == 0} { return }
  switch -- $corner {
    slow {
      set_timing_derate -late 1.9 -cell_delay $srams
      set_timing_derate -late 1.9 -cell_check $srams
    }
    fast {
      set_timing_derate -early 0.6 -cell_delay $srams
    }
  }
  puts "INFO: SRAM derate for corner $corner on [sizeof_collection $srams] SRAM(s)"
}
