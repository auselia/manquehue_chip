#!/bin/bash
# Self-test of the behavioural models of the ADS7057 and the SX1276 (Icarus). usage: verify/models/run_models.sh [work dir]
set -e
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../env.sh"
W=${1:-$REPO/build/models}; mkdir -p "$W"
iverilog -g2012 -o "$W/models.vvp" "$HERE/tb_models.v" "$HERE/ads7057_model.v" "$HERE/sx1276_model.v"
vvp -n "$W/models.vvp" | tee "$W/models.log" | grep -E "PASS|FAIL"
