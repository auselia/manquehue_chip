# Stage 03: clock tree synthesis and post-CTS timing repair.
# Structure after pulp-platform/croc openroad/scripts/03_cts.tcl (Apache-2.0).
set read_lefs 0
source scripts/startup.tcl
load_checkpoint 02_${proj_name}.placed
read_sdc src/constraints.sdc
setDefaultParasitics
set_dont_use $dont_use_cells

set clock_nets [get_nets -of_objects [get_pins -of_objects [get_cells -hier *] -filter "name == CLK"]]
unset_dont_touch $clock_nets

repair_clock_inverters
clock_tree_synthesis -buf_list $ctsBuf -root_buf $ctsBufRoot -sink_clustering_enable -repair_clock_nets
detailed_placement
estimate_parasitics -placement
set_propagated_clock [all_clocks]
report_metrics 03_cts_unrepaired

repair_timing -setup -verbose
repair_timing -hold -hold_margin 0.1 -verbose
detailed_placement
estimate_parasitics -placement
report_metrics 03_cts
catch {check_placement -verbose}
save_checkpoint 03_${proj_name}.cts
