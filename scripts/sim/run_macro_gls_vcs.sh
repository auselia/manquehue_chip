#!/bin/bash
# Macro-level gate-level simulation with the delays of PrimeTime (SDF), in VCS. Same test as run_macro_gls.sh
# (sim/tb/tb_macro.v): JTAG through the macro ports, program loaded over the debug module, GLS OK on uart_tx_o.
# usage: run_macro_gls_vcs.sh <croc_soc.v> <file.sdf> <min|max> <work dir>      (env: PROG_HEX)
#
# - Cells and SRAM: the original PDK models, with their specify blocks and timing checks. The only change: every
#   sequential primitive starts at 0 (no power-up value in the PDK, see sim/GLS.md) and the SRAM cen_dly as in
#   run_macro_gls.sh.
# - PrimeTime writes each delay as (min::max), with no typical value. +mindelays or +maxdelays selects one of them.
#   Run both: min is the hold side, max the setup side.
# - Timing checks are on (+neg_tchk). A violation prints "Timing violation" and puts X on the flop. The first stage
#   of every synchronizer samples a signal of another clock or a chip input on purpose, so its checks fail now and
#   then by design: only those flops lose their checks (noTiming, their delays stay).
set -e
NL=$(readlink -f "$1"); SDF=$(readlink -f "$2"); M=${3:?min or max}; W=${4:?work dir}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../utils/env.sh"
HEX=${PROG_HEX:-$REPO/sim/sw/gls_mini/gls_mini.hex}
PDK=$PDK_ROOT/gf180mcuD/libs.ref
export VCS_HOME PATH=$VCS_HOME/bin:$PATH
mkdir -p "$W"; cd "$W"
python3 - "$PDK" "$HEX" <<'PY'
import sys
pdk, hexf = sys.argv[1], sys.argv[2]
c = open(pdk + "/gf180mcu_fd_sc_mcu7t5v0/verilog/gf180mcu_fd_sc_mcu7t5v0.v").read()
open("cells.v", "w").write("`timescale 1ns/1ps\n" + c)
pr = open(pdk + "/gf180mcu_fd_sc_mcu7t5v0/verilog/primitives.v").read()
pr = pr.replace("\ntable\n", "\ninitial Q = 1'b0;\ntable\n")
open("primitives.v", "w").write("`timescale 1ns/1ps\n" + pr)
s = open(pdk + "/gf180mcu_fd_ip_sram/verilog/gf180mcu_fd_ip_sram__sram512x8m8wm1.v").read()
s = s.replace("  cen_dly        = 0;", "  cen_dly        = 1;")
open("sram.v", "w").write(s)
# program image: word per line from the byte hex (@addr lines + bytes)
mem, addr = {}, 0
for line in open(hexf):
    line = line.strip()
    if line.startswith("@"): addr = int(line[1:], 16); continue
    for b in line.split():
        mem[addr] = int(b, 16); addr += 1
words = [sum(mem.get(a + i, 0) << (8 * i) for i in range(4)) for a in range(min(mem), max(mem) + 1, 4)]
open("prog_words.hex", "w").write("\n".join(f"{w:08x}" for w in words) + "\n")
PY
grep -v '^//' "$NL" > macro_nl.v
cp "$REPO/sim/tb/tb_macro.v" .
NW=$(wc -l < prog_words.hex)
SYNC=$(grep -oE "\bi_[A-Za-z0-9_]*sync[A-Za-z0-9_]*_reg_0_\b" macro_nl.v | sort -u | sed 's/^/tb_macro.dut./' | paste -sd, -)
echo "instance {$SYNC} {noTiming};" > tcheck_off.cfg
echo "synchronizer first stages without timing checks: $(echo "$SYNC" | tr , '\n' | grep -c .)"
vcs -full64 -sverilog -timescale=1ns/1ps +neg_tchk +${M}delays -sdf_retain +optconfigfile+tcheck_off.cfg \
  "+define+SDF_FILE=\"$SDF\"" +define+USE_POWER_PINS -pvalue+tb_macro.NWORDS=$NW -top tb_macro \
  primitives.v cells.v sram.v macro_nl.v tb_macro.v -o simv -l compile.log > /dev/null 2>&1 || { tail -30 compile.log; exit 1; }
echo "SDF warnings: $(grep -c '^Warning-\[SDF' compile.log)"
( time ./simv -l run.log ) > /dev/null 2>&1 || true
grep -E "\[TB\]|\[JTAG\]" run.log | head -12
echo "timing violations: $(grep -c 'Timing violation' run.log)"
