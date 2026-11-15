#!/bin/bash
# IC Validator metal fill of the GDS of a run (croc_metal_fill.rs), into a new GDS
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/pv/fill_icv.sh      (env: RUN or GDS, options in settings.sh)
# in:  <run>/croc_soc.gds
# out: fill_icv/filled.gds next to the GDS, and fill_icv.log. The GDS of the run does not change.
. "$(dirname "${BASH_SOURCE[0]}")/settings.sh"
need "$GDS" FILL-ICV "GDS not found: $GDS. Run make finish first, or set RUN=<run> or GDS=<file>."
need "$ICV_HOME_DIR/bin/icv" FILL-ICV "icv not found in ICV_HOME_DIR=$ICV_HOME_DIR."
need "$REPO/$ICV_FILL_RUNSET" FILL-ICV "runset not found: $ICV_FILL_RUNSET."
need "$ICV_FILL_INCLUDE_DIR" FILL-ICV "include folder not found: $ICV_FILL_INCLUDE_DIR. Set ICV_PDK_HOME or ICV_FILL_INCLUDE_DIR."
set -o pipefail
ICV_BIN=$ICV_HOME_DIR/bin
GDS_REAL=$(readlink -f "$GDS"); OUT=$(dirname "$GDS_REAL")/fill_icv
mkdir -p "$OUT"
echo "[FILL-ICV] design : $GDS_REAL"
echo "[FILL-ICV] runset : $ICV_FILL_RUNSET"
echo "[FILL-ICV] results: $OUT"
# shellcheck disable=SC2086
( cd "$OUT" && PATH="$ICV_BIN:$PATH" ICV_HOME_DIR="${ICV_BIN%/bin}" \
  icv -f gdsii -c "$TOP" -i "$GDS_REAL" -I "$ICV_FILL_INCLUDE_DIR" -host_init "$ICV_HOST_INIT" $ICV_FILL_EXTRA \
    "$REPO/$ICV_FILL_RUNSET" \
) 2>&1 | tee "$OUT/fill_icv.log"
need "$OUT/filled.gds" FILL-ICV "filled.gds was not written. See $OUT/fill_icv.log."
echo "[FILL-ICV] Done. Filled GDS: $OUT/filled.gds"
echo "[FILL-ICV] Density check: make drc GDS=$OUT/filled.gds DRC_EXTRA=--density_only"
