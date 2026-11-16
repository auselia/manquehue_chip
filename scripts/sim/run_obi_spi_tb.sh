#!/bin/bash
# Block test bench of the SPI block (sim/tb/tb_obi_spi.sv) in Verilator, after a lint run of the block
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/sim/run_obi_spi_tb.sh [work dir]      (default sim/build/obi_spi_tb; make sim-spi)
# in:  rtl/user_domain/spi/, sim/models/ads7057_model.v and sx1276_model.v, env SIM_CXX
# out: <work dir>/lint.log, build.log, sim.log. Exit 1 when the test bench does not print PASS.
set -e
. "$(dirname "${BASH_SOURCE[0]}")/../utils/env.sh"
work=${1:-$REPO/sim/build/obi_spi_tb}
mkdir -p "$work"
cd "$work"

includes=(+incdir+"$REPO/rtl/common_cells/include" +incdir+"$REPO/rtl/obi/include")
packages=("$REPO/rtl/common_cells/cf_math_pkg.sv" "$REPO/rtl/obi/obi_pkg.sv" "$REPO/rtl/croc_pkg.sv" "$REPO/rtl/user_pkg.sv")
# the library cells of the block (the generic clock cells: no TARGET_GF180 here)
cells=("$REPO/rtl/tech_cells_generic/tc_clk.sv" "$REPO/rtl/common_cells/sync.sv" "$REPO/rtl/common_cells/fifo_v3.sv")
spi=$REPO/rtl/user_domain/spi
block=("$spi/obi_spi_pkg.sv" "$spi/obi_spi_regs.sv" "$spi/obi_spi_clk_gate.sv" "$spi/adc_rdr.sv" "$spi/rf_spi.sv" "$spi/obi_spi.sv")

# Lint with all warnings on. Only the SPI files count, the packages are context.
verilator --lint-only -Wall "${includes[@]}" "${packages[@]}" "${cells[@]}" "${block[@]}" "$REPO/sim/tb/obi_spi_lint_top.sv" \
  --top-module obi_spi_lint_top > lint.log 2>&1 || true
if grep -E "%(Warning|Error)" lint.log | grep -q "rtl/user_domain/spi"; then
  grep -E "%(Warning|Error)" lint.log | grep "rtl/user_domain/spi" | head -20
  echo "lint: FAIL, see $work/lint.log"
elif grep "%Error" lint.log | grep -vq "Exiting due to"; then
  grep "%Error" lint.log | grep -v "Exiting due to" | head -5
  echo "lint: FAIL (did not elaborate), see $work/lint.log"
else
  echo "lint: clean (no warnings in rtl/user_domain/spi)"
fi

verilator --binary --timing --timescale 1ns/1ps -MAKEFLAGS "CXX=$SIM_CXX LINK=$SIM_CXX" -j 0 -Wno-fatal -Wno-lint -Wno-style \
  "${includes[@]}" "${packages[@]}" "${cells[@]}" "${block[@]}" \
  "$REPO/sim/models/ads7057_model.v" "$REPO/sim/models/sx1276_model.v" "$REPO/sim/tb/tb_obi_spi.sv" \
  --top-module tb_obi_spi -o Vtb_obi_spi > build.log 2>&1 \
  || { tail -20 build.log; echo "build FAIL, see $work/build.log"; exit 1; }
./obj_dir/Vtb_obi_spi | tee sim.log | grep -E "PASS|FAIL"
grep -q "^PASS" sim.log
