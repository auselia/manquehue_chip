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
# Every path group, not only 'clock': adc_sclk, jtag_tck, recovery and removal (async_default), clock gating. The
# worst slack of each group at each corner, setup and hold. The design rules count as violations too.
read GRP_WORST GRP_FAIL < <(python3 - $S <<'EOF'
import re, sys, glob
worst, fail = None, []
for f in sorted(glob.glob(sys.argv[1] + "/report_qor.*.rpt")):
    corner = f.split(".")[-2]
    grp = None
    for line in open(f):
        m = re.search(r"Timing Path Group '(.+?)' \((\w+)_delay", line)
        if m:
            grp = (m.group(1).strip("*"), "setup" if m.group(2) == "max" else "hold")
        m = re.search(r"Critical Path Slack:\s+(-?[\d.]+)", line)
        if m and grp:
            v = float(m.group(1))
            if worst is None or v < worst:
                worst = v
            if v < 0:
                fail.append("%s/%s/%s=%g" % (corner, grp[0], grp[1], v))
print(worst if worst is not None else "n/a", ",".join(fail) or "none")
EOF
)
summary all_groups_worst_slack_ns "$GRP_WORST"
summary all_groups_violations "$GRP_FAIL"
# a VIOLATED line at 0.00 slack is only rounding ("increase significant digits"): not counted
DRV=$(cat $S/report_drv.*.rpt 2>/dev/null | grep "VIOLATED" | grep -vc "significant digits")
[ -n "$(ls $S/report_drv.*.rpt 2>/dev/null)" ] || DRV=n/a
summary drv_violations "$DRV"
UNC=$(grep -h "endpoint.* not constrained" $S/check_timing.*.rpt 2>/dev/null | head -1 | sed -n 's/.*There \(is\|are\) \([0-9]*\).*/\2/p')
summary unconstrained_endpoints "${UNC:-0} (reported, not a failure)"
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
[ "$GRP_FAIL" = none ] || OK=FAIL
[ "$DRV" = 0 ] || OK=FAIL
summary status $OK
