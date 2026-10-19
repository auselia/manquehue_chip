###############################################################################
# Croc SoC Sign-off
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: RedHawk-SC voltage drop of the finish block (called by make rail)
###############################################################################

# Opens the finish block, takes the top-level VDD and VSS pins as ideal supplies (create_taps -top_pg) and solves the
# voltage drop of the routed PDN. It saves nothing: the taps and the result exist only in this session.
#
# Variables (set with -x before this file is sourced, see make rail):
#   TOP                top module (croc_soc)
#   REPORT_DIR         folder for the rail database and the reports
#   RAIL_PRODUCT       redhawk_sc (RedHawk-SC is in the IC Validator install)
#   RAIL_REDHAWK_PATH  folder of the redhawk_sc executable
#   RAIL_TECH_FILE     ITF with the R and C of every layer: tech/gf180mcu.itf, made from the PDK nxtgrd with the LEF
#                      layer names (see its header). This RedHawk-SC takes itf, ircx or nrc, not atf.
#   RAIL_VOLTAGE_DROP  static | dynamic | dynamic_vectorless | dynamic_vcd
###############################################################################

source [file dirname [info script]]/../../common/open_lib.tcl
open_block finish

# A new session that opens finish has no parasitic model (TLUP-032 on open). The dynamic analysis needs one ("No
# valid parasitic for all corners"). The same call as tech_setup.tcl, safe because it is the first in this session.
read_parasitic_tech -layermap ${LPE_LAYERMAP} -tlup ${LPE_NXTGRD} -name ${LPE_SPEC}

set_app_options -name rail.product      -value $RAIL_PRODUCT
set_app_options -name rail.redhawk_path -value $RAIL_REDHAWK_PATH
set_app_options -name rail.tech_file    -value $RAIL_TECH_FILE
set_app_options -name rail.database     -value $REPORT_DIR/RAIL_DATABASE

# analyze_rail starts its worker with rsh by default, which this machine does not have (GRD.013, it waits forever).
# local_submit.sh starts the one worker locally.
set_host_options -target RedHawk -num_processes 1 \
    -submit_command [file dirname [info script]]/local_submit.sh

# Only the top-level VDD and VSS pins of the LEF are the supply: the test shows if those pins are enough.
puts "=== creating taps on croc_soc's top-level VDD/VSS pins ==="
create_taps -supply_net VDD -top_pg
create_taps -supply_net VSS -top_pg

# Power nets are 1.0 V unless set (RAIL-601), VSS is 0 V. set_voltage needs get_supply_nets, not get_nets (SEL-002).
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
