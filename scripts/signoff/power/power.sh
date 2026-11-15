#!/bin/bash
# PrimePower analysis of a run: the setup of the STA, then switching activity and power reports (power_corner.tcl)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/power/power.sh      (env: RUN, PP_CORNERS, PP_SAIF, see below and sta/settings.sh)
# in:  <run>/croc_soc.v, <run>/croc_soc.sdc, <run>/croc_soc.<spef>.spef of every corner, an optional SAIF
# out: <run>/power_pp/: the reports and the log of every corner
. "$(dirname "${BASH_SOURCE[0]}")/../sta/settings.sh"

# Without activity data the estimate is vectorless: a default toggle rate and static probability on the inputs.
# PP_SAIF gives the activity of a simulation.
PP_SAIF=${PP_SAIF-}
PP_DEFAULT_TOGGLE_RATE=${PP_DEFAULT_TOGGLE_RATE-0.1}
PP_DEFAULT_STATIC_PROB=${PP_DEFAULT_STATIC_PROB-0.5}
# fast: the scenario with power analysis in mcmm.tcl (5.5 V gives the highest switching and leakage power)
PP_CORNERS=${PP_CORNERS-fast}

need "$PT_HOME/bin/pt_shell" POWER-PP "pt_shell not found in PT_HOME=$PT_HOME."
need "$SDC" POWER-PP "SDC not found: $SDC. Run make finish, or make pt_export to write SDC and SPEF again."
sram_db POWER-PP
set -o pipefail

vlog_file=$(readlink -f "$VLOG")
sdc_file=$(readlink -f "$SDC")
run_dir=$(dirname "$vlog_file")
saif_file=""
[ -n "$PP_SAIF" ] && saif_file=$(realpath -ms "$PP_SAIF")
out=$run_dir/power_pp
mkdir -p "$out"
echo "[POWER-PP] design  : $vlog_file"
echo "[POWER-PP] sdc     : $sdc_file"
echo "[POWER-PP] corners : $PP_CORNERS"
echo "[POWER-PP] results : $out"

for corner in $PP_CORNERS; do
  case " $CORNERS " in
    *" $corner "*) ;;
    *) echo "[POWER-PP] ERROR: unknown corner '$corner' (expected one of: $CORNERS)"; exit 1 ;;
  esac
  corner_inputs "$corner" "$run_dir"
  need "$SPEF" POWER-PP "SPEF not found for corner $corner: $SPEF. Run make finish or make pt_export first."
  echo "[POWER-PP] --- corner: $corner ---"
  ( cd "$out" && PATH="$PT_HOME/bin:$PATH" pt_shell -x "
      set CORNER $corner; set TOP $TOP; set VLOG $vlog_file; set SDC_FILE $sdc_file; set SPEF_FILE $SPEF
      set SC_DB $SC_DB; set IO_DB $IO_DB; set SRAM_DB $SRAM_DB; set REPORT_DIR $out
      set PP_TOGGLE_RATE $PP_DEFAULT_TOGGLE_RATE; set PP_STATIC_PROB $PP_DEFAULT_STATIC_PROB; set PP_SAIF {$saif_file}
      source $REPO/scripts/signoff/power/power_corner.tcl; exit" ) 2>&1 | tee "$out/power_pp.$corner.log"
done

echo "[POWER-PP] ================ Summary ================"
for corner in $PP_CORNERS; do
  echo "[POWER-PP] $corner:"
  grep "Total Power" "$out/report_power_summary.$corner.rpt" 2>/dev/null | sed 's/^/  /'
done
echo "[POWER-PP] Full reports: $out/*.rpt"
