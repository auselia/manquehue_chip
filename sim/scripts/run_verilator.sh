#!/bin/bash
set -e  # Exit immediately if a command fails

# Resolve repo root from this script's location (sim/scripts -> repo root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BUILD_DIR="$ROOT/sim/build/verilator"
SIM_BIN="$BUILD_DIR/obj_dir/Vtb_croc_soc"

# Which hex to load. Priority: CLI arg > BIN env > HEX env > helloworld default.
HEX="${1:-${BIN:-${HEX:-$ROOT/sim/sw/hello_world/bin/helloworld.hex}}}"
case "$HEX" in
  /*) ;;                  # already absolute
  *)  HEX="$PWD/$HEX" ;;  # relative -> absolute w.r.t. current shell
esac

# Compile the Verilator model unless SKIP_BUILD=1
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "=> Setting up Verilator build workspace..."
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  echo "=> Compiling cycle-accurate hardware model..."
  verilator --binary -j 0 -Wno-fatal --trace --trace-structs \
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

echo "=> Running Simulation with: $HEX"
# Run from sim/build so the testbench's default '../sw/bin/...' path also resolves.
cd "$ROOT/sim/build"
./verilator/obj_dir/Vtb_croc_soc +binary="$HEX"