# Step 5: global and detail routing, and the route optimization
# Author: Viktor Schneider (IMS, Leibniz University Hannover). Adapted by Nicolás Villegas - Universidad de los Andes
# usage: make route      (fc_shell in work/)
# in:  block cts
# out: block route
source [file dirname [info script]]/lib/open_lib.tcl
open_block cts

source $CONFIG_DIR/sdc/design_rules.tcl
design_rules

route_auto

set_app_options -name route_opt.flow.enable_clock_power_recovery -value false

# The paths from the select register of the peripheral demux get more weight
group_path -name CRIT -weight 5 -critical_range 2.5 \
  -from [get_cells i_croc/i_obi_demux/select_q_reg[2]]

route_opt
route_detail -incremental true

set ACTIVE_STEP "05_route"
source [file dirname [info script]]/lib/reporting.tcl

save_block -as route
