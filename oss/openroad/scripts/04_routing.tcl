# Stage 04: global route, repair, detailed route.
# Structure after pulp-platform/croc openroad/scripts/04_routing.tcl (Apache-2.0).
set read_lefs 0
source scripts/startup.tcl
load_checkpoint 03_${proj_name}.cts
read_sdc src/constraints.sdc
setDefaultParasitics
set_propagated_clock [all_clocks]
set_dont_use $dont_use_cells

set_routing_layers -signal Metal2-Metal5 -clock Metal2-Metal5
global_route -guide_file ${report_dir}/04_route.guide -congestion_report_file ${report_dir}/04_route_congestion.rpt -allow_congestion
estimate_parasitics -global_routing
report_metrics 04-01_grt

repair_design -verbose
repair_timing -setup -verbose -repair_tns 100
repair_timing -hold -hold_margin 0.1 -verbose -repair_tns 100
global_route -start_incremental -allow_congestion
detailed_placement
global_route -end_incremental -guide_file ${report_dir}/04_route.guide -congestion_report_file ${report_dir}/04_route_congestion.rpt -allow_congestion -verbose
estimate_parasitics -global_routing
save_checkpoint 04-01_${proj_name}.grt

repair_antennas -ratio_margin 30 -iterations 5
set_thread_count 8
detailed_route -output_drc ${report_dir}/04_route_drc.rpt -drc_report_iter_step 5 -save_guide_updates -clean_patches -verbose 1
save_checkpoint 04_${proj_name}.routed
estimate_parasitics -global_routing
report_metrics 04_routed
