#!/bin/bash
# PrimeTime sign-off STA of a run: one pt_shell per corner (sta_corner.tcl), then the QoR summary
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/sta/sta.sh      (env: RUN, see settings.sh)
# in:  <run>/croc_soc.v, <run>/croc_soc_55ns.sdc, <run>/croc_soc.<spef>.spef of every corner
# out: sta_pt/ in the run folder: the reports of every corner and sta_pt.<corner>.log
. "$(dirname "${BASH_SOURCE[0]}")/settings.sh"
need "$PT_HOME/bin/pt_shell" STA-PT "pt_shell not found in PT_HOME=$PT_HOME."
need "$SPEC_SDC" STA-PT "sign-off SDC not found: $SPEC_SDC. Run make finish, or make pt_export to write SDC and SPEF again."
sram_db STA-PT
set -o pipefail
VLOG_REAL=$(readlink -f "$VLOG"); SDC_REAL=$(readlink -f "$SPEC_SDC"); RUN_REAL=$(dirname "$VLOG_REAL")
OUT=$RUN_REAL/sta_pt
mkdir -p "$OUT"
echo "[STA-PT] design  : $VLOG_REAL"
echo "[STA-PT] sdc     : $SDC_REAL"
echo "[STA-PT] results : $OUT"
for corner in $CORNERS; do
  corner_inputs "$corner"
  need "$SPEF" STA-PT "SPEF not found for corner $corner: $SPEF. Run make finish or make pt_export first."
  echo "[STA-PT] --- corner: $corner ---"
  ( cd "$OUT" && PATH="$PT_HOME/bin:$PATH" pt_shell -x "set CORNER $corner; set TOP $TOP; set VLOG $VLOG_REAL;
      set SDC_FILE $SDC_REAL; set SPEF_FILE $SPEF; set SC_DB $SC_DB; set IO_DB $IO_DB; set SRAM_DB $PT_SRAM_DB;
      set REPORT_DIR $OUT; source $REPO/scripts/signoff/sta/sta_corner.tcl; exit" ) 2>&1 | tee "$OUT/sta_pt.$corner.log"
done
# Setup at slow and typical, hold at fast, as in mcmm.tcl
echo "[STA-PT] ================ Summary ================"
for corner in slow typical; do
  echo "[STA-PT] setup @ $corner (Path Group 'clock'):"
  grep -A5 "Timing Path Group 'clock' (max_delay/setup)" "$OUT/report_qor.$corner.rpt" 2>/dev/null | sed 's/^/  /'
done
echo "[STA-PT] hold @ fast (Path Group 'clock'):"
grep -A5 "Timing Path Group 'clock' (min_delay/hold)" "$OUT/report_qor.fast.rpt" 2>/dev/null | sed 's/^/  /'
echo "[STA-PT] Full reports: $OUT/*.rpt"
