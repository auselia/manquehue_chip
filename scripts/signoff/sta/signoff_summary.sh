#!/bin/bash
# Summary of the functional signoff STA (make sta-pt) and of the Formality result of a run.
# usage: scripts/signoff/sta/signoff_summary.sh      (env: RUN)
. "$(dirname "${BASH_SOURCE[0]}")/../../utils/env.sh"
step_begin signoff
q() { # file kind (max_delay/setup or min_delay/hold) -> slack of path group 'clock'
  grep -A6 "Timing Path Group 'clock' ($2)" "$1" 2>/dev/null | awk '/Critical Path Slack/{print $4; exit}'; }
S=$RUN/sta_pt
SL=$(q $S/report_qor.slow.rpt "max_delay/setup"); ST=$(q $S/report_qor.typical.rpt "max_delay/setup"); SF=$(q $S/report_qor.fast.rpt "max_delay/setup")
HL=$(q $S/report_qor.slow.rpt "min_delay/hold");  HT=$(q $S/report_qor.typical.rpt "min_delay/hold");  HF=$(q $S/report_qor.fast.rpt "min_delay/hold")
summary setup_wns_ns "slow=$SL typical=$ST fast=$SF"
summary hold_wns_ns "slow=$HL typical=$HT fast=$HF"
LEC=$(sed -n 's/^Failing (not equivalent) *\([0-9]*\).*/\1/p' $RUN/lec_fm/report_verification_status.rpt 2>/dev/null | head -1)
summary lec_failing_points "${LEC:-n/a}"
LVS=$(ls $RUN/lvs/*.lyrdb 2>/dev/null | head -1)
LVSN=n/a; [ -n "$LVS" ] && LVSN=$(grep -c "<item>" "$LVS" || true)
summary lvs_errors "$LVSN"
# KLayout DRC of the run. DRC_WAIVED: rules that only fire inside the official PDK SRAM layout (NW.2b_5V_, the wafer.space
# precheck does not report them). They are counted apart and do not fail the sign-off.
DRC=$(ls $RUN/*_drc_*.lyrdb 2>/dev/null | head -1)
DRCN=n/a; DRCW=0
if [ -n "$DRC" ]; then
  read DRCN DRCW < <(python3 - "$DRC" "${DRC_WAIVED:-NW.2b_5V_}" <<'EOF'
import re, sys
s = open(sys.argv[1]).read()
waived = sys.argv[2].split()
n = w = 0
for it in re.findall(r"<item>(.*?)</item>", s, re.S):
    c = re.search(r"<category>(.*?)</category>", it).group(1).strip("'")
    if c in waived: w += 1
    else: n += 1
print(n, w)
EOF
)
fi
summary drc_errors "$DRCN"
summary drc_waived "$DRCW (${DRC_WAIVED:-NW.2b_5V_}, inside the PDK SRAM)"
OK=PASS
for v in $SL $ST $SF $HL $HT $HF; do awk -v x="$v" 'BEGIN{exit !(x+0 < 0 || x == "")}' && OK=FAIL; done
[ "${LEC:-1}" = 0 ] || OK=FAIL
[ "$LVSN" = 0 ] || OK=FAIL
[ "$DRCN" = 0 ] || OK=FAIL
summary status $OK
