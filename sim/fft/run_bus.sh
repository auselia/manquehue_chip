#!/bin/bash
# Bus-level RTL simulation of fft_hwpe with Verilator.  Usage: sim/fft/run_bus.sh [RSP_LAT=2] [RANDOM_GNT=1]
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RTL="${RTL_DIR:-$ROOT/rtl/user_domain/fft}"
BUILD="$HERE/build/bus"
NB=$(wc -l < "$HERE/vectors/names.txt" | tr -d ' ')
LAT="${1:-2}"
RG="${2:-1}"
# g++ with -fcoroutines (Verilator --timing), as in scripts/sim/run_verilator.sh. SIM_CXX overrides it.
GXX=${SIM_CXX:-/nix/store/vr15iyyykg9zai6fpgvhcgyw7gckl78w-gcc-wrapper-14.3.0/bin/g++}
[ -x "$GXX" ] || GXX=g++
mkdir -p "$BUILD"
cd "$BUILD"
rm -rf obj
verilator --binary --timing -MAKEFLAGS "CXX=$GXX LINK=$GXX" -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
  -Wno-PROCASSINIT -Wno-SYNCASYNCNET -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  +incdir+$ROOT/rtl/obi/include \
  -GNB=$NB -GVDIR="\"$HERE/vectors\"" -GRSP_LAT=$LAT -GRANDOM_GNT=$RG \
  --top-module tb_fft_hwpe -Mdir obj \
  $ROOT/rtl/obi/obi_pkg.sv $ROOT/rtl/common_cells/cf_math_pkg.sv $ROOT/rtl/croc_pkg.sv \
  $RTL/fft_cos_rom.sv $RTL/fft_trig.sv $RTL/fft_hwpe_core.sv $RTL/fft_hwpe_regs.sv \
  $RTL/fft_hwpe.sv ${TB_FILE:-$HERE/tb/tb_fft_hwpe.sv} > verilator.log 2>&1 || { echo "verilator failed, see $BUILD/verilator.log"; grep -m5 "%Error" verilator.log; exit 1; }
./obj/Vtb_fft_hwpe
