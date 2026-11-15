#!/bin/bash
# PrimeTime timing models (ETM) of a run at every corner, in parallel, for the chip-level STA
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/sta/extract_models.sh [run folder]      (default outputs/latest)
# in:  <run>/croc_soc.v, <run>/croc_soc_55ns.sdc, <run>/croc_soc.<spef>.spef of every corner
# out: <run>/etm/croc_soc_<corner>.lib, the log of every corner, etm.done
#
# Each log has one PT-063 error (Library Compiler path not set). It is about the optional .db of the model only.
set -e
RUN=${1:-$RUN}
. "$(dirname "${BASH_SOURCE[0]}")/settings.sh"
sram_db ETM
out=$RUN/etm
mkdir -p "$out"

for corner in $CORNERS; do
  corner_inputs "$corner" "$RUN"
  ( mkdir -p "$out/pt_$corner" && cd "$out/pt_$corner" && PATH="$PT_HOME/bin:$PATH" pt_shell -x "
      set CORNER $corner; set TOP $TOP; set VLOG $RUN/$TOP.v; set SDC_FILE $SPEC_SDC; set SPEF_FILE $SPEF
      set SC_DB $SC_DB; set IO_DB $IO_DB; set SRAM_DB $SRAM_DB; set OUT_DIR $out
      source $REPO/scripts/signoff/sta/extract_model_corner.tcl; exit" > "$out/etm.$corner.log" 2>&1 ) &
done
wait
echo "etm done" > "$out/etm.done"
