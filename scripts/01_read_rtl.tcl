###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Read RTL and Elaborate
###############################################################################

# Load the common setup configuration
source [file dirname [info script]]/common/setup.tcl

###########################################################
# Library setup
###########################################################
if {[file exists $DESIGN_LIBRARY]} {
  file delete -force $DESIGN_LIBRARY
}

create_lib -technology $TECH_FILE -ref_libs $REFERENCE_LIBRARY $DESIGN_LIBRARY

###########################################################
# Read design
###########################################################
puts "RM-info: Analyzing RTL using native .flist parsing..."

# 1. Parse just the include directories and add them to FC's search_path
set fp [open "../flists/croc.flist" r]
while {[gets $fp line] >= 0} {
    set line [string trim $line]
    if {[string match "+incdir+*" $line]} {
        set inc [string map {"+incdir+" ""} $line]
        lappend search_path "../$inc"
    }
}
close $fp

# 2. Analyze the design (the -F flag still handles the file paths and +defines natively)
analyze -format sverilog -vcs "-F ../flists/croc.flist"
# Chip floorplan: the pad ring top around croc_soc. The pad cells link to gf180mcu_fd_io.
if {$CHIP_FLOORPLAN} {
    analyze -format sverilog ../rtl/chip/chip_top.sv
}

# Elaborate the top module (croc_chip) defined in setup.tcl
elaborate $TOP_MODULE
set_top_module

# Dedicated scan ports (the RTL has none). dft_scan.tcl declares them as SI/SE/SO and
# mode_func.tcl ties scan_se_i to 0, so they must exist before the constraints are read.
# The chip has scan pads instead (rtl/chip/chip_top.sv), connected when the chain is inserted at chip level.
if {!$CHIP_FLOORPLAN} {
create_port -direction in  scan_si_i
create_port -direction in  scan_se_i
create_port -direction out scan_so_o
}

###########################################################
# Technology setup
###########################################################
source [file dirname [info script]]/common/tech_setup.tcl

###########################################################
# MCMM configuration
###########################################################
source [file dirname [info script]]/common/mcmm.tcl

###########################################################
# Reporting constraints
###########################################################
create_utilization_configuration overall  -exclude io_cells
create_utilization_configuration stdcells -exclude { hard_macros macro_keepouts soft_macros io_cells hard_blockages soft_blockages }

set ACTIVE_STEP "01_read_rtl"
source [file dirname [info script]]/common/reporting.tcl

save_block -as read_rtl
print_message_info -ids * -summary