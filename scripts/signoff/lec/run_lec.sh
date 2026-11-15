#!/bin/bash
# Formality equivalence of the RTL and the netlist of a run, guided by the SVF files of Fusion Compiler
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/lec/run_lec.sh [run folder]      (default outputs/latest)
# in:  <run>/croc_soc.v, <run>/logs/<step>.log, <run>/svf/default-*.svf, flists/croc.flist
# out: <run>/lec_fm/ (reports), <run>/lec_fm.log
#
# Every Fusion Compiler session writes one default-*.svf, and the netlist is explained only by all six in flow order.
# An SVF and the log of its step have the same modification time (archive_run.sh keeps the times).
set -e
RUN=${1:-$RUN}
. "$(dirname "${BASH_SOURCE[0]}")/../../utils/env.sh"
need "$RUN/logs" LEC "no logs/ in '$RUN'. A run that make finish wrote has logs/ and svf/."
need "$RUN/svf" LEC "no svf/ in '$RUN'. A run that make finish wrote has logs/ and svf/."
sram_db LEC

svf_chain=""
for step in read_rtl floorplan synthesis cts route finish; do
  log_time=$(stat -c %Y "$RUN/logs/$step.log")
  svf=""
  for candidate in "$RUN"/svf/default-*.svf; do
    [ "$(stat -c %Y "$candidate")" = "$log_time" ] && { svf=$candidate; break; }
  done
  [ -n "$svf" ] || { echo "no SVF for step $step ($RUN/logs/$step.log was written at $log_time)"; exit 1; }
  svf_chain="$svf_chain $svf"
done
echo "SVF chain:$svf_chain"

# Formality compares functions: it reads the typical libraries (CORNER_typical_LIB comes from config/ through env.sh)
report_dir=$RUN/lec_fm
mkdir -p "$report_dir"
cd "$report_dir"
# shellcheck disable=SC2154
fm_shell -x "
set TOP $TOP
set VLOG $RUN/$TOP.v
set FLIST $REPO/flists/croc.flist
set SC_DB $PDK_DB/${SC_LIB}__${CORNER_typical_LIB}.db
set IO_DB $PDK_DB/${IO_LIB}__${CORNER_typical_LIB}.db
set SRAM_DB $SRAM_DB
set REPORT_DIR $report_dir
set SVF_FILE {$svf_chain}
source $REPO/scripts/signoff/lec/lec_rtl_vs_gate.tcl
exit
" > "$RUN/lec_fm.log" 2>&1
sed -n '/Verification Results/,/^\*\*\*\*/p' "$report_dir/report_verification_status.rpt" | grep -v '^$'
