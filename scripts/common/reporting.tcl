###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: QoR and check reports of every step (sourced with ACTIVE_STEP set)
###############################################################################
puts "================================================================"
puts "INFO: Executing Automated Reporting Engine for stage: $ACTIVE_STEP"
puts "================================================================"

# -----------------------------------------------------------------------------
# Report location
# -----------------------------------------------------------------------------
# 01_read_rtl through 05_route run before the run folder outputs/<run>/ exists (06_finish.tcl creates it when it
# exports the GDS and the netlist). Their reports go to a staging directory, work/reports/<step>/, and 06_finish.tcl
# copies them into outputs/<run>/reports/<step>/. So every run folder carries the reports of the build it was exported
# from, next to its drc/, lvs/, sta_pt/ and power_pp/. The staging directory belongs to work/ (make clean removes it)
# and always holds the latest build attempt.
#
# 06_finish and 07_pt_export run after the run folder exists, they set $RUN_DIR before sourcing this file and write
# into outputs/<run>/reports/<step>/ directly.
if {[info exists RUN_DIR] && [file isdirectory $RUN_DIR]} {
    set REPORT_DIR [file join $RUN_DIR reports ${ACTIVE_STEP}]
} else {
    set REPORT_DIR "reports/${ACTIVE_STEP}"   ;# relative to work/, the working directory of every step
}
file mkdir $REPORT_DIR

# -----------------------------------------------------------------------------
# Helper: some reports (check_pg_connectivity) put thousands of names on one comma-separated line. Write such a
# line as one entry per line under its label. Normal lines stay as they are.
# -----------------------------------------------------------------------------
proc reflow_long_lines {filename {threshold 300}} {
    if {[catch {open $filename r} fh]} { return }
    set out {}
    while {[gets $fh line] >= 0} {
        if {[string length $line] > $threshold && [string first "," $line] >= 0} {
            regexp {^(\s*)(.*)$} $line -> indent rest
            foreach item [split $rest ","] {
                lappend out "${indent}[string trim $item]"
            }
        } else {
            lappend out $line
        }
    }
    close $fh
    set fh [open $filename w]
    puts $fh [join $out "\n"]
    close $fh
}

# -----------------------------------------------------------------------------
# Global Must-Haves (Run for everything except RTL read-in)
# -----------------------------------------------------------------------------
# Not for 03_synthesis: report_qor -summary below gives the same WNS and TNS there, per corner.
if {$ACTIVE_STEP != "01_read_rtl" && $ACTIVE_STEP != "03_synthesis"} {
    puts "INFO: Generating Global QoR Snapshot..."
    create_qor_snapshot -name ${ACTIVE_STEP}_snapshot
    redirect -file ${REPORT_DIR}/global_qor_snapshot.rpt { report_qor_snapshot -name ${ACTIVE_STEP}_snapshot }
}

# -----------------------------------------------------------------------------
# Stage-specific checks
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
        reflow_long_lines ${REPORT_DIR}/check_pg_connectivity.rpt

        redirect -file ${REPORT_DIR}/report_congestion.rpt { report_congestion }

        # check_pg_drc writes one record per violation and has no summary option. Also write the count per rule,
        # so that the size of a problem shows without opening a very large file.
        if {![catch {open ${REPORT_DIR}/check_pg_drc.rpt r} fh]} {
            array set rule_counts {}
            set total 0
            while {[gets $fh line] >= 0} {
                if {[regexp {Violated rule:\s*(\S+)} $line -> rule]} {
                    incr rule_counts($rule)
                    incr total
                }
            }
            close $fh
            set sfh [open ${REPORT_DIR}/check_pg_drc_summary.rpt w]
            puts $sfh "check_pg_drc summary -- $total total violation(s)"
            puts $sfh "(full per-violation detail in check_pg_drc.rpt)"
            puts $sfh ""
            foreach rule [lsort [array names rule_counts]] {
                puts $sfh [format "  %-40s %d" $rule $rule_counts($rule)]
            }
            close $sfh
            if {$total > 0} {
                puts "WARNING: check_pg_drc found $total violation(s) -- see check_pg_drc_summary.rpt"
            } else {
                puts "INFO: check_pg_drc found 0 violations."
            }
        }

        # Show the floating-cell count of the report header on the console too.
        if {![catch {open ${REPORT_DIR}/check_pg_connectivity.rpt r} fh]} {
            while {[gets $fh line] >= 0} {
                if {[regexp {Number of floating std cells:\s*([0-9]+)} $line -> n] && $n > 0} {
                    puts "WARNING: check_pg_connectivity: $n floating std cell(s) -- see check_pg_connectivity.rpt"
                }
            }
            close $fh
        }
    }

    "03_synthesis" {
        redirect -file ${REPORT_DIR}/report_qor_summary.rpt { report_qor -summary }
        redirect -file ${REPORT_DIR}/check_legality.rpt { check_legality }
        redirect -file ${REPORT_DIR}/report_constraints.rpt { report_constraints -all_violators }
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
        # No signoff_check_drc: it needs a DRC runset inside FC (IND-018). make drc and make drc-icv check the GDS.
        puts "INFO: DRC signoff is 'make drc-icv' (IC Validator, properly configured) -- not run from here."

        # report_signal_em needs a scenario with setup and signal_em analysis. In mcmm.tcl no scenario has both:
        # fast has signal_em, slow and typical have setup. Turn setup on in fast for this report only, then off
        # again at once, so the scenario split of mcmm.tcl does not change.
        if {[catch {current_scenario} _orig_scenario]} { set _orig_scenario "" }
        current_scenario fast
        set_scenario_status -setup true {fast}
        catch { redirect -file ${REPORT_DIR}/report_signal_em.rpt { report_signal_em } }
        set_scenario_status -setup false {fast}
        if {$_orig_scenario ne ""} { catch { current_scenario $_orig_scenario } }
    }

    "07_pt_export" {
        redirect -file ${REPORT_DIR}/report_parasitics.rpt { report_parasitics }
    }

    default {
        puts "WARNING: No stage-specific reporting mapped for $ACTIVE_STEP."
    }
}
