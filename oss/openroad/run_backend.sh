#!/bin/bash
# Open-flow back end of croc_soc (OpenROAD). usage: run_backend.sh [floorplan|placement|cts|routing|all]
# Run inside the nix shell of oss/ (nix develop path:$PWD); the netlist comes from ../yosys/out.
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../env.sh
mkdir -p logs
stage() { echo "== $1 $(date +%T)"; openroad -no_splash -exit scripts/$1.tcl 2>&1 | tee logs/$1.log | grep -E "^\[ERROR|^Error|ERROR:" | head -5; }
case "${1:-all}" in
  floorplan) stage 01_floorplan ;;
  placement) stage 02_placement ;;
  cts)       stage 03_cts ;;
  routing)   stage 04_routing ;;
  all)       stage 01_floorplan; stage 02_placement; stage 03_cts; stage 04_routing ;;
esac
echo "== done $(date +%T)"
