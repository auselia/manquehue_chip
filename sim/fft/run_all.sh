#!/bin/bash
# Full test of the FFT accelerator: run_bus.sh at response latencies 1 to 3, with and without random grant
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: sim/fft/run_all.sh [--regen]      (--regen writes the vectors again: needs numpy, and the CSV captures)
# in:  sim/fft/vectors/ (or gen_vectors.py with --regen)
# out: one "PASS <case>" or "FAIL <case>" line per case. Exit 1 when a case fails.
set -e
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here"
[ "${1:-}" = --regen ] && python3 gen_vectors.py
failed=0

# check <name> <command...>: PASS when the command prints a line that starts with PASS
check() {
  local name=$1 output blocks_line
  shift
  output=$("$@" 2>&1) || true
  blocks_line=$(echo "$output" | grep -E '^blocks:' | head -1)
  if echo "$output" | grep -q '^PASS'; then
    echo "PASS  $name   $blocks_line"
  else
    echo "FAIL  $name   $blocks_line"
    echo "$output" | tail -15
    failed=1
  fi
}

for latency in 1 2 3; do
  for random_grant in 0 1; do
    check "bus, response latency=$latency, random grant=$random_grant" ./run_bus.sh $latency $random_grant
  done
done
exit $failed
