#!/bin/bash
# KLayout DRC of the GDS of a run
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/pv/drc.sh      (env: RUN or GDS, options in settings.sh)
# in:  <run>/croc_soc.gds
# out: drc/ next to the GDS: the .lyrdb of every deck and drc.log
. "$(dirname "${BASH_SOURCE[0]}")/settings.sh"
need "$GDS" DRC "GDS not found: $GDS. Run make finish first, or set RUN=<run> or GDS=<file>."
need "$DRC_HOME/run_drc.py" DRC "run_drc.py not found in DRC_HOME=$DRC_HOME."
GDS_REAL=$(readlink -f "$GDS"); OUT=$(dirname "$GDS_REAL")/drc
mkdir -p "$OUT"
echo "[DRC] design : $GDS_REAL"
echo "[DRC] stack  : gf180mcu=$GF180MCU_OPT  mode=$DRC_RUN_MODE  extra='$DRC_EXTRA'"
echo "[DRC] results: $OUT"
# The exit status of run_drc.py does not stop the target: the .lyrdb files are the result.
( cd "$OUT" && PDK_ROOT="$DRC_PDK_ROOT" PDK="$DRC_PDK" \
  python3 "$DRC_HOME/run_drc.py" --path="$GDS_REAL" --gf180mcu="$GF180MCU_OPT" --run_mode="$DRC_RUN_MODE" $DRC_EXTRA \
) 2>&1 | tee "$OUT/drc.log"
echo "[DRC] Done. Open the .lyrdb files in KLayout: $OUT/*.lyrdb"
