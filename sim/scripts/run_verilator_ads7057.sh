#!/bin/bash
# Verilator run script for tb_ads7057 (ADS7057 SPI-transaction verification
# against ads7057_model.sv). Clone of run_verilator.sh with the top module
# and default binary swapped -- see that file for the general flow.
set -e  # Exit immediately if a command fails

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BUILD_DIR="$ROOT/sim/build/verilator_ads7057"
SIM_BIN="$BUILD_DIR/obj_dir/Vtb_ads7057"

HEX="${1:-${BIN:-${HEX:-$ROOT/sim/sw/ads7057_test/bin/main.hex}}}"
case "$HEX" in
  /*) ;;
  *)  HEX="$PWD/$HEX" ;;
esac

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "=> Setting up Verilator build workspace..."
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  echo "=> Compiling cycle-accurate hardware model..."
  verilator --binary -j 0 -Wno-fatal --trace --trace-structs \
    -F "$ROOT/flists/croc_sim.flist" \
    --top-module tb_ads7057
fi

if [ "${BUILD_ONLY:-0}" = "1" ]; then
  echo "=> Build complete (BUILD_ONLY)."
  exit 0
fi

if [ ! -x "$SIM_BIN" ]; then
  echo "ERROR: sim binary not found at $SIM_BIN" >&2
  echo "       Run this script without SKIP_BUILD=1 first to compile it." >&2
  exit 1
fi

echo "=> Running Simulation with: $HEX"
cd "$ROOT/sim/build"
"$BUILD_DIR/obj_dir/Vtb_ads7057" +binary="$HEX"
