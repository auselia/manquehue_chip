#!/bin/bash
# Gate-level test of the scan chain of a run in Verilator: a pseudo-random stream shifted through the chain must come
# out of scan_so_o delayed by exactly the number of scan cells
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: EXPECTED_LAG=<scan cells> scripts/signoff/gls/scan_shift.sh <work dir>      (inside the nix-shell of the template)
# in:  env EXPECTED_LAG (gls.sh reads it from the synthesis log), GLS_RUN (default outputs/latest), FLOPDELAY,
#      GLS_CXX, JOBS, PDK_ROOT
# out: <work dir>/run_<case>.log, and "ALL PASS" or "FAILED" as the last line
#
# testmode_i = scan_se_i = 1, both shift clocks (sim/tb/tb_scan_shift.sv). The gates have zero delay, so the clock
# tree has no skew here: the test proves the chain order and the clock, enable and reset wiring, not the hold timing
# (scan_sta.sh does that).
set -e
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
run_dir=$(readlink -f "${GLS_RUN:-$repo/outputs/latest}")
work=${1:?usage: scan_shift.sh <work dir>}
expected_lag=${EXPECTED_LAG:?set EXPECTED_LAG to the number of scan cells}
pdk=${PDK_ROOT:-$HOME/.ciel}/gf180mcuD/libs.ref
cell_models=$pdk/gf180mcu_fd_sc_mcu7t5v0/verilog
sram_models=$pdk/gf180mcu_fd_ip_sram/verilog
. "$repo/scripts/utils/env.sh"
cxx=${GLS_CXX:-$SIM_CXX}
models=$repo/scripts/signoff/gate_models.py

mkdir -p "$work"
cd "$work"
python3 "$models" netlist "$run_dir/croc_soc.v" croc_soc_gls.v --no-supply-ports
python3 "$models" cells "$cell_models/gf180mcu_fd_sc_mcu7t5v0.v" cells.v --no-keeper --flop-delay "${FLOPDELAY:-0.5ns}"
python3 "$models" sram "$sram_models/gf180mcu_fd_ip_sram__sram512x8m8wm1.v" sram.v

# The chain in the netlist: its length must be the expected one. An odd number of inverters between the cells
# returns the stream inverted.
trace=$(python3 "$repo/scripts/signoff/gls/scan_chain_trace.py" "$run_dir/croc_soc.v")
echo "scan chain in the netlist: $trace"
traced_cells=$(echo "$trace" | sed -n 's/.*cells=\([0-9]*\).*/\1/p')
inversions=$(echo "$trace" | sed -n 's/.*inversions=\([0-9]*\).*/\1/p')
inverted=$((inversions % 2))
if [ "$traced_cells" != "$expected_lag" ]; then
  echo "traced chain has $traced_cells cells, expected $expected_lag"
  echo "FAILED"
  exit 1
fi

cat > files.f <<EOF2
+define+USE_POWER_PINS
+define+FUNCTIONAL
+define+VERILATOR=1
$repo/sim/tb/tb_scan_shift.sv
$cell_models/primitives.v
$work/cells.v
$work/sram.v
$work/croc_soc_gls.v
EOF2
verilator --binary -MAKEFLAGS "CXX=$cxx LINK=$cxx" -j "${JOBS:-8}" -Wno-fatal -Wno-lint -Wno-style \
  -Wno-SPECIFYIGN --timing -f files.f --top-module tb_scan_shift -o Vscan > build.log 2>&1 \
  || { echo "verilator build failed, see $work/build.log"; exit 1; }

# Must pass: the normal shift, and the shift with jtag_trst_ni low (testmode_i gates its resets).
# For information only: rst_ni low. The tester holds rst_ni inactive during the shift, and the 800 flops behind the
# reset generator (it passes rst_ni through in test mode) are not gated, so this run disturbs the chain.
failed=0
for case_args in "" "+trstn_low" "+rstn_low"; do
  case_name=$(echo "$case_args" | tr -d "+")
  case_name=${case_name:-normal}
  echo "== run: ${case_args:-defaults}"
  set +e
  # shellcheck disable=SC2086  # case_args is empty or one plusarg
  stdbuf -oL ./obj_dir/Vscan +expected_lag="$expected_lag" +expected_inv=$inverted $case_args 2>&1 \
    | tee "run_$case_name.log" | grep -E "SCAN_SHIFT|Error|error"
  sim_status=${PIPESTATUS[0]}
  set -e
  [ "$case_name" = rstn_low ] && continue
  [ "$sim_status" = 0 ] || failed=1
  grep -q "SCAN_SHIFT_RESULT PASS" "run_$case_name.log" || failed=1
done
if [ $failed = 0 ]; then echo "ALL PASS"; else echo "FAILED"; fi
exit $failed
