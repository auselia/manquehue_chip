#!/bin/bash
# Chip-level gate-level simulation of chip_top (pads included) in Icarus, plain Verilog test bench.
# usage: run_chip_gls.sh <chip_top.pnl.v> <croc_soc.v> [work dir]       (run inside the template's nix-shell: iverilog)
#   env SDF=<file.sdf>: simulation with timing. The cell models keep their specify blocks (no -DFUNCTIONAL), the
#   delays of PrimeTime are annotated (tb_macro.v, $sdf_annotate), and the flops get no extra output delay.
set -e
CHIP_NL=none; MACRO_NL=$(readlink -f "$2"); W=${3:?work dir}
HEX=${PROG_HEX:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/sim/sw/gls_mini/gls_mini.hex}
T=${TEMPLATE_DIR:-$HOME/Documents/waferspace_manquehue}
PDK=$HOME/.ciel/gf180mcuD/libs.ref
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p $W; cd $W
FUNC=-DFUNCTIONAL; DEFAULT_DLY=0.5ns
if [ -n "$SDF" ]; then
  # The SRAM entries of the SDF have a COND that Icarus cannot parse (CEN==1'b0&&GWEN==1'b1), and it stops reading the
  # file there. The SRAM model has no edge paths in timing mode (below), so its CELL blocks are left out of a copy.
  mkdir -p "$W"
  python3 - "$(readlink -f "$SDF")" "$W/sim.sdf" <<'EOF'
import re, sys
t = open(sys.argv[1]).read()
parts = re.split(r"(?m)^(?=\(CELL\s*$)", t)
keep = [x for x in parts if 'CELLTYPE "gf180mcu_fd_ip_sram__' not in x]
if not keep[-1].rstrip().endswith(")"):
    keep[-1] += ")"
open(sys.argv[2], "w").write("".join(keep))
print("SDF for the simulation:", len(parts) - len(keep), "SRAM cell block(s) left out")
EOF
  FUNC="-gspecify -ginterconnect -DSDF_FILE=\"$W/sim.sdf\""; DEFAULT_DLY=0
fi
export INIT=${INIT:-0} CHIP_NL MACRO_NL HEX PDK W HERE FLOPDELAY=${FLOPDELAY:-$DEFAULT_DLY}
python3 - <<'PY'
import os, re
pdk, W, hexf = os.environ["PDK"], os.environ["W"], os.environ["HEX"]
v = pdk + "/gf180mcu_fd_sc_mcu7t5v0/verilog"
# flop output delay: same reason as in scripts/sim/run_gls.sh (zero-delay clock-tree race, above the SRAM model's 100 ps)
c = open(v + "/gf180mcu_fd_sc_mcu7t5v0.v").read()
n = [0]
def rep(m):
    n[0] += 1
    return (f"{m.group(1)}buf #({os.environ['FLOPDELAY']}) MGMDLY_{n[0]}( {m.group(3)}, {m.group(3)}_u );\n"
            f"{m.group(1)}{m.group(2)}( {m.group(3)}_u,")
c = re.sub(r"(\s*)(gf180mcu_fd_sc_mcu7t5v0__udp_[a-z_]+)\(\s*(\w+),", rep, c)
# timing mode: Icarus does not take ifnone before an edge-sensitive path ("sorry"). Without the keyword it is a plain
# edge-sensitive path, and the SDF still annotates it.
if os.environ.get("SDF"):
    c = re.sub(r"\bifnone\b", "", c)
open("cells_chip.v", "w").write("`timescale 1ns/1ps\n" + c)   # without a timescale Icarus uses 1 s units and rounds the flop delay to 0
# power-up state of the sequential cells: all flops and latches start at INIT (0 or 1), like a Verilator two-state run.
# Without it every unreset flop is X for ever and the four-state simulator never leaves X (pessimism, not a design bug).
pr = open(v + "/primitives.v").read()
pr = pr.replace("\ntable\n", "\ninitial Q = 1'b%s;\ntable\n" % os.environ.get("INIT", "0"))
open("primitives_chip.v", "w").write("`timescale 1ns/1ps\n" + pr)
s = open(pdk + "/gf180mcu_fd_ip_sram/verilog/gf180mcu_fd_ip_sram__sram512x8m8wm1.v").read()
s = s.replace("  cen_dly        = 0;", "  cen_dly        = 1;")
# timing mode: Icarus rejects the conditional edge paths of the SRAM model (CLK to Q[i]). Only those lines are left
# out (the specparams stay): the SRAM keeps the access delay of its behavioral model, the cells get the SDF delays.
if os.environ.get("SDF"):
    s = re.sub(r"(?m)^.*\(posedge CLK => \(Q\[\d\].*$", "", s)
open("sram_chip.v", "w").write(s)
# program image: word per line from the byte hex (@addr lines + bytes)
mem, addr = {}, 0
for line in open(hexf):
    line = line.strip()
    if line.startswith("@"): addr = int(line[1:], 16); continue
    for b in line.split():
        mem[addr] = int(b, 16); addr += 1
lo, hi = min(mem), max(mem)
words = []
for a in range(lo, hi + 1, 4):
    words.append(sum(mem.get(a + i, 0) << (8 * i) for i in range(4)))
open("prog_words.hex", "w").write("\n".join(f"{w:08x}" for w in words) + "\n")
print("delayed sequential cells:", n[0], " program words:", len(words), " base 0x%x" % lo)
PY
NW=$(wc -l < prog_words.hex)
# the netlist headers hold one comment line of many thousand characters, which Icarus' scanner cannot take
grep -v '^//' "$MACRO_NL" > macro_nl.v
cp $HERE/../../sim/tb/tb_macro.v tb_macro.v
IP=$(ls $T/ip/gf180mcu_ws_ip__*/vh/*.v)
iverilog -g2012 -o macro_gls.vvp -s tb_macro -P tb_macro.NWORDS=$NW \
  $FUNC -DUSE_POWER_PINS -DSLOT_0P5X1 -DPAD_gf180mcu_fd_io -DSCL_gf180mcu_fd_sc_mcu7t5v0 -DSRAM_gf180mcu_fd_ip_sram \
  -I $T/src \
  primitives_chip.v cells_chip.v sram_chip.v macro_nl.v tb_macro.v 2>&1 | grep -v -e "^$" -e "Timing checks are not supported" > compile.log || true
head -40 compile.log   # all messages in compile.log: head on the pipe would stop iverilog (SIGPIPE)
echo "compiled $(date +%T)"
( time vvp -n macro_gls.vvp $VVP_ARGS ) 2>&1 | tee run.log | grep -E "\[TB\]|\[JTAG\]|\[CORE\]|\[UART\]|real|FAIL|PASS" | head -60
