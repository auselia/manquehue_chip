#!/bin/bash
# RTL simulation of croc in Verilator with the SoC test bench: build the model, then run a program
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/sim/run_verilator.sh [program.hex]      (make sim, make run)
# in:  env BIN or HEX (the program, default helloworld), FLASH (a flash image: boot from the flash, no JTAG load),
#      SIM_ARGS (more plusargs, for example +adc_tone=36), BUILD_ONLY=1, SKIP_BUILD=1, TRACE=1, SIM_CXX
# out: sim/build/verilator/ (the model), the test bench output on stdout
#
# TRACE=1 dumps the waveform into sim/build/croc.fst: tens of GB for a long program.
set -e
. "$(dirname "${BASH_SOURCE[0]}")/../utils/env.sh"
build_dir=$REPO/sim/build/verilator
model=$build_dir/obj_dir/Vtb_croc_soc

# The program and the flash image as absolute paths: the script changes folder before the run
program=${1:-${BIN:-${HEX:-$REPO/sim/sw/hello_world/bin/helloworld.hex}}}
[[ $program = /* ]] || program=$PWD/$program
flash_image=${FLASH:-}
[ -z "$flash_image" ] || [[ $flash_image = /* ]] || flash_image=$PWD/$flash_image

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  echo "=> Compiling the Verilator model in $build_dir"
  mkdir -p "$build_dir"
  cd "$build_dir"
  verilator --binary -MAKEFLAGS "CXX=$SIM_CXX LINK=$SIM_CXX" -j 0 -Wno-fatal --trace --trace-structs \
    ${TRACE:+ +define+TRACE_WAVE} -F "$REPO/flists/croc_sim.flist" --top-module tb_croc_soc
fi
if [ "${BUILD_ONLY:-0}" = 1 ]; then
  echo "=> Build complete (BUILD_ONLY)."
  exit 0
fi
need "$model" SIM "no Verilator model in $build_dir. Run make verilate (or make sim) first."

# The test bench runs from sim/build, so its default program path ../sw/... resolves too
cd "$REPO/sim/build"
# shellcheck disable=SC2086  # SIM_ARGS is a list of plusargs
if [ -n "$flash_image" ]; then
  echo "=> Running Simulation from the QSPI flash: $flash_image"
  exec "$model" +flash="$flash_image" ${SIM_ARGS:-}
fi
echo "=> Running Simulation with: $program"
# shellcheck disable=SC2086
"$model" +binary="$program" ${SIM_ARGS:-}
