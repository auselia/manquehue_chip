###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Chip views (CHIP_FLOORPLAN=1): GDS with every layout merged, DEF, utilization
###############################################################################

# Layouts merged into the chip GDS. The IO cells and the SRAM come from the official PDK (IO_GDS_DIR, SRAM_GDS_DIR),
# the standard cells from the Synopsys copy in ${PDK_DIR}/gds (identical to the PDK ones).
proc chip_gds_files {} {
    global PDK_DIR SRAM_GDS_DIR IO_GDS_DIR WS_IP_DIR CHIP_WS_IPS CHIP_DCDC_MACROS
    set gds_files [lsearch -all -inline -not -regexp [glob ${PDK_DIR}/gds/*.gds] {gf180mcu_fd_ip_sram__|gf180mcu_fd_io__}]
    lappend gds_files {*}[glob ${SRAM_GDS_DIR}/gf180mcu_fd_ip_sram__*.gds]
    lappend gds_files $IO_GDS_DIR/gf180mcu_fd_io.gds
    foreach ip $CHIP_WS_IPS { lappend gds_files $WS_IP_DIR/$ip/gds/$ip.gds }
    # The DC-DC layouts moved to the origin (dcdc_abstract.py), so they land where they were drawn
    foreach m $CHIP_DCDC_MACROS { lappend gds_files [file normalize chip_abstracts/$m.gds] }
    return $gds_files
}

proc write_chip_views {dir name} {
    global TOP_MODULE ICC2GDS_LAYERMAP
    file mkdir $dir
    write_gds -units 1000 -merge_files [chip_gds_files] -merge_gds_top_cell $TOP_MODULE \
        -layer_map $ICC2GDS_LAYERMAP -long_names $dir/$name.gds
    write_def -compress gzip $dir/$name.def
    report_utilization > $dir/utilization.rpt
    puts "INFO: chip views written to $dir"
}
