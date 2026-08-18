#!/bin/bash
set -e  # Exit immediately if a command fails

# Resolve repo root from this script's location (sim/scripts -> repo root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Changed build directory and binary name conventions for VCS
BUILD_DIR="$ROOT/sim/build/vcs"
SIM_BIN="$BUILD_DIR/simv"

# Which hex to load. Priority: CLI arg > BIN env > HEX env > helloworld default.
HEX="${1:-${BIN:-${HEX:-$ROOT/sim/sw/hello_world/bin/helloworld.hex}}}"
case "$HEX" in
  /*) ;;                  # already absolute
  *)  HEX="$PWD/$HEX" ;;  # relative -> absolute w.r.t. current shell
esac

# Compile the VCS model unless SKIP_BUILD=1
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "=> Setting up VCS build workspace..."
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  
  echo "=> Compiling cycle-accurate hardware model with VCS..."
  vcs -sverilog -full64 \
    -j 4\
    -F "$ROOT/flists/croc_sim_vcs.flist" \
    -timescale=1ns/1ps \
    -top tb_croc_soc \
    -debug_access+pp \
    -o "$SIM_BIN"
fi

# Stop here if we only wanted to compile
if [ "${BUILD_ONLY:-0}" = "1" ]; then
  echo "=> Build complete (BUILD_ONLY)."
  exit 0
fi

if [ ! -x "$SIM_BIN" ]; then
  echo "ERROR: sim binary not found at $SIM_BIN" >&2
  echo "       Run the build script first to compile it." >&2
  exit 1
fi

echo "=> Running Simulation with: $HEX"
# Run from sim/build so the testbench's default '../sw/bin/...' path also resolves.
cd "$ROOT/sim/build"

# Run the generated simulation executable and pass the plusarg
"$SIM_BIN" +binary="$HEX"
