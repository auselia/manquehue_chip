###############################################################################
# scripts/rail/analyze_rail.tcl -- RedHawk-SC Fusion static/dynamic voltage
# drop (IR drop) signoff, run in-design against the FC 'finish' block.
#
# Unlike the numbered 0X_*.tcl steps, this is a read-only signoff pass (like
# scripts/pt/sta_corner.tcl): it opens the already-built 'finish' block,
# treats croc_soc's top-level VDD/VSS pins as ideal external voltage sources
# (create_taps -top_pg), and asks RedHawk-SC to solve for voltage drop across
# the block's real, routed PDN. Nothing about the block itself is modified or
# saved back -- the taps and the rail result exist only in this fc_shell
# session; results are written to REPORT_DIR instead.
#
# Expects the following variables set (via `fc_shell -x "set VAR val; ..."`)
# before this script is sourced -- see the 'make rail' Makefile target:
#   TOP               -- design.dlib top-level module name (croc_soc)
#   REPORT_DIR        -- directory to write rail_result / reports into
#   RAIL_PRODUCT      -- redhawk_sc (this env has no separate 'redhawk' binary;
#                         RedHawk-SC ships bundled inside the IC Validator
#                         install -- see RAIL_REDHAWK_PATH)
#   RAIL_REDHAWK_PATH -- dir containing the redhawk_sc executable
#   RAIL_TECH_FILE    -- ITF (Interconnect Technology Format), NOT the "ATF"
#                         FC's own docs call it -- this RedHawk-SC build only
#                         accepts itf/ircx/nrc (confirmed empirically). The
#                         real one, scripts/rail/tech/gf180mcu.itf, was
#                         recovered directly from GlobalFoundries' own
#                         officially-released field-solver binary
#                         (~/pdk_synopsys/pex/*.nxtgrd) via StarRC's
#                         grdgenxo -nxtgrd2itf converter -- not hand-authored
#                         -- then had its CONDUCTOR/VIA layer names remapped
#                         from TLUplus-internal names (TM/M4../V1..) to
#                         GF180MCU's real LEF/DEF names (Metal5/Metal4../
#                         Via1..) per ~/pdk_synopsys/tech/tluplus/mdb2itf.map
#                         -- required, or nearly every via/pin in the design
#                         fails to resolve (confirmed 2026-08-22: 141k+ via
#                         connectivity errors before the rename, ~0 after).
#                         See that file's own header for full provenance.
#   RAIL_VOLTAGE_DROP -- static | dynamic | dynamic_vectorless | dynamic_vcd
###############################################################################

source [file dirname [info script]]/../common/open_lib.tcl
open_block finish

# A fresh, standalone fc_shell session opening "finish" cold (unlike the
# sequential 01->07 flow, where each stage inherits parasitics attached by
# 01_read_rtl.tcl) does not have a working parasitic model attached, even
# though the block "remembers" it was once attached (TLUP-032 "Preserved
# ... doesn't belong to any TLUPlus model" warning on open). Static analysis
# doesn't need this (pure DC resistance network), but dynamic does
# (write_parasitics/.spef failed with "No valid parasitic for all corners"
# without this, confirmed 2026-08-22). This re-runs the same
# read_parasitic_tech call scripts/common/tech_setup.tcl uses -- safe here
# specifically because this is the FIRST attach in this session, unlike the
# earlier, unrelated finding that re-sourcing tech_setup.tcl mid-chain in
# 03_synthesis.tcl orphans an already-attached model.
read_parasitic_tech -layermap ${LPE_LAYERMAP} -tlup ${LPE_NXTGRD} -name ${LPE_SPEC}

set_app_options -name rail.product      -value $RAIL_PRODUCT
set_app_options -name rail.redhawk_path -value $RAIL_REDHAWK_PATH
set_app_options -name rail.tech_file    -value $RAIL_TECH_FILE
set_app_options -name rail.database     -value $REPORT_DIR/RAIL_DATABASE

# analyze_rail is a distributed-processing command (FC UG ch.1, "Configuring
# Distributed Processing"): with no set_host_options config it defaults to
# submitting its worker job via rsh, even for a single-machine run. This box
# has neither rsh nor passwordless ssh-to-self, so that default hangs
# forever (GRD.013 "Still waiting for first worker to launch", confirmed
# 2026-08-22 after ~40 min of retries). Route the submission through a
# trivial local exec wrapper instead -- 1 process, no real queue.
set_host_options -target RedHawk -num_processes 1 \
    -submit_command [file dirname [info script]]/local_submit.sh

# Treats exactly and only the top-level VDD/VSS pins already on croc_soc's
# LEF (the 6+6 discrete Metal5 pins) as the ideal external supply -- this is
# the direct test of "will just those 6 pins work".
puts "=== creating taps on croc_soc's top-level VDD/VSS pins ==="
create_taps -supply_net VDD -top_pg
create_taps -supply_net VSS -top_pg

# RAIL-601 (confirmed 2026-08-22): power nets default to 1.0V unless given
# an explicit voltage -- wrong for this 5V design (VSS correctly defaults
# to 0.0V on its own, no action needed there). set_voltage -object_list
# needs a get_supply_nets collection specifically, not get_nets (get_nets
# failed with SEL-002 "inappropriate type (net)"). croc_soc rail is the
# 5.0V MCMM corner (scripts/common/mcmm.tcl).
set_voltage 5.0 -object_list [get_supply_nets VDD]

puts "=== running $RAIL_VOLTAGE_DROP voltage drop analysis ==="
analyze_rail -voltage_drop $RAIL_VOLTAGE_DROP -nets {VDD VSS}

puts "=== writing voltage drop report ==="
report_rail_result -type voltage_drop_or_rise -supply_nets [get_nets {VDD VSS}] \
    $REPORT_DIR/voltage_drop.$RAIL_VOLTAGE_DROP.rpt

puts "=== writing per-pin power report (for total current estimate) ==="
report_rail_result -type pg_pin_power -supply_nets [get_nets VDD] -limit 0 \
    $REPORT_DIR/pg_pin_power.VDD.$RAIL_VOLTAGE_DROP.rpt
report_rail_result -type pg_pin_power -supply_nets [get_nets VSS] -limit 0 \
    $REPORT_DIR/pg_pin_power.VSS.$RAIL_VOLTAGE_DROP.rpt
