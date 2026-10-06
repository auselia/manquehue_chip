#!/bin/bash
# scripts/pt/extract_models.sh -- PrimeTime timing models (slow, typical, fast) of a finished run.
#
# Runs scripts/pt/extract_model_corner.tcl once per corner, in parallel, against the 55 ns signoff
# SDC and the matching SPEF of the run, and writes <run>/etm/<TOP>_<corner>.lib. The wafer.space
# template points at these files so the chip-level STA can time through the hard macro.
#
# usage: scripts/pt/extract_models.sh [run folder]   (default: outputs/latest)
# PT's "1 error" in each log (PT-063, Library Compiler path not set) is only the optional .db step.
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
L="$(readlink -f "${1:-$REPO/outputs/latest}")"
OUT="$L/etm"; mkdir -p "$OUT"
DB="${PT_PDK_DB_DIR:-$HOME/pdk_synopsys/db}"
SRAM="$REPO/outputs/.cache/gf180mcu_fd_ip_sram__sram512x8m8wm1__tt_025C_5v00.db"
PT_BIN="${PT_HOME_DIR:-/usr/synopsys/prime/Y-2026.03-SP2}/bin"

for spec in "slow gf180mcu_fd_sc_mcu7t5v0__ss_125C_4v50 gf180mcu_fd_io__ss_125C_4v50 typ_125" \
            "typical gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00 gf180mcu_fd_io__tt_025C_5v00 typ_25" \
            "fast gf180mcu_fd_sc_mcu7t5v0__ff_n40C_5v50 gf180mcu_fd_io__ff_n40C_5v50 typ_-40"; do
  set -- $spec
  ( PATH="$PT_BIN:$PATH" pt_shell -x "set CORNER $1; set TOP croc_soc; set VLOG $L/croc_soc.v; \
      set SDC_FILE $L/croc_soc_55ns.sdc; set SPEF_FILE $L/croc_soc.$4.spef; set SC_DB $DB/$2.db; \
      set IO_DB $DB/$3.db; set SRAM_DB $SRAM; set OUT_DIR $OUT; \
      source $REPO/scripts/pt/extract_model_corner.tcl; exit" > "$OUT/etm.$1.log" 2>&1 ) &
done
wait
echo "etm done" > "$OUT/etm.done"
