#!/bin/bash
# One step 7 test: plays an event with event_arb.py, boots croc (step 7 in the flash), captures the UART with the AD2
# and checks it with event_check.py.   ./event_run.sh <name> <event_arb.py arguments...>
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
PY=${PY:-python3}
N=$1; shift
OUT=logs/event_$N.log
rm -f "$OUT" "$OUT.ready"
$PY event_arb.py "$@"
python3 -I scope.py ":WGEN:OUTP 1" > /dev/null
sleep 0.5
python3 -I ad2_uart.py 20 "$OUT" > /dev/null 2> "$OUT.err" &
RP=$!
for i in $(seq 50); do [ -f "$OUT.ready" ] && break; sleep 0.1; done
timeout 40 ./load.sh boot > /dev/null 2>&1
wait $RP
python3 -I scope.py ":WGEN:OUTP 0" > /dev/null
grep -E "STEP7|fail" "$OUT" || true
$PY event_check.py "$OUT"
