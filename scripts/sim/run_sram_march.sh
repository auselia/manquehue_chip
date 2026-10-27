#!/bin/bash
# March C- of the 2 KB SRAM through the JTAG debug module on the gate-level macro, fault-free and with injected faults.
# usage: run_sram_march.sh <croc_soc.v> [work dir]        (needs iverilog, about 2 min per run, runs in parallel)
# Results: <work dir>/run_<case>.log, last lines "MARCH PASS" / "MARCH FAIL". Faults go into the behavioural SRAM model.
set -e
MACRO_NL=$(readlink -f "${1:?croc_soc.v}"); W=${2:?work dir}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../utils/env.sh"
PDK=$HOME/.ciel/gf180mcuD/libs.ref
mkdir -p "$W"; cd "$W"
export MACRO_NL PDK
python3 - <<'PY'
import os, re
v = os.environ["PDK"] + "/gf180mcu_fd_sc_mcu7t5v0/verilog"
n = [0]
def rep(m):
    n[0] += 1
    return (f"{m.group(1)}buf #(0.5ns) MGMDLY_{n[0]}( {m.group(3)}, {m.group(3)}_u );\n"
            f"{m.group(1)}{m.group(2)}( {m.group(3)}_u,")
c = open(v + "/gf180mcu_fd_sc_mcu7t5v0.v").read()
c = re.sub(r"(\s*)(gf180mcu_fd_sc_mcu7t5v0__udp_[a-z_]+)\(\s*(\w+),", rep, c)
open("cells_chip.v", "w").write("`timescale 1ns/1ps\n" + c)        # no timescale: Icarus would round the flop delay to 0
pr = open(v + "/primitives.v").read().replace("\ntable\n", "\ninitial Q = 1'b0;\ntable\n")
open("primitives_chip.v", "w").write("`timescale 1ns/1ps\n" + pr)
s = open(os.environ["PDK"] + "/gf180mcu_fd_ip_sram/verilog/gf180mcu_fd_ip_sram__sram512x8m8wm1.v").read()
open("sram_chip.v", "w").write(s.replace("  cen_dly        = 0;", "  cen_dly        = 1;"))
PY
grep -v '^//' "$MACRO_NL" > macro_nl.v
iverilog -g2012 -o march.vvp -DFUNCTIONAL -DUSE_POWER_PINS -DSLOT_0P5X1 -DSCL_gf180mcu_fd_sc_mcu7t5v0 -DSRAM_gf180mcu_fd_ip_sram \
  -s tb_sram_march primitives_chip.v cells_chip.v sram_chip.v macro_nl.v "$HERE/../../sim/tb/tb_sram_march.v"
run() { n=$1; shift; ( vvp -n march.vvp "$@" > run_$n.log 2>&1 ) & }
run good
run checker +checker
run saf0  +fault=saf0 +fa=100 +fb=3
run saf1  +fault=saf1 +fa=300 +fb=7
run cfin  +fault=cfin +fa=200 +fa2=201 +fb=5
run af    +fault=af   +fa=10  +fa2=400
wait
for n in good checker saf0 saf1 cfin af; do printf "%-8s %s\n" $n "$(grep -h 'MARCH PASS\|MARCH FAIL' run_$n.log)"; done
