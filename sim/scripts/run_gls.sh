#!/bin/bash
# Zero-delay gate-level simulation of the croc_soc macro netlist (outputs/latest/croc_soc.v)
# with Verilator, using the repo testbench. No waveform dump: the testbench hard-codes
# `define TRACE_WAVE and a --trace build writes tens of GB.
#
# usage: sim/scripts/run_gls.sh <program.hex> [work dir]
#   program.hex  must fit the 2 KB SRAM, e.g. sim/sw/gls_mini/build.sh -> bin/gls_mini.hex
#   work dir     default /tmp/gls_full
# env:   PDK_ROOT   default ~/.ciel
#        GLS_CXX    g++ with -fcoroutines (Verilator --timing); system g++ 8.5 on Rocky has none
#        GLS_RUN     netlist run folder, default outputs/latest
#        GLS_TIMEOUT run time limit in seconds, default 7200
#        JOBS       compile parallelism, default 8
# Run it inside an environment that has verilator (the template's nix-shell on Rocky).
#
# What it patches, all in the work dir (nothing in the repo changes):
#  - the testbench instantiates the netlist module instead of the RTL one (TARGET_GLS), ties the
#    scan ports off if the netlist has them, and prints a time marker every 100 us
#  - the netlist loses its redundant VDD/VSS port declarations (the cell models declare supplies)
#  - cell models: the weak bus keeper is unsupported by Verilator, and the 18 sequential UDPs get
#    a 0.1 ns output delay, otherwise the zero-delay clock tree races and the JTAG TAP shifts one
#    cycle early
#  - the vendor SRAM model starts with CEN deasserted (its own initial block sets cen_dly = 0)
# Output must stay line-buffered (stdbuf -oL) or it is lost when the run is killed.
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN=$(readlink -f "${GLS_RUN:-$REPO/outputs/latest}")
PDK=${PDK_ROOT:-$HOME/.ciel}/gf180mcuD/libs.ref
V=$PDK/gf180mcu_fd_sc_mcu7t5v0/verilog
S=$PDK/gf180mcu_fd_ip_sram/verilog
GXX=${GLS_CXX:-/nix/store/vr15iyyykg9zai6fpgvhcgyw7gckl78w-gcc-wrapper-14.3.0/bin/g++}
HEX=$(readlink -f "${1:?usage: run_gls.sh <program.hex> [work dir]}")
W=${2:-/tmp/gls_full}
mkdir -p "$W/tb"; cd "$W"
export W RUN V DELAY=0.1ns

cp "$REPO"/rtl/test/*.sv tb/
python3 - <<'PY'
import os, re
W, RUN, V = os.environ["W"], os.environ["RUN"], os.environ["V"]

p = W + "/tb/tb_croc_soc.sv"
s = open(p).read()
old = "  `ifdef TARGET_NETLIST_YOSYS\n  \\croc_soc$croc_chip.i_croc_soc i_croc_soc (\n  `else"
assert s.count(old) == 1
s = s.replace(old, old.replace("  `else", "  `elsif TARGET_GLS\n  croc_soc i_croc_soc (\n  `else"))
net = open(RUN + "/croc_soc.v").read()
if re.search(r"\bscan_se_i\b", net):
    old = "    .testmode_i    ( 1'b0        ),\n"
    assert s.count(old) == 1
    s = s.replace(old, old + "    .scan_si_i     ( 1'b0        ),\n    .scan_se_i     ( 1'b0        ),\n    .scan_so_o     (             ),\n")
i = s.rindex("endmodule")
s = s[:i] + "  initial forever begin #100us; $display(\"PROG %0t\", $time); end\n" + s[i:]
open(p, "w").write(s)

net = net.replace(" , VDD , VSS ) ;", " ) ;", 1)
net = net.replace("input  VDD ;\n", "", 1).replace("input  VSS ;\n", "", 1)
open(W + "/croc_soc_gls.v", "w").write(net)

c = open(V + "/gf180mcu_fd_sc_mcu7t5v0.v").read().replace("buf (weak0, weak1)", "buf")
n = [0]
def rep(m):
    n[0] += 1
    return (f"{m.group(1)}buf #({os.environ['DELAY']}) MGMDLY_{n[0]}( {m.group(3)}, {m.group(3)}_u );\n"
            f"{m.group(1)}{m.group(2)}( {m.group(3)}_u,")
c = re.sub(r"(\s*)(gf180mcu_fd_sc_mcu7t5v0__udp_[a-z_]+)\(\s*(\w+),", rep, c)
open(W + "/cells.v", "w").write(c)
print("sequential UDP outputs delayed:", n[0])
PY
sed "s/^  cen_dly        = 0;/  cen_dly        = 1;/" "$S/gf180mcu_fd_ip_sram__sram512x8m8wm1.v" > sram.v
grep -c "cen_dly        = 1;" sram.v

cat > files.f <<EOF
+incdir+$REPO/rtl/apb/include
+incdir+$REPO/rtl/common_cells/include
+incdir+$REPO/rtl/cve2/include
+incdir+$REPO/rtl/idma/include
+incdir+$REPO/rtl/obi/include
+define+TARGET_FLIST
+define+TARGET_GLS
+define+FUNCTIONAL
+define+USE_POWER_PINS
+define+VERILATOR=1
+define+COMMON_CELLS_ASSERTS_OFF=1
$REPO/rtl/common_verification/clk_rst_gen.sv
$REPO/rtl/common_cells/cf_math_pkg.sv
$REPO/rtl/riscv-dbg/dm_pkg.sv
$REPO/rtl/riscv-dbg/tb/jtag_test_simple.sv
$REPO/rtl/obi/obi_pkg.sv
$REPO/rtl/croc_pkg.sv
$REPO/rtl/user_pkg.sv
$REPO/rtl/soc_ctrl/soc_ctrl_regs_pkg.sv
$REPO/rtl/gpio/gpio_reg_pkg.sv
$REPO/rtl/clint/clint_reg_pkg.sv
$REPO/rtl/obi_timer/obi_timer_reg_pkg.sv
$W/tb/tb_croc_pkg.sv
$W/tb/croc_vip.sv
$W/tb/tb_croc_soc.sv
$V/primitives.v
$W/cells.v
$W/sram.v
$W/croc_soc_gls.v
EOF

verilator --binary -MAKEFLAGS "CXX=$GXX LINK=$GXX" -j "${JOBS:-8}" -Wno-fatal -Wno-lint -Wno-style \
  -Wno-SPECIFYIGN --timing -f files.f --top-module tb_croc_soc -o Vgls > build.log 2>&1 \
  || { echo "verilator build failed, see $W/build.log"; exit 1; }
echo "run start $(date +%T)" > run.status
set +e
( time timeout "${GLS_TIMEOUT:-7200}" stdbuf -oL ./obj_dir/Vgls +binary="$HEX" ) > run.log 2>&1
echo "run end $(date +%T) rc=$?" >> run.status
tail -n 15 run.log
