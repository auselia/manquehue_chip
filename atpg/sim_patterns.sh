#!/bin/bash
# Apply the ATPG patterns to the gate-level netlist in Icarus and compare every expected output.
# usage: sim_patterns.sh <run dir> [jobs] [npat]   (jobs: parallel chunks, default 1; npat: only the first n patterns)
#   <run dir> holds croc_soc_atpg.v (fix_inputs.py), cells_atpg.v, primitives_atpg.v, sram_blackbox.v and
#   patterns_stuck.stil (TestMAX ATPG). npat limits the number of patterns (default: all 573).
# The SRAM is the black box of the ATPG run: its outputs are unknown and the patterns mask what depends on them.
# Flop delay 0.5 ns as in sim/GLS.md; the cell library has no timescale and Icarus would round the delay to 0.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
D=$(readlink -f "${1:?run dir}"); JOBS=${2:-1}; NPAT=${3:-573}
IVERILOG=${IVERILOG:-$(ls -d /nix/store/*-iverilog-*/bin | head -1)}
export PATH=$IVERILOG:$PATH
cd "$D"
python3 "$HERE/stil_to_vectors.py" patterns_stuck.stil .
cp "$HERE/tb_atpg.v" .
python3 - <<'PY'
import re
n = [0]
def rep(m):
    n[0] += 1
    return (f"{m.group(1)}buf #(0.5) MGMDLY_{n[0]}( {m.group(3)}, {m.group(3)}_u );\n"
            f"{m.group(1)}{m.group(2)}( {m.group(3)}_u,")
c = open("cells_atpg.v").read()
c = re.sub(r"(\s*)(gf180mcu_fd_sc_mcu7t5v0__udp_[a-z_]+)\(\s*(\w+),", rep, c)
open("cells_sim.v", "w").write("`timescale 1ns/1ps\n" + c)
open("primitives_sim.v", "w").write("`timescale 1ns/1ps\n" + open("primitives_atpg.v").read())
print("delayed sequential cells:", n[0])
PY
iverilog -g2012 -o sim.vvp -DFUNCTIONAL -s tb_atpg primitives_sim.v cells_sim.v sram_blackbox.v croc_soc_atpg.v tb_atpg.v
echo "compiled $(date +%T)"
# chunks of consecutive patterns run as independent simulations (each starts from a loaded chain)
per=$(( (NPAT + JOBS - 1) / JOBS ))
rm -f sim_*.log
for ((i = 0; i < JOBS; i++)); do
  first=$(( i * per )); n=$(( NPAT - first )); (( n > per )) && n=$per
  (( n > 0 )) || continue
  vvp -n sim.vvp +first=$first +npat=$n > sim_$i.log 2>&1 &
done
wait
echo "finished $(date +%T)"
grep -h "PASS\|FAIL\|MISMATCH" sim_*.log | head -30
echo "chunks passed: $(grep -l PASS sim_*.log | wc -l) of $(ls sim_*.log | wc -l)"
