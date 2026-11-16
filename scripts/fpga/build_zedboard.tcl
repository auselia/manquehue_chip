# Vivado batch build of croc for the ZedBoard (non-project mode): synthesis, place, route, bitstream
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: make fpga, or vivado -mode batch -source scripts/fpga/build_zedboard.tcl in the repo root
# in:  flists/croc_fpga.flist, scripts/fpga/zedboard.xdc
# out: work_fpga/: croc_zedboard_top.bit, checkpoints, timing, utilization and DRC reports

set repo_dir  [file normalize [file join [file dirname [info script]] .. ..]]
set flist     [file join $repo_dir "flists" "croc_fpga.flist"]
set xdc       [file join $repo_dir "scripts" "fpga" "zedboard.xdc"]
set part      "xc7z020clg484-1"
set top       "croc_zedboard_top"
set work_dir  [file join $repo_dir "work_fpga"]

file mkdir $work_dir

# The sources of the flist: its paths are relative to its folder (flists/)
set incdirs {}
set defines {}
set src_files {}

set fp [open $flist r]
while {[gets $fp line] >= 0} {
  set line [string trim $line]
  if {$line eq ""} { continue }
  if {[string match "#*" $line]}  { continue }
  if {[string match "//*" $line]} { continue }

  if {[string match "+incdir+*" $line]} {
    lappend incdirs [file normalize [file join [file dirname $flist] [string range $line 8 end]]]
  } elseif {[string match "+define+*" $line]} {
    lappend defines [string range $line 8 end]
  } else {
    lappend src_files [file normalize [file join [file dirname $flist] $line]]
  }
}
close $fp

puts "\[build_zedboard\] [llength $src_files] source files, [llength $incdirs] incdirs, [llength $defines] defines"

# Sources and constraints
read_verilog -sv $src_files
read_xdc $xdc

set_property include_dirs  $incdirs [current_fileset]
set_property verilog_define $defines [current_fileset]

# Synthesis, place, route, bitstream
synth_design -top $top -part $part
write_checkpoint -force [file join $work_dir "post_synth.dcp"]
report_timing_summary -file [file join $work_dir "post_synth_timing.rpt"]
report_utilization    -file [file join $work_dir "post_synth_utilization.rpt"]

opt_design
place_design
report_utilization -file [file join $work_dir "post_place_utilization.rpt"]

route_design
write_checkpoint -force [file join $work_dir "post_route.dcp"]
report_timing_summary -file [file join $work_dir "post_route_timing.rpt"]
report_drc            -file [file join $work_dir "post_route_drc.rpt"]

write_bitstream -force [file join $work_dir "$top.bit"]

puts "\[build_zedboard\] Done. Bitstream: [file join $work_dir "$top.bit"]"
