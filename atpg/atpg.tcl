# ATPG script for croc_soc (TestMAX ATPG, TetraMAX command set).
# DRAFT: written without the tool. The command names follow the TetraMAX documentation from memory and must be
# checked against `help` once the tool is installed. Run:  tmax -tcl atpg.tcl     (or tmax2 -tcl atpg.tcl)
set_messages -log atpg.log -replace

# 1. libraries and design
read_netlist primitives_atpg.v -format verilog -library
read_netlist cells_atpg.v      -format verilog -library
read_netlist sram_blackbox.v   -format verilog -library
read_netlist croc_soc_atpg.v   -format verilog
set_build -black_box gf180mcu_fd_ip_sram__sram512x8m8wm1
run_build_model croc_soc

# 2. rule check against the protocol written by Fusion Compiler (write_test_protocol)
run_drc croc_soc.stil

# 3. faults and pattern generation: stuck-at first, full scan, all faults
set_faults -model stuck
add_faults -all
set_atpg -abort_limit 100 -merge high
run_atpg -auto

# 4. results
report_summaries
report_faults -summary
write_faults faults_untested.txt -class {UD AU} -replace
write_patterns patterns_stuck.stil -format stil -replace
exit
