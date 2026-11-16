# Open the design library of work/ for a step, with the settings of setup.tcl
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: source at the start of steps 2 to 6
# in:  setup.tcl, work/design.dlib
# out: the open library
source [file dirname [info script]]/setup.tcl

if {[sizeof_collection [current_lib -quiet]] == 0} {
  open_lib $DESIGN_LIBRARY
} else {
  close_blocks -purge -force [get_blocks]
}