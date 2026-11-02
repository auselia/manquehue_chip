###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: No clock gating check on the ADC SCLK mux (adc_rdr.sv, i_sclk_mux)
###############################################################################

# The SCLK mux selects the gated clock (gclk) or SCLK_HALF with fhalf_q. fhalf_q changes only at the start of a
# frame, while gate_en_q is 0 and gclk is still, so the switch cannot glitch. The tools put a clock gating check on
# the gates of that mux as if gclk ran: it is not a real check, and hold fixing on it only adds delay cells.
# The mux is in gates only after compile, so 04_cts.tcl calls this again before clock_opt. Before compile it finds
# no leaf cell and does nothing.
proc sclk_mux_no_gating_check {} {
  set nets [get_nets -quiet -hierarchical *adc_rdr*gclk]
  if {[sizeof_collection $nets] == 0} { return }
  # every combinational cell after gclk: the inverter, the mux gates, the bus mux and the buffers to the pad. The
  # inverter can come before the gates that the check is on.
  set cells [filter_collection [all_fanout -from $nets -only_cells -flat] "is_combinational == true"]
  if {[sizeof_collection $cells] == 0} { return }
  set_disable_clock_gating_check $cells
  puts "INFO: no clock gating check on [sizeof_collection $cells] cell(s) of the ADC SCLK mux"
}
sclk_mux_no_gating_check
