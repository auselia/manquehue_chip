#!/bin/bash
# Replay of the ATPG patterns on the gate-level netlist in Icarus: every expected output is compared
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/dft/sim_patterns.sh <ATPG folder> [jobs] [patterns]      (env: DFT_REPLAY=parallel|serial)
# in:  <ATPG folder>/croc_soc_atpg.v, cells_atpg.v, primitives_atpg.v, sram_blackbox.v, patterns_stuck.stil,
#      scan_cells.rpt (parallel only)
# out: <ATPG folder>/sim_<chunk>.log, and "chunks passed: N of M" on stdout
#
# parallel (default): each pattern loads the chain by a force on every scan cell and reads the unload from the cells,
#   one simulation of about a minute.
# serial: each pattern shifts the chain in and out through scan_si_i and scan_so_o, which also tests the shift path
#   (about 4.5 h with 9 jobs). For a full sign-off.
# The SRAM is the black box of the ATPG run: its outputs are unknown, and the patterns mask what depends on them.
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../../utils/env.sh"
folder=$(readlink -f "${1:?ATPG folder}")
jobs=${2:-1}
models=$REPO/scripts/signoff/gate_models.py

cd "$folder"
python3 "$here/stil_to_vectors.py" patterns_stuck.stil .
patterns=${3:-$(wc -l < pi.mem)}
cp "$REPO/sim/tb/tb_atpg.v" .
python3 "$models" cells cells_atpg.v cells_sim.v --flop-delay 0.5 --timescale
python3 "$models" primitives primitives_atpg.v primitives_sim.v --timescale

parallel_define=""
if [ "${DFT_REPLAY:-parallel}" = parallel ]; then
  python3 "$here/scan_cells_vh.py" scan_cells.rpt croc_soc_atpg.v .
  parallel_define=-DPARALLEL
  jobs=1
fi
echo "replay mode: ${DFT_REPLAY:-parallel}"
iverilog -g2012 -o sim.vvp -DFUNCTIONAL $parallel_define -s tb_atpg \
  primitives_sim.v cells_sim.v sram_blackbox.v croc_soc_atpg.v tb_atpg.v
echo "compiled $(date +%T)"

# chunks of consecutive patterns run as independent simulations, each from a loaded chain
per_chunk=$(( (patterns + jobs - 1) / jobs ))
rm -f sim_*.log
for ((chunk = 0; chunk < jobs; chunk++)); do
  first=$(( chunk * per_chunk ))
  count=$(( patterns - first ))
  (( count > per_chunk )) && count=$per_chunk
  (( count > 0 )) || continue
  vvp -n sim.vvp +first=$first +npat=$count > "sim_$chunk.log" 2>&1 &
done
wait
echo "finished $(date +%T)"
grep -h "PASS\|FAIL\|MISMATCH" sim_*.log | head -30
echo "chunks passed: $(grep -l PASS sim_*.log | wc -l) of $(ls sim_*.log | wc -l)"
