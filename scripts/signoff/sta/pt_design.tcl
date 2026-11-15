# The PrimeTime setup that every check of a run shares: libraries, netlist and link
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: source this file in pt_shell, then call require and read_design
# in:  the variables TOP, VLOG, SC_DB, IO_DB and SRAM_DB (set with pt_shell -x)
# out: the linked design

# require <names>: stop when one of the variables is not set
proc require {names} {
  foreach name $names {
    if { ![uplevel #0 [list info exists $name]] } {
      puts "ERROR: variable '$name' is not set. The calling script sets it with pt_shell -x."
      exit 1
    }
  }
}

# read_design: link the cell, IO and SRAM libraries of the corner and read the netlist.
# The PDK has one SRAM view (tt, 25 C, 5.0 V), so every corner links the same SRAM .db.
proc read_design {} {
  global link_library target_library SC_DB IO_DB SRAM_DB VLOG TOP
  set link_library   "* $SC_DB $IO_DB $SRAM_DB"
  set target_library "$SC_DB"
  read_verilog $VLOG
  current_design $TOP
  link_design
}
