# TestMAX ATPG of croc_soc: rule check against the protocol, stuck-at patterns, coverage
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: tmax -shell -tcl atpg.tcl      (dft.sh runs it in <run>/checks/dft/)
# in:  primitives_atpg.v, cells_atpg.v, sram_blackbox.v, croc_soc_atpg.v, croc_soc_scan.stil (fix_inputs.py)
# out: atpg.log, patterns_stuck.stil, faults_untested.txt, scan_cells.rpt
set_messages -log atpg.log -replace

read_netlist primitives_atpg.v -format verilog -library
read_netlist cells_atpg.v      -format verilog -library
read_netlist sram_blackbox.v   -format verilog -library
read_netlist croc_soc_atpg.v   -format verilog
set_build -black_box gf180mcu_fd_ip_sram__sram512x8m8wm1
run_build_model croc_soc

run_drc croc_soc_scan.stil

# stuck-at, full scan, all faults
set_faults -model stuck
add_faults -all
set_atpg -abort_limit 100 -merge high
run_atpg -auto

report_summaries
report_faults -summary
write_faults faults_untested.txt -class {UD AU} -replace
write_patterns patterns_stuck.stil -format stil -replace
# chain order and cell names for the parallel-load test bench (scan_cells_vh.py)
report_scan_cells -all > scan_cells.rpt
exit
