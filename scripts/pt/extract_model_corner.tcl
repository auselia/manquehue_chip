###############################################################################
# scripts/pt/extract_model_corner.tcl -- PrimeTime timing model (ETM) for ONE corner
#
# Same netlist, SDC, SPEF and liberty setup as sta_corner.tcl, then extract_model writes an
# interface timing model of the block (setup/hold to the clocks, clock-to-output delays, pin
# caps) as a Liberty file, so a parent design can time through the hard macro.
#
# Required Tcl variables (set via -x before sourcing this file):
#   CORNER TOP VLOG SDC_FILE SPEF_FILE SC_DB IO_DB SRAM_DB OUT_DIR
###############################################################################

foreach v {CORNER TOP VLOG SDC_FILE SPEF_FILE SC_DB IO_DB SRAM_DB OUT_DIR} {
  if { ![info exists $v] } {
    puts "ERROR: required variable '$v' not set -- see header comment in [info script]."
    exit 1
  }
}
file mkdir $OUT_DIR

set link_library   "* $SC_DB $IO_DB $SRAM_DB"
set target_library "$SC_DB"

read_verilog $VLOG
current_design $TOP
link_design

read_sdc $SDC_FILE
read_parasitics -format SPEF $SPEF_FILE
update_timing -full

extract_model -output ${OUT_DIR}/${TOP}_${CORNER} -format {lib} -library_cell
puts "INFO: $CORNER timing model written to ${OUT_DIR}/${TOP}_${CORNER}.lib"
