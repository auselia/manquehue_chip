#!/bin/bash
# Core-level RTL simulation with Verilator.  Usage: sim/fft/run_core.sh [BACKPRESSURE=0|1]
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RTL="${RTL_DIR:-$ROOT/rtl/user_domain/fft}"
BUILD="$HERE/build/core"
NB=$(wc -l < "$HERE/vectors/names.txt" | tr -d ' ')
BP="${1:-1}"
mkdir -p "$BUILD"
cd "$BUILD"
rm -rf obj
verilator --binary --timing -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
  -GNB=$NB -GVDIR="\"$HERE/vectors\"" -GBACKPRESSURE=$BP \
  --top-module tb_fft_hwpe_core -Mdir obj \
  $RTL/fft_cos_rom.sv $RTL/fft_trig.sv $RTL/fft_window.sv $RTL/fft_pre.sv $RTL/fft_butterfly.sv \
  $RTL/fft_post.sv $RTL/fft_feat.sv $RTL/fft_hwpe_core.sv $HERE/tb/tb_fft_hwpe_core.sv > verilator.log 2>&1 || { echo "verilator failed, see $BUILD/verilator.log"; grep -m5 "%Error" verilator.log; exit 1; }
./obj/Vtb_fft_hwpe_core
