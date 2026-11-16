#!/bin/bash
# RTL simulation of croc in VCS with the SoC test bench: build the model, then run a program
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/sim/run_vcs.sh [program.hex]      (make sim-vcs, make run-vcs)
# in:  env BIN or HEX (the program, default helloworld), BUILD_ONLY=1, SKIP_BUILD=1
# out: sim/build/vcs/simv, the test bench output on stdout
set -e
. "$(dirname "${BASH_SOURCE[0]}")/../utils/env.sh"
build_dir=$REPO/sim/build/vcs
model=$build_dir/simv

program=${1:-${BIN:-${HEX:-$REPO/sim/sw/hello_world/bin/helloworld.hex}}}
[[ $program = /* ]] || program=$PWD/$program

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  echo "=> Compiling the VCS model in $build_dir"
  mkdir -p "$build_dir"
  cd "$build_dir"
  vcs -sverilog -full64 -j 4 -F "$REPO/flists/croc_sim_vcs.flist" -timescale=1ns/1ps -top tb_croc_soc \
    -debug_access+pp -o "$model"
fi
if [ "${BUILD_ONLY:-0}" = 1 ]; then
  echo "=> Build complete (BUILD_ONLY)."
  exit 0
fi
need "$model" SIM "no VCS model in $build_dir. Run make vcs-compile (or make sim-vcs) first."

echo "=> Running Simulation with: $program"
cd "$REPO/sim/build"
"$model" +binary="$program"
