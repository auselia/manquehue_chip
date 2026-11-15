#!/bin/bash
# KLayout LVS of a run: the SPICE netlist from the gate-level Verilog against the GDS
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/pv/lvs.sh      (env: RUN or GDS and VLOG, options in settings.sh)
# in:  <run>/croc_soc.gds, <run>/croc_soc.v, the standard-cell CDL
# out: lvs/ next to the GDS: croc_soc.sp, the .lvsdb, the extracted netlist, lvs_compare_summary.txt and the logs
. "$(dirname "${BASH_SOURCE[0]}")/settings.sh"
need "$GDS" LVS "GDS not found: $GDS. Run make finish first, or set RUN=<run> or GDS=<file>."
need "$VLOG" LVS "Verilog netlist not found: $VLOG. 06_finish.tcl writes it next to the GDS, or set VLOG=<file>."
need "$LVS_HOME/run_lvs.py" LVS "run_lvs.py not found in LVS_HOME=$LVS_HOME."
need "$LVS_SC_CDL" LVS "standard-cell CDL not found: $LVS_SC_CDL. Set LVS_PDK_KIT to the ciel libs.ref (ciel ls)."
# shellcheck disable=SC2086
fold_cdl LVS "$FOLDED_SC_CDL" $LVS_WELL_TIES $LVS_MODEL_RENAME
set -o pipefail
GDS_REAL=$(readlink -f "$GDS"); VLOG_REAL=$(readlink -f "$VLOG"); OUT=$(dirname "$GDS_REAL")/lvs
mkdir -p "$OUT"
echo "[LVS] design  : $GDS_REAL"
echo "[LVS] netlist : $VLOG_REAL"
echo "[LVS] stack   : gf180mcu=$GF180MCU_OPT  mode=$LVS_RUN_MODE  sub=$LVS_SUB"
echo "[LVS] results : $OUT"
spice LVS "$FOLDED_SC_CDL" "$OUT"
blackbox_gds LVS "$OUT"
echo "[LVS] Running KLayout LVS (GF180MCU)"
# shellcheck disable=SC2086
( cd "$OUT" && PDK_ROOT="$LVS_PDK_ROOT" PDK="$LVS_PDK" \
  python3 "$LVS_HOME/run_lvs.py" --design="$LVS_GDS" --net="$OUT/$TOP.sp" --gf180mcu="$GF180MCU_OPT" \
    --run_mode="$LVS_RUN_MODE" --lvs_sub="$LVS_SUB" $LVS_FLAGS $LVS_EXTRA \
    --blackbox_macros="${LVS_BLACKBOX_CELLS// /,}" --exclude_from_compare="$LVS_EXCLUDE_FROM_COMPARE" \
) 2>&1 | tee "$OUT/lvs.log"
echo "[LVS] Second, independent compare (lvs_compare.rb)"
klayout -b -r "$LVS_HOME/lvs_compare.rb" -rd layout_netlist="$OUT/extracted_netlist_$TOP.cir" \
  -rd schematic_netlist="$OUT/$TOP.sp" -rd device_class_map="$LVS_DEVICE_CLASS_MAP" \
  -rd blackbox_macros="${LVS_BLACKBOX_CELLS// /,}" -rd exclude_from_compare="$LVS_EXCLUDE_FROM_COMPARE" \
  -rd summary="$OUT/lvs_compare_summary.txt" > "$OUT/lvs_compare.log" 2>&1
if grep -q "INFO : Congratulations! Netlists match." "$OUT/lvs.log"; then
  echo "[LVS] MATCH. The result is $OUT/*.lvsdb (KLayout netlist browser). Text summary: lvs_compare_summary.txt."
else
  echo "[LVS] MISMATCH. Open $OUT/*.lvsdb in KLayout to see the circuits, nets and devices that differ."
  echo "[LVS] Text summary: $OUT/lvs_compare_summary.txt."
  exit 1
fi
