###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: The AC3E pad ring table (padring.txt) and the pad positions, for the chip and the macro pins
###############################################################################
# Sourced by chip_floorplan.tcl, chip_pg_pads.tcl and 02_floorplan.tcl (macro pins facing their pads). Sets:
#   chip_pads      {number signal cell} per pad
#   chip_breakers  {instance pad} per breaker: a brk5 in the gap after the pad
#   chip_segments  pad number -> supply net of its ring segment

set chip_pads {}
set chip_breakers {}
set chip_segments [dict create]
set f [open [file dirname [info script]]/padring.txt]
foreach line [split [read $f] "\n"] {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} { continue }
    switch [lindex $line 0] {
        pad { lappend chip_pads [lrange $line 1 3] }
        brk { lappend chip_breakers [lrange $line 1 2] }
        seg {
            foreach r [lrange $line 2 end] {
                lassign [split $r -] lo hi
                if {$hi eq ""} { set hi $lo }
                for {set n $lo} {$n <= $hi} {incr n} { dict set chip_segments $n [lindex $line 1] }
            }
        }
    }
}
close $f

# Side and position of a pad: the lower-left coordinate along its side (y on west/east, x on south/north)
# W/E: 100 um pitch from 423.5, S/N: 104 um pitch from 410.5 (the AC3E padframe rule). Pads are 75 um wide.
proc pad_side_loc {n} {
    if {$n <= 43} { return [list left   [expr {4623.5 - 100.0 * ($n - 1)}]] }
    if {$n <= 54} { return [list bottom [expr {410.5 + 104.0 * ($n - 44)}]] }
    if {$n <= 97} { return [list right  [expr {423.5 + 100.0 * ($n - 55)}]] }
    return [list top [expr {1450.5 - 104.0 * ($n - 98)}]]
}
