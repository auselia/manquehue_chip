# PrimeTime timing model (ETM) of croc_soc at one corner, as a Liberty file for the chip-level STA
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: pt_shell -x "set CORNER ...; ...; source extract_model_corner.tcl"      (extract_models.sh does it)
# in:  CORNER, TOP, VLOG, SDC_FILE (the sign-off SDC), SPEF_FILE, SC_DB, IO_DB, SRAM_DB, OUT_DIR
# out: OUT_DIR/<TOP>_<corner>.lib: setup and hold to the clocks, clock-to-output delays, pin capacitances
source [file dirname [info script]]/pt_design.tcl
require {CORNER TOP VLOG SDC_FILE SPEF_FILE SC_DB IO_DB SRAM_DB OUT_DIR}
file mkdir $OUT_DIR

read_design
read_sdc $SDC_FILE
read_parasitics -format SPEF $SPEF_FILE
update_timing -full

extract_model -output ${OUT_DIR}/${TOP}_${CORNER} -format {lib} -library_cell
puts "INFO: $CORNER timing model written to ${OUT_DIR}/${TOP}_${CORNER}.lib"
