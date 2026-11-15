# Write the PrimeTime inputs (SDC, SPEF) again from the saved finish block, into the run folder of outputs/latest
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: make pt_export      (fc_shell in work/)
# in:  work/design.dlib, block finish
# out: outputs/latest/: the files of common/export_signoff.tcl
#
# 06_finish.tcl writes these files already. outputs/latest is the run of this block only until another run is exported.
source [file dirname [info script]]/../common/open_lib.tcl
open_block finish

set RUN_DIR [file normalize [file join [file dirname [info script]] .. .. outputs latest]]
if { ![file isdirectory $RUN_DIR] } {
  puts "ERROR: outputs/latest does not resolve to a run directory ($RUN_DIR). Run make finish first."
  exit 1
}
source [file dirname [info script]]/../common/export_signoff.tcl
