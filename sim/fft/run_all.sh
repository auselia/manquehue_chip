#!/bin/bash
# Full regression of the AE-FFT accelerator: regenerate vectors (optional), core test, bus test sweep.
#   sim/fft/run_all.sh [--regen]       --regen rebuilds the vectors (needs numpy and, for captured data, the CSV files)
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
[ "$1" = "--regen" ] && python3 gen_vectors.py
fail=0
check() { # name, command...
  local name="$1"; shift
  local out; out="$("$@" 2>&1)" || true
  local line; line="$(echo "$out" | grep -E '^blocks:' | head -1)"
  if echo "$out" | grep -q '^PASS'; then echo "PASS  $name   $line"; else echo "FAIL  $name   $line"; echo "$out" | tail -15; fail=1; fi
}
for bp in 0 1; do check "core, dump back-pressure=$bp" ./run_core.sh $bp; done
for lat in 1 2 3; do for rg in 0 1; do check "bus, response latency=$lat, random grant=$rg" ./run_bus.sh $lat $rg; done; done
exit $fail
