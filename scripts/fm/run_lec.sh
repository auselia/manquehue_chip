#!/bin/bash
# Formality RTL-vs-gate equivalence check of a finished run, guided by the SVFs Fusion Compiler wrote.
#
# usage: scripts/fm/run_lec.sh [run folder]   (default: outputs/latest)
#        PDK_DB=<dir with the synopsys .db files> (default ~/pdk_synopsys/db)
#
# Every FC session writes a default-*.svf, and the netlist is only explained by all of them in flow order.
# The six sessions are matched to the step logs (<step>.log) by modification time, which FC sets at the end of the
# session. The files come from the run folder (<run>/logs and <run>/svf, copied there by scripts/utils/archive_run.sh at
# the end of the finish step), so any run with those folders can be checked. For an older run without them the script
# falls back to work/logs and work/ of this checkout, which only fit the newest build.
# Results land in <run folder>/lec_fm/ and in <run folder>/lec_fm.log.
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN=$(readlink -f "${1:-$REPO/outputs/latest}")
PDK_DB=${PDK_DB:-$HOME/pdk_synopsys/db}
CACHE=$REPO/outputs/.cache
if [ -d "$RUN/logs" ] && [ -d "$RUN/svf" ]; then LOGD=$RUN/logs; SVFD=$RUN/svf; else LOGD=$REPO/work/logs; SVFD=$REPO/work; fi
echo "step logs: $LOGD, SVF: $SVFD"
SVF=""
for step in read_rtl floorplan synthesis cts route finish; do
  t=$(stat -c %Y "$LOGD/$step.log")
  f=$(for c in "$SVFD"/default-*.svf; do [ "$(stat -c %Y "$c")" = "$t" ] && echo "$c"; done | head -1)
  [ -n "$f" ] || { echo "no SVF for step $step ($LOGD/$step.log was written at $t)"; exit 1; }
  SVF="$SVF $f"
done
echo "SVF chain:$SVF"
mkdir -p "$RUN/lec_fm"
cd "$RUN/lec_fm"
fm_shell -x "
set TOP croc_soc
set VLOG $RUN/croc_soc.v
set FLIST $REPO/flists/croc.flist
set SC_DB $PDK_DB/gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30.db
set IO_DB $PDK_DB/gf180mcu_fd_io__tt_025C_3v30.db
set SRAM_DB $CACHE/gf180mcu_fd_ip_sram__sram512x8m8wm1__tt_025C_5v00.db
set REPORT_DIR $RUN/lec_fm
set SVF_FILE {$SVF}
source $REPO/scripts/fm/lec_rtl_vs_gate.tcl
exit
" > "$RUN/lec_fm.log" 2>&1
sed -n '/Verification Results/,/^\*\*\*\*/p' "$RUN/lec_fm/report_verification_status.rpt" | grep -v '^$'
