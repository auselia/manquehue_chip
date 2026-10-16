#!/bin/bash
# Gate-level simulation of a run: Verilator (full-SoC testbench, program prints GLS OK), scan shift, and the Icarus
# macro-level JTAG boot test. The chip-level test (pad ring) is part of `make chip`, it needs the chip netlist.
# usage: scripts/gls/run_gls_all.sh      (env: RUN)
set -e
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../utils/env.sh"
step_begin gls
O=$STEP_DIR
HEX=$REPO/sim/sw/gls_mini/gls_mini.hex
nixrun() { ( cd "$TEMPLATE_DIR" && nix-shell --run "$*" ); }
ST=PASS

# a. Verilator, vendor models with 0.5 ns flop delay (see sim/GLS.md)
nixrun "GLS_RUN=$RUN $REPO/sim/scripts/run_gls.sh $HEX $O/verilator" > "$O/verilator.log" 2>&1 || true
L=$(grep -h "GLS OK" "$O/verilator/run.log" 2>/dev/null | head -1)
summary verilator_boot "${L:-no GLS OK}"; [ -n "$L" ] || ST=FAIL

# b. scan shift (0 mismatches, lag = number of scan cells)
nixrun "GLS_RUN=$RUN $REPO/sim/scripts/run_gls_scan.sh $O/scan_shift" > "$O/scan_shift.log" 2>&1 || true
R=$(tail -n 3 "$O/scan_shift.log" | grep -o "ALL PASS\|FAILED" | head -1)
summary scan_shift "${R:-no result}"; [ "$R" = "ALL PASS" ] || ST=FAIL

# c. Icarus, JTAG through the macro ports, program loaded over the debug module, GLS OK on uart_tx_o
nixrun "PROG_HEX=$HEX $HERE/run_macro_gls.sh none $RUN/croc_soc.v $O/icarus_macro" > "$O/icarus_macro.log" 2>&1 || true
P=$(grep -h "PASS: GLS OK" "$O/icarus_macro.log" | head -1)
summary icarus_macro_boot "${P:-no PASS}"; [ -n "$P" ] || ST=FAIL
summary status $ST
