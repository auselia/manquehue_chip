#!/bin/bash
# Open-flow synthesis of croc_soc (Yosys + slang + ABC) for gf180mcu_fd_sc_mcu7t5v0.
# usage: nix develop path:$PWD (in oss/) -c oss/yosys/run_synthesis.sh      env: SYNTH_PERIOD_PS (default 40000)
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../env.sh
python3 ../prep_rtl.py
AIG=src/lazy_man_synth_library.aig
if [ ! -s $AIG ]; then
  echo "fetching the ABC record library from pulp-platform/croc (42 MB)"
  curl -fL --retry 5 -o $AIG https://raw.githubusercontent.com/pulp-platform/croc/88ec4ebb0aa7aff8778381eba196858a424e9d52/yosys/src/lazy_man_synth_library.aig
fi
rm -rf out tmp reports; mkdir -p out tmp reports
echo "start $(date +%T)"
yosys -c scripts/yosys_synthesis.tcl > synth.log 2>&1 && echo "synthesis ok $(date +%T)" || { echo "synthesis FAILED"; tail -30 synth.log; exit 1; }
grep -E "Number of cells|Chip area|Number of wires" reports/croc_soc_area.rpt | tail -4
