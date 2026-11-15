#!/bin/bash
# Gate-level simulation of the croc_soc netlist in Icarus with sim/tb/tb_macro.v: the program is loaded over JTAG
# through the macro ports and must print GLS OK on uart_tx_o
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/gls/icarus_macro.sh <croc_soc.v> <work dir>      (inside the nix-shell of the template)
# in:  env PROG_HEX (default sim/sw/gls_mini/bin/gls_mini.hex), FLOPDELAY (default 0.5ns), INIT (power-up value of
#      the flops, default 0), VVP_ARGS
# out: <work dir>/run.log, compile.log
#
# Zero delay with the flop output delay of gate_models.py. vcs_sdf.sh is the same test with the delays of PrimeTime.
set -e
netlist=$(readlink -f "${1:?usage: icarus_macro.sh <croc_soc.v> <work dir>}")
work=${2:?usage: icarus_macro.sh <croc_soc.v> <work dir>}
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
program=${PROG_HEX:-$repo/sim/sw/gls_mini/bin/gls_mini.hex}
pdk=$HOME/.ciel/gf180mcuD/libs.ref
cell_models=$pdk/gf180mcu_fd_sc_mcu7t5v0/verilog
models=$repo/scripts/signoff/gate_models.py

mkdir -p "$work"
cd "$work"
python3 "$models" cells "$cell_models/gf180mcu_fd_sc_mcu7t5v0.v" cells_chip.v --flop-delay "${FLOPDELAY:-0.5ns}" --timescale
python3 "$models" primitives "$cell_models/primitives.v" primitives_chip.v --init "${INIT:-0}" --timescale
python3 "$models" sram "$pdk/gf180mcu_fd_ip_sram/verilog/gf180mcu_fd_ip_sram__sram512x8m8wm1.v" sram_chip.v
python3 "$models" netlist "$netlist" macro_nl.v --no-comments
python3 "$models" words "$program" prog_words.hex
cp "$repo/sim/tb/tb_macro.v" tb_macro.v

program_words=$(wc -l < prog_words.hex)
iverilog -g2012 -o macro_gls.vvp -s tb_macro -P tb_macro.NWORDS="$program_words" -DFUNCTIONAL -DUSE_POWER_PINS \
  primitives_chip.v cells_chip.v sram_chip.v macro_nl.v tb_macro.v 2>&1 \
  | grep -v -e "^$" -e "Timing checks are not supported" > compile.log || true
# all messages are in compile.log: head on the pipe of iverilog would stop it (SIGPIPE)
head -40 compile.log
echo "compiled $(date +%T)"
# shellcheck disable=SC2086  # VVP_ARGS is a list of plusargs
( time vvp -n macro_gls.vvp $VVP_ARGS ) 2>&1 | tee run.log | grep -E "\[TB\]|\[JTAG\]|\[CORE\]|\[UART\]|real|FAIL|PASS" | head -60
