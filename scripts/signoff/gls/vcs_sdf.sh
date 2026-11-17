#!/bin/bash
# Gate-level simulation of the croc_soc netlist in VCS with the SDF delays of PrimeTime and the timing checks on:
# the test of icarus_macro.sh (sim/tb/tb_macro.v, program over JTAG, GLS OK on uart_tx_o) with real delays
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/gls/vcs_sdf.sh <croc_soc.v> <file.sdf> <min|max> <work dir>      (env: PROG_HEX, VCS_EXTRA)
# in:  the netlist, the typical SDF of make sta-pt, the PDK cell and SRAM models with their specify blocks
# out: <work dir>/run.log, compile.log, and "timing violations: N" on stdout
#
# PrimeTime writes each delay as (min::max), with no typical value: +mindelays (the hold side) or +maxdelays (the
# setup side) selects one. A timing violation prints "Timing violation" and puts X on the flop.
# The first stage of every synchronizer samples a signal of another clock or a chip input on purpose: its checks
# fail now and then by design, so only those flops run without checks (noTiming). Their delays stay.
set -e
netlist=$(readlink -f "$1")
sdf=$(readlink -f "$2")
delays=${3:?min or max}
work=${4:?work dir}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../../utils/env.sh"
program=${PROG_HEX:-$REPO/sim/sw/gls_mini/bin/gls_mini.hex}
pdk=$PDK_ROOT/gf180mcuD/libs.ref
cell_models=$pdk/gf180mcu_fd_sc_mcu7t5v0/verilog
models=$REPO/scripts/signoff/gate_models.py
export VCS_HOME PATH=$VCS_HOME/bin:$PATH

mkdir -p "$work"
cd "$work"
python3 "$models" cells "$cell_models/gf180mcu_fd_sc_mcu7t5v0.v" cells.v --timescale
python3 "$models" primitives "$cell_models/primitives.v" primitives.v --init 0 --timescale
python3 "$models" sram "$pdk/gf180mcu_fd_ip_sram/verilog/gf180mcu_fd_ip_sram__sram512x8m8wm1.v" sram.v
python3 "$models" netlist "$netlist" macro_nl.v --no-comments
python3 "$models" words "$program" prog_words.hex
cp "$REPO/sim/tb/tb_macro.v" .
program_words=$(wc -l < prog_words.hex)

# the first flop of every synchronizer (its name ends in sync..._reg_0_) runs without timing checks
sync_flops=$(grep -oE "\bi_[A-Za-z0-9_]*sync[A-Za-z0-9_]*_reg_0_\b" macro_nl.v | sort -u | sed 's/^/tb_macro.dut./' | paste -sd, -)
echo "instance {$sync_flops} {noTiming};" > tcheck_off.cfg
echo "synchronizer first stages without timing checks: $(echo "$sync_flops" | tr , '\n' | grep -c .)"

# shellcheck disable=SC2086  # VCS_EXTRA is a list of options
vcs -full64 -sverilog -timescale=1ns/1ps ${VCS_EXTRA:-} +neg_tchk +"${delays}"delays -sdf_retain +optconfigfile+tcheck_off.cfg \
  "+define+SDF_FILE=\"$sdf\"" +define+USE_POWER_PINS -pvalue+tb_macro.NWORDS="$program_words" -top tb_macro \
  primitives.v cells.v sram.v macro_nl.v tb_macro.v -o simv -l compile.log > /dev/null 2>&1 \
  || { tail -30 compile.log; exit 1; }
echo "SDF warnings: $(grep -c '^Warning-\[SDF' compile.log)"
( time ./simv -l run.log ) > /dev/null 2>&1 || true
grep -E "\[TB\]|\[JTAG\]" run.log | head -12
echo "timing violations: $(grep -c 'Timing violation' run.log)"
