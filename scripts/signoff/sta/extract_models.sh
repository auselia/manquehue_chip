#!/bin/bash
# scripts/signoff/sta/extract_models.sh -- PrimeTime timing models (slow, typical, fast) of a finished run.
#
# Runs scripts/signoff/sta/extract_model_corner.tcl once per corner, in parallel, against the 55 ns signoff
# SDC and the matching SPEF of the run, and writes <run>/etm/<TOP>_<corner>.lib. The wafer.space
# template points at these files so the chip-level STA can time through the hard macro.
#
# usage: scripts/signoff/sta/extract_models.sh [run folder]   (default: outputs/latest)
# PT's "1 error" in each log (PT-063, Library Compiler path not set) is only the optional .db step.
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
L="$(readlink -f "${1:-$REPO/outputs/latest}")"
OUT="$L/etm"; mkdir -p "$OUT"
eval "$(python3 "$REPO/scripts/lib/config.py" sh)"
DB="${PT_PDK_DB_DIR:-$HOME/pdk_synopsys/db}"
SRAM="$REPO/outputs/.cache/$SRAM_LIB.db"
PT_BIN="${PT_HOME_DIR:-/usr/synopsys/prime/Y-2026.03-SP2}/bin"

for c in $CORNERS; do
  lib=CORNER_${c}_LIB spef=CORNER_${c}_SPEF
  set -- "$c" "${SC_LIB}__${!lib}" "${IO_LIB}__${!lib}" "${!spef}"
  # pt_shell writes its command logs into the working directory: one folder per corner (they run in parallel)
  ( mkdir -p "$OUT/pt_$1" && cd "$OUT/pt_$1" && PATH="$PT_BIN:$PATH" pt_shell -x "set CORNER $1; set TOP croc_soc; set VLOG $L/croc_soc.v; \
      set SDC_FILE $L/croc_soc_${SPEC_PERIOD%.0}ns.sdc; set SPEF_FILE $L/croc_soc.$4.spef; set SC_DB $DB/$2.db; \
      set IO_DB $DB/$3.db; set SRAM_DB $SRAM; set OUT_DIR $OUT; \
      source $REPO/scripts/signoff/sta/extract_model_corner.tcl; exit" > "$OUT/etm.$1.log" 2>&1 ) &
done
wait
echo "etm done" > "$OUT/etm.done"
