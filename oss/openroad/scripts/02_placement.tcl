# Stage 02: pins, global placement, repair, detailed placement.
# Structure after pulp-platform/croc openroad/scripts/02_placement.tcl (Apache-2.0).
set read_lefs 0
source scripts/startup.tcl
load_checkpoint 01_${proj_name}.floorplan
read_sdc src/constraints.sdc
setDefaultParasitics
set_dont_use $dont_use_cells

# clock nets are not buffered here, CTS does it
set clock_nets [get_nets -of_objects [get_pins -of_objects [get_cells -hier *] -filter "name == CLK"]]
set_dont_touch $clock_nets

utl::report "Repair tie fanout"
repair_tie_fanout $tieHiPin
repair_tie_fanout $tieLoPin
utl::report "Remove buffers, repair design"
remove_buffers
repair_design -verbose

# first pass without pins, then place the pins from the cell positions, then the real global placement
global_placement -skip_io -density 0.60
set_io_pin_constraint -region top:*    -pin_names {jtag_trst_ni testmode_i}
set_io_pin_constraint -region right:*  -pin_names {status_o jtag_tdo_o rst_ni gpio_i[1] gpio_o[1] gpio_out_en_o[1] uart_rx_i}
set_io_pin_constraint -region bottom:* -pin_names {jtag_tms_i jtag_tck_i qspi_clk_o qspi_sd_o[*] qspi_sd_i[*] qspi_sd_en_o[*] qspi_csn_o[*]}
set_io_pin_constraint -region left:*   -pin_names {ref_clk_i uart_tx_o clk_i jtag_tdi_i gpio_i[0] gpio_o[0] gpio_out_en_o[0]}
place_pins -hor_layers Metal3 -ver_layers Metal2 -min_distance 2 -min_distance_in_tracks
save_checkpoint 02-01_${proj_name}.pins

global_placement -density 0.60
estimate_parasitics -placement
report_metrics 02-02_gpl1
repair_design -verbose
repair_timing -setup -verbose

global_placement -density 0.60 -routability_driven -timing_driven
save_checkpoint 02-02_${proj_name}.gpl2
detailed_placement -max_displacement {300 150}
optimize_mirroring
estimate_parasitics -placement
report_metrics 02_placed
catch {check_placement -verbose}
save_checkpoint 02_${proj_name}.placed
