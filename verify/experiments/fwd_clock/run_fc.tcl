# Forwarded-clock experiment through Fusion Compiler: synthesis, placement, CTS, routing of fwd_clk_toy with the same
# libraries, corners and clock-tree options as the croc_soc flow. Run in verify/experiments/fwd_clock/work:
#   fc_shell -batch -f ../run_fc.tcl
set HERE [file normalize [file dirname [info script]]]
set REPO [file normalize $HERE/../../..]
source $REPO/scripts/common/setup.tcl         ;# TECH_FILE, REFERENCE_LIBRARY, layer maps, SYN_IGNORE_CELLS, CTS_CELLS
set TOP fwd_clk_toy
if {[file exists toy.dlib]} { file delete -force toy.dlib }
create_lib -technology $TECH_FILE -ref_libs $REFERENCE_LIBRARY toy.dlib
analyze -format verilog $HERE/fwd_clk_toy.v
elaborate $TOP
set_top_module $TOP
source $REPO/scripts/common/tech_setup.tcl

# corners and scenarios as in mcmm.tcl (functional mode only)
remove_scenarios -all; remove_corners -all; remove_modes -all
create_corner slow;    set_process_label ss; set_voltage 4.5; set_temperature 125
create_corner typical; set_process_label tt; set_voltage 5.0; set_temperature 25
create_corner fast;    set_process_label ff; set_voltage 5.5; set_temperature -40
create_mode func
create_scenario -name slow    -mode func -corner slow
create_scenario -name typical -mode func -corner typical
create_scenario -name fast    -mode func -corner fast
foreach_in_collection c [get_corners] { current_corner $c; set_parasitic_parameters -early_spec $LPE_SPEC -late_spec $LPE_SPEC }
set_scenario_status -all -hold false -dynamic_power false -leakage_power false -cell_em false -signal_em false {typical slow}
set_scenario_status -none -hold true -dynamic_power true -leakage_power true -cell_em true -signal_em true {fast}
current_mode func
foreach s [get_attribute [get_scenarios] -name name] { current_scenario $s; source $HERE/constraints.sdc }
current_scenario fast

initialize_floorplan -control_type die -side_length {120 120} -core_offset 10
create_net -power VDD
create_net -ground VSS
connect_pg_net -automatic
place_pins -self

set_app_options -name compile.flow.high_effort_timing -value 1
set_app_options -name opt.timing.effort               -value high
set_lib_cell_purpose -include none [get_lib_cells $SYN_IGNORE_CELLS]
compile_fusion
foreach s [get_attribute [get_scenarios] -name name] {
  current_scenario $s
  set_clock_uncertainty -setup 0.7  [get_clocks clk]
  set_clock_uncertainty -hold  0.35 [get_clocks clk]
}
set_lib_cell_purpose -include {hold optimization} [get_lib_cells $SYN_IGNORE_CELLS]
set_lib_cell_purpose -exclude cts [get_lib_cells]
set_lib_cell_purpose -include cts [get_lib_cells $CTS_CELLS]
set_app_options -name clock_opt.flow.enable_clock_power_recovery      -value false
set_app_options -name cts.optimize.enable_area_recovery_in_local_skew -value false
clock_opt
route_auto
route_opt
save_block -as toy_routed

file mkdir reports
write_verilog -include {pg_netlist} reports/toy_pg.v
write_verilog reports/toy.v
foreach s {slow typical fast} {
  # one report per scenario: sdo = SDO input to its capture flop, cs = CS output against SCLK, clk2port = clock to port
  redirect -file reports/sdo_setup.$s.rpt  { report_timing -scenarios $s -delay_type max -from [get_ports adc_sdo_i] -input_pins }
  redirect -file reports/sdo_hold.$s.rpt   { report_timing -scenarios $s -delay_type min -from [get_ports adc_sdo_i] -input_pins }
  redirect -file reports/cs_setup.$s.rpt   { report_timing -scenarios $s -delay_type max -to [get_ports adc_csn_o] -input_pins }
  redirect -file reports/cs_hold.$s.rpt    { report_timing -scenarios $s -delay_type min -to [get_ports adc_csn_o] -input_pins }
  redirect -file reports/all_setup.$s.rpt  { report_timing -scenarios $s -delay_type max -max_paths 30 -nworst 1 -input_pins -sort_by group }
  redirect -file reports/all_hold.$s.rpt   { report_timing -scenarios $s -delay_type min -max_paths 30 -nworst 1 -input_pins -sort_by group }
  redirect -file reports/latency.$s.rpt    { report_clock_timing -scenarios $s -type latency -nworst 4 }
}
redirect -file reports/clock_gating_check.rpt { report_clock_gating_check }
redirect -file reports/check_timing.rpt       { check_timing -verbose }
redirect -file reports/qor.rpt                { report_qor }
redirect -file reports/clock_qor.rpt          { report_clock_qor -type summary }
exit
