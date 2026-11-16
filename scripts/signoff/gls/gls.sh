#!/bin/bash
# Gate-level simulation checks of a run: Verilator boot over JTAG and from the QSPI flash, scan shift, Icarus macro
# boot over JTAG, and the same boot in VCS with the SDF delays of PrimeTime (min and max)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/gls/gls.sh      (env: RUN)
# in:  <run>/croc_soc.v, <run>/logs/synthesis.log (scan cells), <run>/sta_pt/croc_soc.typical.sdf, sim/sw programs
# out: <run>/checks/gls/: summary.txt and one folder and log per test
#
# The chip-level test through the pads is in waferspace_manquehue: it needs the chip netlist.
set -e
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../../utils/env.sh"
step_begin gls
out=$STEP_DIR
status=PASS

# nixrun <command>: run a command in the nix-shell of the wafer.space template (Verilator, Icarus)
nixrun() {
  ( cd "$TEMPLATE_DIR" && nix-shell --run "$*" )
}

# The programs, built from source: gls_mini prints GLS OK and fits the 2 KB SRAM, flash_hello runs from the flash
program=$REPO/sim/sw/gls_mini/bin/gls_mini.hex
flash_program=$REPO/sim/sw/flash/bin/flash_hello.flash.hex
"$REPO/scripts/sim/build_sw.sh" gls_mini > "$out/gls_mini_build.log" 2>&1 || true
"$REPO/sim/sw/flash/build.sh" > "$out/flash_build.log" 2>&1 || true

# Verilator: boot over JTAG
nixrun "GLS_RUN=$RUN $here/verilator.sh $program $out/verilator" > "$out/verilator.log" 2>&1 || true
result=$(grep -h "GLS OK" "$out/verilator/run.log" 2>/dev/null | head -1)
summary verilator_boot "${result:-no GLS OK}"
[ -n "$result" ] || status=FAIL

# Verilator: boot from the QSPI flash. The bootrom finds the image and runs it from the flash model, no JTAG load.
result=""
if [ -f "$flash_program" ]; then
  nixrun "GLS_RUN=$RUN GLS_PLUSARGS=+flash=$flash_program $here/verilator.sh $program $out/flash_boot" \
    > "$out/flash_boot.log" 2>&1 || true
  result=$(grep -h "FLASH OK" "$out/flash_boot/run.log" 2>/dev/null | head -1)
fi
summary flash_boot "${result:-no FLASH OK}"
[ -n "$result" ] || status=FAIL

# Scan shift: the stream comes out of the chain delayed by the number of scan cells that synthesis traced
scan_cells=$(zcat -f "$RUN"/logs/synthesis.log* 2>/dev/null | grep -o "successfully traced with [0-9]* scan_cells" \
  | grep -o "[0-9]*" | tail -1)
result=""
if [ -n "$scan_cells" ]; then
  nixrun "EXPECTED_LAG=$scan_cells GLS_RUN=$RUN $here/scan_shift.sh $out/scan_shift" > "$out/scan_shift.log" 2>&1 || true
  result=$(tail -n 3 "$out/scan_shift.log" | grep -o "ALL PASS\|FAILED" | head -1)
fi
summary scan_shift "${result:-no result (no scan cell count in the synthesis log)}"
[ "$result" = "ALL PASS" ] || status=FAIL

# Icarus: JTAG through the macro ports, program loaded over the debug module, GLS OK on uart_tx_o
nixrun "PROG_HEX=$program $here/icarus_macro.sh $RUN/croc_soc.v $out/icarus_macro" > "$out/icarus_macro.log" 2>&1 || true
result=$(grep -h "PASS: GLS OK" "$out/icarus_macro.log" | head -1)
summary icarus_macro_boot "${result:-no PASS}"
[ -n "$result" ] || status=FAIL

# VCS: the same boot with the typical SDF of make sta-pt, at its min and its max values, timing checks on.
# PASS needs GLS OK and 0 timing violations. Icarus cannot do this: it reads the typical value of an SDF triple,
# PrimeTime leaves it empty, and Icarus keeps the 1 ns default of the cell models without a message.
sdf=$RUN/sta_pt/croc_soc.typical.sdf
if [ -f "$sdf" ]; then
  for delays in min max; do
    log=$out/vcs_macro_sdf_$delays.log
    PROG_HEX=$program "$here/vcs_sdf.sh" "$RUN/croc_soc.v" "$sdf" $delays "$out/vcs_macro_sdf_$delays" > "$log" 2>&1 || true
    result=$(grep -h "PASS: GLS OK" "$log" | head -1)
    violations=$(grep -h "^timing violations:" "$log" | grep -o "[0-9]*" | head -1)
    summary vcs_macro_boot_sdf_$delays "${result:-no PASS}, timing violations: ${violations:-?}"
    [ -n "$result" ] && [ "$violations" = 0 ] || status=FAIL
  done
else
  summary vcs_macro_boot_sdf "not run (no SDF, run make sta-pt)"
fi
summary status $status
