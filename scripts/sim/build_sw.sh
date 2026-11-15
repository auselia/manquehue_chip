#!/bin/bash
# Builds the croc_soc programs of sim/sw: a Makefile program with make, the others with their build.sh
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/sim/build_sw.sh [program ...]      (default: all; env RISCV_PREFIX, default riscv32-none-elf-)
#        scripts/sim/build_sw.sh clean [program ...]
# in:  sim/sw/<program>/ and the library sim/sw/lib/
# out: sim/sw/<program>/bin/. Exit 1 when a program does not build.
SW=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../sim/sw" && pwd)
export RISCV_PREFIX=${RISCV_PREFIX:-riscv32-none-elf-}
CLEAN=0; [ "$1" = clean ] && { CLEAN=1; shift; }
if [ $# -eq 0 ]; then
  set -- $(cd "$SW" && for d in */; do d=${d%/}; [ -f "$d/Makefile" ] || [ -f "$d/build.sh" ] && echo "$d"; done)
fi
FAILED=()
for p in "$@"; do
  d=$SW/$p
  if [ "$CLEAN" = 1 ]; then rm -rf "$d/bin" "$d/build"; continue; fi
  if [ -f "$d/Makefile" ]; then
    make -s -C "$d" RISCV_PREFIX="$RISCV_PREFIX" || FAILED+=("$p")
  elif [ -f "$d/build.sh" ]; then
    # fpga_bringup builds one bring-up step per call (see its README)
    [ "$p" = fpga_bringup ] && { echo "[SW] $p: build its steps with sim/sw/fpga_bringup/build.sh <step>"; continue; }
    bash "$d/build.sh" > /dev/null || FAILED+=("$p")
  else
    echo "[SW] no program: $p"; FAILED+=("$p")
  fi
done
[ ${#FAILED[@]} -eq 0 ] || { echo "[SW] FAILED: ${FAILED[*]}"; exit 1; }
