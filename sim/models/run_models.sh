#!/bin/bash
# Self-test of the behavioural models of the ADS7057 ADC and the SX1276 radio, in Icarus
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: sim/models/run_models.sh [work dir]      (default sim/build/models)
# in:  sim/models/tb_models.v, ads7057_model.v, sx1276_model.v
# out: <work dir>/models.log, and the PASS or FAIL lines on stdout
set -e
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../../scripts/utils/env.sh"
work=${1:-$REPO/sim/build/models}
mkdir -p "$work"
iverilog -g2012 -o "$work/models.vvp" "$here/tb_models.v" "$here/ads7057_model.v" "$here/sx1276_model.v"
vvp -n "$work/models.vvp" | tee "$work/models.log" | grep -E "PASS|FAIL"
