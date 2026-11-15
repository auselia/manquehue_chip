#!/bin/bash
# Plays each scope capture with the WaveGen (cav_arb.py) and records croc's ADC (the step 3 -DDUMP build in the flash,
# ./load.sh boot) or croc's FFT features (the step 5 build in the flash), into logs/cav_<mode>_<capture>.log.
#   ./cav_run.sh dump|fft <capture.csv>...
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
PY=${PY:-python3}
MODE=${1:?dump|fft}; shift
mkdir -p logs
for C in "$@"; do
  N=$(basename "$C" _all.csv)
  OUT=logs/cav_${MODE}_${N}.log
  rm -f "$OUT" "$OUT.ready"
  $PY cav_arb.py "$C" > "$OUT.arb"
  python3 -I scope.py ":WGEN:OUTP 1" > /dev/null
  sleep 1
  python3 -I ad2_uart.py 15 "$OUT" > /dev/null 2> "$OUT.err" &
  RP=$!
  for i in $(seq 50); do [ -f "$OUT.ready" ] && break; sleep 0.1; done
  timeout 40 ./load.sh boot > /dev/null 2>&1
  wait $RP
  python3 -I scope.py ":WGEN:OUTP 0" > /dev/null
  echo "== $N: $(head -1 "$OUT.arb")"
  if [ "$MODE" = dump ]; then $PY cav_compare.py "$C" "$OUT"; else grep -E "peak bin|band energy|total energy|STEP5" "$OUT"; fi
done
