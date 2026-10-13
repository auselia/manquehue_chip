# Common setup of the OpenROAD stages (structure after pulp-platform/croc openroad/scripts/startup.tcl, Apache-2.0).
set proj_name  [expr {[info exists ::env(PROJ_NAME)]  ? $::env(PROJ_NAME)  : "croc_soc"}]
set top_design [expr {[info exists ::env(TOP_DESIGN)] ? $::env(TOP_DESIGN) : "croc_soc"}]
set netlist    [expr {[info exists ::env(NETLIST)]    ? $::env(NETLIST)    : "../yosys/out/${proj_name}_yosys.v"}]
set report_dir reports
set save_dir   save
set out_dir    out
file mkdir $report_dir
file mkdir $save_dir
file mkdir $out_dir

# target die size: width is the slot-limited macro width of the FC flow; height from total cell area / utilization
set die_w 1019.92
set target_util 0.70
set core_margin 25.0

utl::report "Project $proj_name, top $top_design, netlist $netlist"

source scripts/init_tech_gf180.tcl

proc save_checkpoint {name} {
    global save_dir
    write_db ${save_dir}/${name}.odb
    write_sdc -no_timestamp ${save_dir}/${name}.sdc
    utl::report "checkpoint ${name}"
}
proc load_checkpoint {name} {
    global save_dir
    read_db ${save_dir}/${name}.odb
    # the technology, libraries and SDC are not stored in the db: init_tech_gf180.tcl read the libraries
    # and the SDC is read again by the caller
}

# worst slack, TNS, area and the five worst endpoints per check type and corner
proc report_metrics {tag} {
    global report_dir
    utl::report "== metrics $tag"
    report_design_area
    report_wns
    report_tns
    report_worst_slack -max
    report_worst_slack -min
    foreach corner {slow typical fast} {
        utl::report "-- corner $corner"
        report_checks -corner $corner -path_delay max -group_path_count 3 -format end
        report_checks -corner $corner -path_delay min -group_path_count 3 -format end
    }
    report_check_types -max_slew -max_capacitance -max_fanout -violators > ${report_dir}/${tag}_drv.rpt
}
