#!/bin/bash
# Block testbench of the SPI block (sim/tb/tb_obi_spi.sv) in Verilator, with a lint run of the block first.
# Needs verilator (the template's nix-shell on Rocky).
# usage: scripts/sim/run_obi_spi_tb.sh [work dir]   (default build/obi_spi_tb)
#        SIM_CXX   g++ with -fcoroutines (see scripts/sim/run_verilator.sh)
set -e
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
W=${1:-$REPO/build/obi_spi_tb}
GXX=${SIM_CXX:-/nix/store/vr15iyyykg9zai6fpgvhcgyw7gckl78w-gcc-wrapper-14.3.0/bin/g++}
[ -x "$GXX" ] || GXX=g++
mkdir -p "$W"
cd "$W"

INC="+incdir+$REPO/rtl/common_cells/include +incdir+$REPO/rtl/obi/include"
PKGS="$REPO/rtl/common_cells/cf_math_pkg.sv $REPO/rtl/obi/obi_pkg.sv $REPO/rtl/croc_pkg.sv $REPO/rtl/user_pkg.sv"
# library cells the block uses (generic clock cells: no TARGET_GF180 here)
LIBS="$REPO/rtl/tech_cells_generic/tc_clk.sv $REPO/rtl/common_cells/sync.sv $REPO/rtl/common_cells/fifo_v3.sv"
D=$REPO/rtl/user_domain/spi
SPI="$D/obi_spi_pkg.sv $D/obi_spi_regs.sv $D/obi_spi_clk_gate.sv $D/adc_rdr.sv $D/obi_spi.sv"

# 1. lint of the block (all warnings on, only the SPI files are checked, the packages are context)
verilator --lint-only -Wall $INC $PKGS $LIBS $SPI "$REPO/sim/tb/obi_spi_lint_top.sv" \
  --top-module obi_spi_lint_top > lint.log 2>&1 || true
if grep -E "%(Warning|Error)" lint.log | grep -q "rtl/user_domain/spi"; then
  grep -E "%(Warning|Error)" lint.log | grep "rtl/user_domain/spi" | head -20
  echo "lint: FAIL, see $W/lint.log"
elif grep "%Error" lint.log | grep -vq "Exiting due to"; then
  grep "%Error" lint.log | grep -v "Exiting due to" | head -5
  echo "lint: FAIL (did not elaborate), see $W/lint.log"
else
  echo "lint: clean (no warnings in rtl/user_domain/spi)"
fi

# 2. testbench
verilator --binary --timing --timescale 1ns/1ps -MAKEFLAGS "CXX=$GXX LINK=$GXX" -j 0 -Wno-fatal -Wno-lint -Wno-style \
  $INC $PKGS $LIBS $SPI \
  "$REPO/sim/models/ads7057_model.v" "$REPO/sim/models/sx1276_model.v" "$REPO/sim/tb/tb_obi_spi.sv" \
  --top-module tb_obi_spi -o Vtb_obi_spi > build.log 2>&1 \
  || { tail -20 build.log; echo "build FAIL, see $W/build.log"; exit 1; }
./obj_dir/Vtb_obi_spi | tee sim.log | grep -E "PASS|FAIL"
grep -q "^PASS" sim.log
