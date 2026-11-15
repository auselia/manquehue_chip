#!/bin/bash
# March C- test of the 2 KB SRAM through the JTAG debug module on the gate-level netlist, fault-free and with four
# injected faults
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/dft/sram_march.sh <croc_soc.v> <work dir>      (about 2 min, the six runs in parallel)
# in:  the netlist, sim/tb/tb_sram_march.v
# out: <work dir>/run_<case>.log, each ending with "MARCH PASS" or "MARCH FAIL"
#
# The faults go into the behavioural SRAM model. The fault-free run must pass, every fault run must fail.
set -e
netlist=$(readlink -f "${1:?croc_soc.v}")
work=${2:?work dir}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../../utils/env.sh"
pdk=$HOME/.ciel/gf180mcuD/libs.ref
cell_models=$pdk/gf180mcu_fd_sc_mcu7t5v0/verilog
models=$REPO/scripts/signoff/gate_models.py

mkdir -p "$work"
cd "$work"
python3 "$models" cells "$cell_models/gf180mcu_fd_sc_mcu7t5v0.v" cells_chip.v --flop-delay 0.5ns --timescale
python3 "$models" primitives "$cell_models/primitives.v" primitives_chip.v --init 0 --timescale
python3 "$models" sram "$pdk/gf180mcu_fd_ip_sram/verilog/gf180mcu_fd_ip_sram__sram512x8m8wm1.v" sram_chip.v
python3 "$models" netlist "$netlist" macro_nl.v --no-comments
iverilog -g2012 -o march.vvp -DFUNCTIONAL -DUSE_POWER_PINS -s tb_sram_march \
  primitives_chip.v cells_chip.v sram_chip.v macro_nl.v "$REPO/sim/tb/tb_sram_march.v"

# run_case <name> <plusargs...>: one simulation in the background
run_case() {
  local name=$1
  shift
  vvp -n march.vvp "$@" > "run_$name.log" 2>&1 &
}
run_case good
run_case checker +checker
run_case saf0 +fault=saf0 +fa=100 +fb=3
run_case saf1 +fault=saf1 +fa=300 +fb=7
run_case cfin +fault=cfin +fa=200 +fa2=201 +fb=5
run_case af   +fault=af   +fa=10  +fa2=400
wait
for name in good checker saf0 saf1 cfin af; do
  printf "%-8s %s\n" $name "$(grep -h 'MARCH PASS\|MARCH FAIL' "run_$name.log")"
done
