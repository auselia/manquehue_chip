###############################################################################
# Automated QoR and Validation Reporting Engine
###############################################################################
puts "================================================================"
puts "INFO: Executing Automated Reporting Engine for stage: $ACTIVE_STEP"
puts "================================================================"

# Establish target directory (Makefile already created it, but this ensures safety)
set REPORT_DIR "../reports/${ACTIVE_STEP}"
file mkdir $REPORT_DIR

# -----------------------------------------------------------------------------
# Global Must-Haves (Run for everything except RTL read-in)
# -----------------------------------------------------------------------------
if {$ACTIVE_STEP != "01_read_rtl"} {
    puts "INFO: Generating Global QoR Snapshot..."
    create_qor_snapshot -name ${ACTIVE_STEP}_snapshot
    redirect -file ${REPORT_DIR}/global_qor_snapshot.rpt { report_qor_snapshot -name ${ACTIVE_STEP}_snapshot }
}

# -----------------------------------------------------------------------------
# Stage-Specific Validation (Verified via FC Man Pages)
# -----------------------------------------------------------------------------
puts "INFO: Running targeted metrics for $ACTIVE_STEP..."

switch $ACTIVE_STEP {

    "01_read_rtl" {
        redirect -file ${REPORT_DIR}/check_design.rpt { check_design -checks netlist }
        redirect -file ${REPORT_DIR}/report_unbound.rpt { check_design -checks unbound }
        redirect -file ${REPORT_DIR}/check_timing.rpt { check_timing }
    }

    "02_floorplan" {
        check_pg_drc -no_gui -output ${REPORT_DIR}/check_pg_drc.rpt
        check_pg_connectivity -write_connectivity_file ${REPORT_DIR}/check_pg_connectivity.rpt
        
        redirect -file ${REPORT_DIR}/report_congestion.rpt { report_congestion }
    }

    "03_synthesis" {
        redirect -file ${REPORT_DIR}/report_qor_summary.rpt { report_qor -summary }
        redirect -file ${REPORT_DIR}/check_legality.rpt { check_legality }
        redirect -file ${REPORT_DIR}/report_constraints.rpt { report_constraints -all_violators }
        redirect -file ${REPORT_DIR}/report_timing_worst.rpt { report_timing -delay_type max -max_paths 50 }
        redirect -file ${REPORT_DIR}/check_pre_placement.rpt { check_design -checks pre_placement_stage }
    }

    "04_cts" {
        redirect -file ${REPORT_DIR}/check_pre_cts.rpt { check_design -checks pre_clock_tree_stage }

        redirect -file ${REPORT_DIR}/report_clock_qor.rpt { report_clock_qor }
        redirect -file ${REPORT_DIR}/check_clock_trees.rpt { check_clock_trees }
        redirect -file ${REPORT_DIR}/report_clock_timing.rpt { report_clock_timing -type skew }
    }

    "05_route" {
        redirect -file ${REPORT_DIR}/check_pre_route.rpt { check_design -checks pre_route_stage }

        redirect -file ${REPORT_DIR}/check_routes.rpt { check_routes }
        redirect -file ${REPORT_DIR}/report_wirelength.rpt { report_wirelength }
        redirect -file ${REPORT_DIR}/report_design_routing.rpt { report_design -routing }
    }

    "06_finish" {
        catch { redirect -file ${REPORT_DIR}/signoff_check_drc.rpt { signoff_check_drc } }
        catch { redirect -file ${REPORT_DIR}/report_signal_em.rpt { report_signal_em } }
    }

    "07_pt_export" {
        redirect -file ${REPORT_DIR}/report_parasitics.rpt { report_parasitics }
    }

    default {
        puts "WARNING: No stage-specific reporting mapped for $ACTIVE_STEP."
    }
}