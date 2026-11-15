#!/bin/bash
# IC Validator LVS of a run, with the same SPICE netlist and black boxes as the KLayout LVS (no model rename)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/pv/lvs_icv.sh      (env: RUN or GDS and VLOG, options in settings.sh)
# in:  <run>/croc_soc.gds, <run>/croc_soc.v, the standard-cell CDL
# out: lvs_icv/ next to the GDS: croc_soc.sp, croc_soc.RESULTS, croc_soc.vue and the logs
. "$(dirname "${BASH_SOURCE[0]}")/settings.sh"
need "$GDS" LVS-ICV "GDS not found: $GDS. Run make finish first, or set RUN=<run> or GDS=<file>."
need "$VLOG" LVS-ICV "Verilog netlist not found: $VLOG. 06_finish.tcl writes it next to the GDS, or set VLOG=<file>."
need "$ICV_HOME_DIR/bin/icv" LVS-ICV "icv not found in ICV_HOME_DIR=$ICV_HOME_DIR."
need "$ICV_LVS_RUNSET" LVS-ICV "runset not found: $ICV_LVS_RUNSET. Set ICV_PDK_HOME or ICV_LVS_RUNSET."
need "$LVS_HOME/verilog2spice.py" LVS-ICV "verilog2spice.py not found in LVS_HOME=$LVS_HOME."
need "$LVS_HOME/fold_wells.py" LVS-ICV "fold_wells.py not found in LVS_HOME=$LVS_HOME."
need "$LVS_SC_CDL" LVS-ICV "standard-cell CDL not found: $LVS_SC_CDL. Set LVS_PDK_KIT to the ciel libs.ref (ciel ls)."
# shellcheck disable=SC2086
fold_cdl LVS-ICV "$FOLDED_SC_CDL_ICV" $LVS_WELL_TIES
set -o pipefail
ICV_BIN=$ICV_HOME_DIR/bin
GDS_REAL=$(readlink -f "$GDS"); VLOG_REAL=$(readlink -f "$VLOG"); OUT=$(dirname "$GDS_REAL")/lvs_icv
mkdir -p "$OUT"
echo "[LVS-ICV] design  : $GDS_REAL"
echo "[LVS-ICV] netlist : $VLOG_REAL"
echo "[LVS-ICV] runset  : $ICV_LVS_RUNSET"
echo "[LVS-ICV] stack   : BEOL_STACK=$ICV_BEOL_STACK"
echo "[LVS-ICV] results : $OUT"
spice LVS-ICV "$FOLDED_SC_CDL_ICV" "$OUT"
blackbox_gds LVS-ICV "$OUT"
echo "[LVS-ICV] Running IC Validator LVS (GF180MCU)"
CFG=(); [ -n "$ICV_RUNSET_CONFIG" ] && CFG=(-runset_config "$REPO/$ICV_RUNSET_CONFIG")
# shellcheck disable=SC2086
( cd "$OUT" && PATH="$ICV_BIN:$PATH" ICV_HOME_DIR="${ICV_BIN%/bin}" ICV_LVS="$ICV_LVS_HOME" \
  BEOL_STACK="$ICV_BEOL_STACK" \
  icv -f gdsii -c "$TOP" -i "$LVS_GDS" -s "$OUT/$TOP.sp" -sf SPICE -vue "${CFG[@]}" -host_init "$ICV_HOST_INIT" \
    $ICV_LVS_EXTRA "$ICV_LVS_RUNSET" \
) 2>&1 | tee "$OUT/lvs_icv.log"
if grep -q "LVS Compare Result: PASS" "$OUT/$TOP.RESULTS" 2>/dev/null; then
  echo "[LVS-ICV] MATCH. Summary: $OUT/$TOP.RESULTS. Compare tree: open $OUT/$TOP.vue in VUE."
else
  echo "[LVS-ICV] MISMATCH, or the run failed. Summary: $OUT/$TOP.RESULTS. Differences: open $OUT/$TOP.vue in VUE."
  exit 1
fi
