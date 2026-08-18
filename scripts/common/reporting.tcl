###############################################################################
# Automated QoR and Validation Reporting Engine
###############################################################################
puts "================================================================"
puts "INFO: Executing Automated Reporting Engine for stage: $ACTIVE_STEP"
puts "================================================================"

# -----------------------------------------------------------------------------
# Report location
# -----------------------------------------------------------------------------
# 01_read_rtl through 05_route run before any timestamped run folder exists
# (outputs/<run>/ is only created by 06_finish.tcl at GDS/Verilog export), so
# their reports stay in the flat, stage-organized ../reports/ tree -- these
# describe the state of the LATEST build attempt and are expected to be
# overwritten on every rebuild, same convention as ../logs/.
#
# 06_finish and 07_pt_export both run AFTER that run folder exists and both
# already compute $RUN_DIR for their own GDS/Verilog/SDC/SPEF output before
# sourcing this file -- route their reports into outputs/<run>/reports/
# instead, so they live alongside that same run's drc_icv/, lvs_icv/,
# sta_pt/, power_pp/ and survive future rebuilds. Without this, comparing a
# past run's FC-native QoR/DRC/EM data against a new one meant re-running the
# whole flow just to regenerate what used to be there.
if {[info exists RUN_DIR] && [file isdirectory $RUN_DIR]} {
    set REPORT_DIR [file join $RUN_DIR reports ${ACTIVE_STEP}]
} else {
    set REPORT_DIR "../reports/${ACTIVE_STEP}"
}
file mkdir $REPORT_DIR

# -----------------------------------------------------------------------------
# Helper: some FC report commands (check_pg_connectivity in particular) dump
# an entire list -- thousands of instance names -- onto a single comma-
# separated line. A 400KB single line is unreadable in an editor and
# unusable with grep/less. Reflow any such line into one entry per line,
# indented under its original label, leaving normal-length lines untouched.
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
# Skipped for 03_synthesis: that stage already gets the same WNS/TNS (plus
# area) from report_qor -summary below, just sliced by corner instead of by
# path group -- generating both there is duplication, not two signals.
if {$ACTIVE_STEP != "01_read_rtl" && $ACTIVE_STEP != "03_synthesis"} {
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
        reflow_long_lines ${REPORT_DIR}/check_pg_connectivity.rpt

        redirect -file ${REPORT_DIR}/report_congestion.rpt { report_congestion }

        # check_pg_drc has no built-in summary/limit option (confirmed via
        # check_pg_drc -help): it writes one full record per violation, so a
        # power grid with a real, widespread problem produces a report too
        # large to read directly rather than a bug in how it's called. Derive
        # a by-rule violation count alongside the full detail so the scale of
        # any problem is visible without opening a multi-hundred-MB file.
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

        # check_pg_connectivity reports floating-cell counts up front in its
        # own header; surface that number to the console too since it's the
        # single most important line in the file and otherwise only visible
        # by opening it.
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
        # signoff_check_drc removed (was here, always failing: "Error: DRC
        # runset not found. (IND-018)"). It's FC's own in-design wrapper
        # around IC Validator and needs a foundry DRC runset configured
        # inside FC to work at all -- this flow never set one up. `make
        # drc-icv` already runs the real IC Validator with a properly
        # configured runset against this run's GDS and is the validated
        # signoff DRC path; this call was a redundant, broken duplicate of
        # it, not a second independent check.
        puts "INFO: DRC signoff is 'make drc-icv' (IC Validator, properly configured) -- not run from here."

        # report_signal_em needs a scenario with BOTH setup and signal_em
        # analysis enabled (it needs setup timing to bound the current
        # waveform window). This project's own MCMM scenario split
        # (common/mcmm.tcl) deliberately gives no single scenario both: fast
        # has signal_em true but setup false, typical/slow have setup true
        # but signal_em false (confirmed by trying both -- 'typical' fails
        # "not configured for hold", 'fast' fails "not configured for
        # setup"). That split is intentional QoR scoping for optimization/
        # timing signoff, not a bug, so don't touch it permanently. Instead,
        # borrow `fast` (the scenario already carrying every EM/power flag)
        # and flip just its -setup bit on for the duration of this one
        # report, then flip it back immediately -- reporting.tcl runs at the
        # very end of the stage, after save_block, so nothing downstream
        # optimizes against this scenario while it's borrowed.
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
