#!/bin/bash
# Bus-level RTL test of the FFT accelerator (fft_hwpe) in Verilator, against the vectors of the bit-exact model
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: sim/fft/run_bus.sh [response latency, default 2] [random grant 0|1, default 1]
# in:  rtl/user_domain/fft/, sim/fft/vectors/, env RTL_DIR, TB_FILE, SIM_CXX
# out: sim/build/fft_bus/verilator.log, the test bench output on stdout (PASS or FAIL)
set -e
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../../scripts/utils/env.sh"
rtl=${RTL_DIR:-$REPO/rtl/user_domain/fft}
build=$REPO/sim/build/fft_bus
response_latency=${1:-2}
random_grant=${2:-1}
blocks=$(wc -l < "$here/vectors/names.txt" | tr -d ' ')

mkdir -p "$build"
cd "$build"
rm -rf obj
verilator --binary --timing -MAKEFLAGS "CXX=$SIM_CXX LINK=$SIM_CXX" -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
  -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-PROCASSINIT -Wno-SYNCASYNCNET -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  +incdir+"$REPO/rtl/obi/include" \
  -GNB="$blocks" -GVDIR="\"$here/vectors\"" -GRSP_LAT="$response_latency" -GRANDOM_GNT="$random_grant" \
  --top-module tb_fft_hwpe -Mdir obj \
  "$REPO/rtl/obi/obi_pkg.sv" "$REPO/rtl/common_cells/cf_math_pkg.sv" "$REPO/rtl/croc_pkg.sv" \
  "$rtl/fft_cos_rom.sv" "$rtl/fft_trig.sv" "$rtl/fft_hwpe_core.sv" "$rtl/fft_hwpe_regs.sv" "$rtl/fft_hwpe.sv" \
  "${TB_FILE:-$here/tb/tb_fft_hwpe.sv}" > verilator.log 2>&1 \
  || { echo "verilator failed, see $build/verilator.log"; grep -m5 "%Error" verilator.log; exit 1; }
./obj/Vtb_fft_hwpe
