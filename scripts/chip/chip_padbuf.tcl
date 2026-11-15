###############################################################################
# Croc SoC Chip
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: One buffer after each input pad that drives more than one cell
###############################################################################

# The Y pin of the gf180mcu_fd_io input pads has max_fanout 1, and compile_fusion does not fix the fanout of an IO
# cell. jtag_trst_ni drove 25 cells, rst_ni and jtag_tck_i 5. A buffer after the pad takes all the loads. The clock
# pads (clk_i, jtag_tck_i) get a clock buffer: CTS did not buffer them (chip STA of 7 Nov 2026: jtag_tck_i/Y drove
# 26 loads, clk_i/Y 2), and the clock tree starts after it.
proc chip_buffer_input_pads {{lib_cell gf180mcu_fd_sc_mcu7t5v0__buf_4} {clk_cell gf180mcu_fd_sc_mcu7t5v0__clkbuf_8}} {
  set n 0
  foreach_in_collection y [get_pins -quiet -of_objects [get_cells -quiet pad_*] -filter "lib_pin_name == Y"] {
    set cell [get_object_name [get_cells -of_objects $y]]
    set net [get_nets -quiet -of_objects $y]
    if {[sizeof_collection $net] == 0} { continue }
    set loads [get_pins -quiet -leaf -of_objects $net -filter "direction == in"]
    set clk [expr {$cell in {pad_clk_i pad_jtag_tck_i}}]
    if {[sizeof_collection $loads] <= 1 && !$clk} { continue }
    set new [add_buffer -lib_cell [expr {$clk ? $clk_cell : $lib_cell}] $loads -new_cell_names padbuf_${cell}]
    # later optimization removes a buffer it does not need for timing: this one is for the pad fanout
    set_dont_touch $new true
    incr n
  }
  puts "INFO: buffer after $n input pad(s)"
}
