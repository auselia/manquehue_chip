#!/bin/bash
# STA of the scan shift of a run (scan_se_i = 1, testmode_i = 1) at every corner, in parallel
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/sta/scan_sta.sh      (env: RUN)
# in:  <run>/croc_soc.v, <run>/croc_soc_scan.sdc, <run>/croc_soc.<spef>.spef of every corner
# out: <run>/checks/scan_sta/: summary.txt, results.txt, the log of every corner
set -e
. "$(dirname "${BASH_SOURCE[0]}")/settings.sh"
step_begin scan_sta
sram_db SCAN-STA

# run_corner <corner>: one pt_shell in its own folder (pt_shell writes its command log into the working folder)
run_corner() {
  local corner=$1
  corner_inputs "$corner" "$RUN"
  mkdir -p "$STEP_DIR/pt_$corner"
  cd "$STEP_DIR/pt_$corner"
  PATH=$PT_HOME/bin:$PATH pt_shell -x "
    set CORNER $corner; set TOP $TOP; set VLOG $RUN/$TOP.v; set SDC_FILE $RUN/${TOP}_scan.sdc; set SPEF_FILE $SPEF
    set SC_DB $SC_DB; set IO_DB $IO_DB; set SRAM_DB $SRAM_DB; set REPORT_DIR $STEP_DIR
    source $REPO/scripts/signoff/sta/scan_sta_corner.tcl" > "$STEP_DIR/$corner.log" 2>&1
}

logs=()
for corner in $CORNERS; do
  run_corner "$corner" &
  logs+=("$STEP_DIR/$corner.log")
done
wait

results=$STEP_DIR/results.txt
grep -h "^RESULT" "${logs[@]}" | sed 's/^RESULT //' > "$results"
cat "$results"

# count_violators <hold|setup>: the sum of violators=N over all corners
count_violators() {
  grep " $1:" "$results" | sed 's/.*violators=\([0-9]*\).*/\1/' | awk '{ sum += $1 } END { print sum + 0 }'
}
hold_violators=$(count_violators hold)
setup_violators=$(count_violators setup)
corners_timed=$(grep -c "hold:" "$results")
hold_worst_slack=$(sed -n 's/.* hold: .*worst_slack=\(.*\)/\1/p' "$results" | paste -sd' ')

summary hold_violators "$hold_violators"
summary setup_violators "$setup_violators"
summary corners_timed "$corners_timed"
summary "hold_worst_slack_ns($CORNERS)" "$hold_worst_slack"
if [ "$corners_timed" = "${#logs[@]}" ] && [ "$hold_violators" = 0 ] && [ "$setup_violators" = 0 ]; then
  summary status PASS
else
  summary status FAIL
fi
