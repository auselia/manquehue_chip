#!/bin/bash
# IC Validator DRC of the GDS of a run, with the decks of ICV_PDK_HOME
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/pv/drc_icv.sh      (env: RUN or GDS, options in settings.sh)
# in:  <run>/croc_soc.gds
# out: drc_icv/ next to the GDS: croc_soc.RESULTS, croc_soc.vue and drc_icv.log
. "$(dirname "${BASH_SOURCE[0]}")/settings.sh"
need "$GDS" DRC-ICV "GDS not found: $GDS. Run make finish first, or set RUN=<run> or GDS=<file>."
need "$ICV_HOME_DIR/bin/icv" DRC-ICV "icv not found in ICV_HOME_DIR=$ICV_HOME_DIR."
need "$ICV_DRC_RUNSET" DRC-ICV "runset not found: $ICV_DRC_RUNSET. Set ICV_PDK_HOME or ICV_DRC_RUNSET."
set -o pipefail
ICV_BIN=$ICV_HOME_DIR/bin
GDS_REAL=$(readlink -f "$GDS"); OUT=$(dirname "$GDS_REAL")/drc_icv
mkdir -p "$OUT"
echo "[DRC-ICV] design : $GDS_REAL"
echo "[DRC-ICV] runset : $ICV_DRC_RUNSET"
echo "[DRC-ICV] stack  : BEOL_STACK=$ICV_BEOL_STACK TOPMETAL=$ICV_TOPMETAL MIMCAP=$ICV_MIMCAP PADBONDING=$ICV_PADBONDING"
echo "[DRC-ICV] results: $OUT"
CFG=(); [ -n "$ICV_RUNSET_CONFIG" ] && CFG=(-runset_config "$REPO/$ICV_RUNSET_CONFIG")
# shellcheck disable=SC2086
( cd "$OUT" && PATH="$ICV_BIN:$PATH" ICV_HOME_DIR="${ICV_BIN%/bin}" \
  BEOL_STACK="$ICV_BEOL_STACK" TOPMETAL="$ICV_TOPMETAL" MIMCAP_SELECTION="$ICV_MIMCAP" PADBONDING="$ICV_PADBONDING" \
  LATCH_CHECK="$ICV_LATCH_CHECK" \
  icv -f gdsii -c "$TOP" -i "$GDS_REAL" -vue "${CFG[@]}" -host_init "$ICV_HOST_INIT" $ICV_DRC_EXTRA "$ICV_DRC_RUNSET" \
) 2>&1 | tee "$OUT/drc_icv.log" || exit
echo "[DRC-ICV] Done. Summary: $OUT/$TOP.RESULTS. Violations: open $OUT/$TOP.vue in VUE."
