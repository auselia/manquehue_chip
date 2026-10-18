#!/bin/bash
set -e  # Exit immediately if a command fails

# Resolve repo root from this script's location (scripts/sim -> repo root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BUILD_DIR="$ROOT/sim/build/verilator"
# g++ with -fcoroutines (Verilator --timing). The system g++ 8.5 on Rocky has none, so the default is the
# nix g++ that scripts/sim/run_gls.sh also uses. Override with SIM_CXX. Plain g++ when that path does not exist.
GXX=${SIM_CXX:-/nix/store/vr15iyyykg9zai6fpgvhcgyw7gckl78w-gcc-wrapper-14.3.0/bin/g++}
[ -x "$GXX" ] || GXX=g++
SIM_BIN="$BUILD_DIR/obj_dir/Vtb_croc_soc"

# Which hex to load. Priority: CLI arg > BIN env > HEX env > helloworld default.
HEX="${1:-${BIN:-${HEX:-$ROOT/sim/sw/hello_world/bin/helloworld.hex}}}"
case "$HEX" in
  /*) ;;                  # already absolute
  *)  HEX="$PWD/$HEX" ;;  # relative -> absolute w.r.t. current shell
esac
case "${FLASH:-}" in
  ""|/*) ;;
  *)  FLASH="$PWD/$FLASH" ;;  # relative -> absolute before the script changes directory
esac

# Compile the Verilator model unless SKIP_BUILD=1
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "=> Setting up Verilator build workspace..."
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  echo "=> Compiling cycle-accurate hardware model..."
  # TRACE=1 dumps the waveform (sim/build/croc.fst, tens of GB for a long program)
  verilator --binary -MAKEFLAGS "CXX=$GXX LINK=$GXX" -j 0 -Wno-fatal --trace --trace-structs ${TRACE:+ +define+TRACE_WAVE} \
    -F "$ROOT/flists/croc_sim.flist" \
    --top-module tb_croc_soc
fi

# Stop here if we only wanted to compile
if [ "${BUILD_ONLY:-0}" = "1" ]; then
  echo "=> Build complete (BUILD_ONLY)."
  exit 0
fi

if [ ! -x "$SIM_BIN" ]; then
  echo "ERROR: sim binary not found at $SIM_BIN" >&2
  echo "       Run 'make verilate' (or 'make sim') first to compile it." >&2
  exit 1
fi

# FLASH=<hex>: program in the QSPI flash model (boot from flash, no JTAG load). The hex comes from
# objcopy -O verilog with addresses relative to 0x2000_0000 (sim/sw/flash/build.sh).
if [ -n "${FLASH:-}" ]; then
  echo "=> Running Simulation from the QSPI flash: $FLASH"
  cd "$ROOT/sim/build"
  exec ./verilator/obj_dir/Vtb_croc_soc +flash="$FLASH"
fi

echo "=> Running Simulation with: $HEX"
# Run from sim/build so the testbench's default '../sw/bin/...' path also resolves.
cd "$ROOT/sim/build"
./verilator/obj_dir/Vtb_croc_soc +binary="$HEX"