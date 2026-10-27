# -----------------------------------------------------------------------------
# This file was created at the Institute of Microelectronic Systems,
# Leibniz University Hannover. It is provided "as is" without
# warranty of any kind, express or implied, including but not
# limited to correctness or fitness for a particular purpose.
#
# Author: Viktor Schneider
# -----------------------------------------------------------------------------

source [file dirname [info script]]/common/open_lib.tcl

open_block cts

route_auto

set_app_options -name route_opt.flow.enable_clock_power_recovery -value false

group_path -name CRIT -weight 5 -critical_range 2.5 \
  -from [get_cells ${CROC_HIER}i_croc/i_obi_demux/select_q_reg[2]]

route_opt

route_detail -incremental true
if {$CHIP_FLOORPLAN} {
    source [file dirname [info script]]/chip/chip_pg_pads.tcl
    chip_connect_pads
    chip_float_dcdc_pins
}

set ACTIVE_STEP "05_route"
source [file dirname [info script]]/common/reporting.tcl

save_block -as route

# Chip floorplan: routing check and the routed chip views
if {$CHIP_FLOORPLAN} {
    file mkdir ../outputs/chip_route
    check_routes
    redirect -file ../outputs/chip_route/check_lvs.rpt { check_lvs -checks {open short} -max_errors 2000 }
    source [file dirname [info script]]/chip/chip_export.tcl
    write_chip_views [file normalize ../outputs/chip_route] chip_route
}
