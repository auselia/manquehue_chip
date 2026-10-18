#!/bin/bash
# Gate-level scan-shift test of the croc_soc macro netlist (outputs/latest/croc_soc.v) with Verilator.
# Shifts a pseudo-random stream through the scan chain with testmode_i = scan_se_i = 1 and both shift
# clocks, and checks it comes out of scan_so_o delayed by exactly the number of scan cells, also with
# jtag_trst_ni driven low (rst_ni low is run for information, see the loop below). See rtl/test/tb_scan_shift.sv.
#
# usage: scripts/sim/run_gls_scan.sh [work dir]      (default /tmp/gls_scan)
# env:   PDK_ROOT   default ~/.ciel
#        GLS_CXX    g++ with -fcoroutines (Verilator --timing); system g++ 8.5 on Rocky has none
#        GLS_RUN    netlist run folder, default outputs/latest
#        EXPECTED_LAG  scan cells in the chain, default 3964 (dft_drc: "Chain 1 ... scan_cells")
#        FLOPDELAY  output delay of the sequential cell models, default 0.5ns
#        JOBS       compile parallelism, default 8
# Run it inside an environment that has verilator (the template's nix-shell on Rocky).
#
# Same netlist and cell-model patches as scripts/sim/run_gls.sh (see there for why), nothing in the repo
# changes. Zero delay on the combinational gates means the clock tree has no skew in this simulation:
# it proves the chain order, the clock/enable/reset wiring and the reset gating, not hold timing (the
# scan-mode STA covers that).
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN=$(readlink -f "${GLS_RUN:-$REPO/outputs/latest}")
PDK=${PDK_ROOT:-$HOME/.ciel}/gf180mcuD/libs.ref
V=$PDK/gf180mcu_fd_sc_mcu7t5v0/verilog
S=$PDK/gf180mcu_fd_ip_sram/verilog
GXX=${GLS_CXX:-/nix/store/vr15iyyykg9zai6fpgvhcgyw7gckl78w-gcc-wrapper-14.3.0/bin/g++}
W=${1:-/tmp/gls_scan}
mkdir -p "$W"; cd "$W"
export W RUN V DELAY=${FLOPDELAY:-0.5ns}

python3 - <<'PY'
import os, re
W, RUN, V = os.environ["W"], os.environ["RUN"], os.environ["V"]
net = open(RUN + "/croc_soc.v").read()
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

cat > files.f <<EOT
+define+USE_POWER_PINS
+define+FUNCTIONAL
+define+VERILATOR=1
$REPO/rtl/test/tb_scan_shift.sv
$V/primitives.v
$W/cells.v
$W/sram.v
$W/croc_soc_gls.v
EOT

verilator --binary -MAKEFLAGS "CXX=$GXX LINK=$GXX" -j "${JOBS:-8}" -Wno-fatal -Wno-lint -Wno-style \
  -Wno-SPECIFYIGN --timing -f files.f --top-module tb_scan_shift -o Vscan > build.log 2>&1 \
  || { echo "verilator build failed, see $W/build.log"; exit 1; }

RC=0
# must pass: normal shift, and jtag_trst_ni driven low (its resets are gated by testmode_i).
# informational: rst_ni driven low. rst_ni is a DFT reset signal held inactive by the tester during scan; 800 flops
# (the reset-generator output, which follows rst_ni in test mode) are not gated, so this run is expected to disturb the chain.
for args in "" "+trstn_low" "+rstn_low"; do
  tag=$(echo "$args" | tr -d "+"); tag=${tag:-normal}
  echo "== run: ${args:-defaults}"
  set +e
  stdbuf -oL ./obj_dir/Vscan +expected_lag=${EXPECTED_LAG:-3964} $args 2>&1 | tee "run_${tag}.log" | grep -E "SCAN_SHIFT|Error|error"
  rc_run=${PIPESTATUS[0]}
  set -e
  if [ "$tag" = rstn_low ]; then continue; fi
  [ "$rc_run" = 0 ] || RC=1
  grep -q "SCAN_SHIFT_RESULT PASS" "run_${tag}.log" || RC=1
done
[ $RC = 0 ] && echo "ALL PASS" || echo "FAILED"
exit $RC
