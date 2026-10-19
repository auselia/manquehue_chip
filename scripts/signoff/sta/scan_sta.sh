#!/bin/bash
# Scan-shift STA of a run: scan_se_i = 1, testmode_i = 1, both shift clocks timed against each other.
# Same netlist, libraries and parasitics as the signoff STA, SDC = <run>/croc_soc_scan.sdc (written by 06_finish, common/export_signoff.tcl).
# usage: scripts/signoff/sta/scan_sta.sh      (env: RUN)
set -e
. "$(dirname "${BASH_SOURCE[0]}")/../../utils/env.sh"
step_begin scan_sta
O=$STEP_DIR
cat > "$O/scan_sta.tcl" <<'TCL'
set link_library "* $SC_DB $IO_DB $SRAM_DB"
set target_library "$SC_DB"
read_verilog $VLOG
current_design croc_soc
link_design
read_sdc $SDC_FILE
read_parasitics -format SPEF $SPEF_FILE
update_timing -full
set si [get_pins -hierarchical */SI]
puts "RESULT corner=$CORNER SI_pins=[sizeof_collection $si]"
foreach {kind dt} {hold min setup max} {
  set all  [get_timing_paths -delay_type $dt -to $si -max_paths 100000 -nworst 1 -slack_lesser_than 1000]
  set viol [get_timing_paths -delay_type $dt -to $si -max_paths 100000 -nworst 1 -slack_lesser_than 0]
  set w [get_timing_paths -delay_type $dt -to $si -max_paths 1]
  puts "RESULT corner=$CORNER $kind: timed_endpoints=[sizeof_collection $all] violators=[sizeof_collection $viol] worst_slack=[get_attribute $w slack]"
}
redirect -file $REPORT_DIR/worst_hold.$CORNER.rpt { report_timing -delay_type min -to $si -max_paths 3 -input_pins -transition_time }
exit
TCL
run() { # corner sc io spef
  PATH=$PT_HOME/bin:$PATH pt_shell -x "
    set CORNER $1; set VLOG $RUN/croc_soc.v; set SDC_FILE $RUN/croc_soc_scan.sdc; set SPEF_FILE $RUN/croc_soc.$4.spef
    set SC_DB $PDK_DB/gf180mcu_fd_sc_mcu7t5v0__$2.db; set IO_DB $PDK_DB/gf180mcu_fd_io__$3.db; set SRAM_DB $SRAM_DB
    set REPORT_DIR $O
    source $O/scan_sta.tcl" > "$O/$1.log" 2>&1
}
run slow    ss_125C_4v50 ss_125C_4v50 typ_125 &
run typical tt_025C_5v00 tt_025C_5v00 typ_25  &
run fast    ff_n40C_5v50 ff_n40C_5v50 typ_-40 &
wait
grep -h "^RESULT" "$O"/slow.log "$O"/typical.log "$O"/fast.log | sed 's/^RESULT //' > "$O/results.txt"
cat "$O/results.txt"
HV=$(awk '/ hold:/{split($0,a,"violators="); split(a[2],b," "); s+=b[1]} END{print s+0}' "$O/results.txt")
SV=$(awk '/ setup:/{split($0,a,"violators="); split(a[2],b," "); s+=b[1]} END{print s+0}' "$O/results.txt")
N=$(grep -c "hold:" "$O/results.txt")
summary hold_violators "$HV"; summary setup_violators "$SV"; summary corners_timed "$N"
sed -n 's/.* hold: .*worst_slack=\(.*\)/\1/p' "$O/results.txt" | paste -sd' ' | sed 's/^/hold_worst_slack_ns(slow typical fast): /' >> "$SUMMARY"
if [ "$N" = 3 ] && [ "$HV" = 0 ] && [ "$SV" = 0 ]; then summary status PASS; else summary status FAIL; fi
