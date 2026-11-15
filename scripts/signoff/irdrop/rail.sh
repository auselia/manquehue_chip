#!/bin/bash
# RedHawk-SC voltage drop of the finish block in work/design.dlib (analyze_rail.tcl in Fusion Compiler)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/irdrop/rail.sh      (env: RAIL_VOLTAGE_DROP and the RAIL_* variables below)
# in:  work/design.dlib (block finish), the ITF of RAIL_TECH_FILE
# out: outputs/latest/rail_rh/: voltage_drop.<mode>.rpt, rail.<mode>.log and the rail database
. "$(dirname "${BASH_SOURCE[0]}")/../../utils/env.sh"
# It opens the block, not an archived run, and saves nothing. create_taps -top_pg takes the top-level VDD and VSS
# pins as the ideal supply, so the result shows if those pins are enough. RedHawk-SC is in the IC Validator install
# (pfsc/linux/bin/redhawk_sc, license SNPS_INDESIGN_RH_RAIL).
RAIL_PRODUCT=${RAIL_PRODUCT-redhawk_sc}
RAIL_REDHAWK_PATH=${RAIL_REDHAWK_PATH-$ICV_HOME_DIR/pfsc/linux/bin}
# static works (worst drop 0.21 % at the 6 VDD and 6 VSS pins). dynamic_vectorless solves, but report_rail_result
# gives no values per pin (RAIL-1120). The cause is not known.
RAIL_VOLTAGE_DROP=${RAIL_VOLTAGE_DROP-static}
# R and C of every layer (RAIL-300). This RedHawk-SC takes itf, ircx or nrc, not atf. gf180mcu.itf comes from the PDK
# nxtgrd (StarRC grdgenxo -nxtgrd2itf) with the LEF layer names (see its header). grdgenxo needs libnsl on Rocky.
RAIL_TECH_FILE=${RAIL_TECH_FILE-scripts/signoff/irdrop/tech/gf180mcu.itf}
cd "$REPO" || exit 1
command -v fc_shell > /dev/null || { echo "[RAIL] ERROR: fc_shell not found on PATH."; exit 1; }
[ -e work/design.dlib/finish ] || { echo "[RAIL] ERROR: no block finish in work/design.dlib. Run make finish first."; exit 1; }
[ -x "$RAIL_REDHAWK_PATH/redhawk_sc" ] || { echo "[RAIL] ERROR: redhawk_sc not found in RAIL_REDHAWK_PATH=$RAIL_REDHAWK_PATH."; exit 1; }
[ -n "$RAIL_TECH_FILE" ] && [ -e "$RAIL_TECH_FILE" ] || { echo "[RAIL] ERROR: RAIL_TECH_FILE not found: '$RAIL_TECH_FILE'."; exit 1; }
set -o pipefail
OUT=outputs/latest/rail_rh
mkdir -p "$OUT"
TECH=$(readlink -f "$RAIL_TECH_FILE"); OUT_REAL=$(readlink -f "$OUT")
echo "[RAIL] design    : $TOP (block finish, work/design.dlib)"
echo "[RAIL] product   : $RAIL_PRODUCT"
echo "[RAIL] tech_file : $TECH"
echo "[RAIL] mode      : $RAIL_VOLTAGE_DROP"
echo "[RAIL] results   : $OUT"
cd work && fc_shell -batch -x "set TOP $TOP; set REPORT_DIR $OUT_REAL; set RAIL_PRODUCT $RAIL_PRODUCT;
  set RAIL_REDHAWK_PATH $RAIL_REDHAWK_PATH; set RAIL_TECH_FILE $TECH; set RAIL_VOLTAGE_DROP $RAIL_VOLTAGE_DROP;
  source ../scripts/signoff/irdrop/analyze_rail.tcl; exit" 2>&1 | tee "$OUT_REAL/rail.$RAIL_VOLTAGE_DROP.log"
echo "[RAIL] Full report: $OUT/voltage_drop.$RAIL_VOLTAGE_DROP.rpt"
