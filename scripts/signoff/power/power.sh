#!/bin/bash
# PrimePower analysis of a run (power_corner.tcl): the setup of the STA, then activity and power reports
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/power/power.sh      (env: RUN, PP_CORNERS, PP_SAIF, see below and sta/settings.sh)
# in:  <run>/croc_soc.v, <run>/croc_soc.sdc, <run>/croc_soc.<spef>.spef of every corner, optional SAIF
# out: power_pp/ in the run folder: the reports of every corner and power_pp.<corner>.log
. "$(dirname "${BASH_SOURCE[0]}")/../sta/settings.sh"
# Without activity data PrimePower gives a vectorless estimate (default toggle rate and static probability).
# Set PP_SAIF to a simulated activity file for real numbers.
PP_SAIF=${PP_SAIF-}
PP_DEFAULT_TOGGLE_RATE=${PP_DEFAULT_TOGGLE_RATE-0.1}
PP_DEFAULT_STATIC_PROB=${PP_DEFAULT_STATIC_PROB-0.5}
# fast by default: the scenario with power analysis in mcmm.tcl (5.5 V, the highest switching and leakage power).
# All corners: PP_CORNERS="slow typical fast"
PP_CORNERS=${PP_CORNERS-fast}
need "$PT_HOME/bin/pt_shell" POWER-PP "pt_shell not found in PT_HOME=$PT_HOME."
need "$SDC" POWER-PP "SDC not found: $SDC. Run make finish, or make pt_export to write SDC and SPEF again."
sram_db POWER-PP
set -o pipefail
VLOG_REAL=$(readlink -f "$VLOG"); SDC_REAL=$(readlink -f "$SDC"); RUN_REAL=$(dirname "$VLOG_REAL")
SAIF=""; [ -n "$PP_SAIF" ] && SAIF=$(realpath -ms "$PP_SAIF")
OUT=$RUN_REAL/power_pp
mkdir -p "$OUT"
echo "[POWER-PP] design  : $VLOG_REAL"
echo "[POWER-PP] sdc     : $SDC_REAL"
echo "[POWER-PP] corners : $PP_CORNERS"
echo "[POWER-PP] results : $OUT"
for corner in $PP_CORNERS; do
  case " $CORNERS " in *" $corner "*) ;; *) echo "[POWER-PP] ERROR: unknown corner '$corner' (expected one of: $CORNERS)"; exit 1 ;; esac
  corner_inputs "$corner"
  need "$SPEF" POWER-PP "SPEF not found for corner $corner: $SPEF. Run make finish or make pt_export first."
  echo "[POWER-PP] --- corner: $corner ---"
  ( cd "$OUT" && PATH="$PT_HOME/bin:$PATH" pt_shell -x "set CORNER $corner; set TOP $TOP; set VLOG $VLOG_REAL;
      set SDC_FILE $SDC_REAL; set SPEF_FILE $SPEF; set SC_DB $SC_DB; set IO_DB $IO_DB; set SRAM_DB $PT_SRAM_DB;
      set REPORT_DIR $OUT; set PP_TOGGLE_RATE $PP_DEFAULT_TOGGLE_RATE; set PP_STATIC_PROB $PP_DEFAULT_STATIC_PROB;
      set PP_SAIF {$SAIF}; source $REPO/scripts/signoff/power/power_corner.tcl; exit" ) 2>&1 | tee "$OUT/power_pp.$corner.log"
done
echo "[POWER-PP] ================ Summary ================"
for corner in $PP_CORNERS; do
  echo "[POWER-PP] $corner:"
  grep "Total Power" "$OUT/report_power_summary.$corner.rpt" 2>/dev/null | sed 's/^/  /'
done
echo "[POWER-PP] Full reports: $OUT/*.rpt"
