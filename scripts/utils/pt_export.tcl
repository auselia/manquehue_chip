# make pt_export: writes the PrimeTime inputs again (06_finish.tcl writes them already) from the saved finish block
# of work/design.dlib into the run folder outputs/latest points to. That is the run of the same build only while no
# other run was exported after it.
source [file dirname [info script]]/../common/open_lib.tcl
open_block finish

set RUN_DIR [file normalize [file join [file dirname [info script]] .. .. outputs latest]]
if { ![file isdirectory $RUN_DIR] } {
  puts "ERROR: outputs/latest does not resolve to a run directory ($RUN_DIR). Run make finish first."
  exit 1
}
source [file dirname [info script]]/../common/export_signoff.tcl
