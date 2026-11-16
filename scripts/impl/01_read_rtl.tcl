# Step 1: read and elaborate the RTL, add the scan ports, set up the technology and the corners and modes
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: make read_rtl      (fc_shell in work/)
# in:  flists/croc.flist, config/
# out: work/design.dlib, block read_rtl
source [file dirname [info script]]/lib/setup.tcl

if {[file exists $DESIGN_LIBRARY]} {
  file delete -force $DESIGN_LIBRARY
}
create_lib -technology $TECH_FILE -ref_libs $REFERENCE_LIBRARY $DESIGN_LIBRARY

# The include folders of the flist go into the search path. analyze reads the files and the defines with -F.
puts "RM-info: Analyzing RTL using native .flist parsing..."
set fp [open "../flists/croc.flist" r]
while {[gets $fp line] >= 0} {
    set line [string trim $line]
    if {[string match "+incdir+*" $line]} {
        set inc [string map {"+incdir+" ""} $line]
        lappend search_path "../$inc"
    }
}
close $fp
analyze -format sverilog -vcs "-F ../flists/croc.flist"

elaborate $TOP_MODULE
set_top_module

# Dedicated scan ports (the RTL has none). dft_scan.tcl declares them as SI, SE and SO, and mode_func.tcl ties
# scan_se_i to 0, so they must exist before the constraints are read.
create_port -direction in  scan_si_i
create_port -direction in  scan_se_i
create_port -direction out scan_so_o

source [file dirname [info script]]/lib/tech_setup.tcl
source [file dirname [info script]]/lib/mcmm.tcl

create_utilization_configuration overall  -exclude io_cells
create_utilization_configuration stdcells -exclude { hard_macros macro_keepouts soft_macros io_cells hard_blockages soft_blockages }

set ACTIVE_STEP "01_read_rtl"
source [file dirname [info script]]/lib/reporting.tcl

save_block -as read_rtl
print_message_info -ids * -summary
