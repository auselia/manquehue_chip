#!/bin/bash
# Chip-level PrimeTime STA of chip_top: SPEF from work/chip.dlib (fc_shell, chip_sta_export.tcl), then one pt_shell
# per corner (chip_sta_corner.tcl) with the SDC chip_sta.sdc. Reports in outputs/chip_final/sta_pt.
# usage: make chip-sta   (env: PT_* libraries from the Makefile, SKIP_EXPORT=1 to keep the SPEF already written)
set -e
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
C=$REPO/outputs/chip_final
O=$C/sta_pt
mkdir -p "$O"
[ -s "$C/chip_top.v" ] || { echo "ERROR: no $C/chip_top.v (run make chip_pnr)"; exit 1; }
if [ "${SKIP_EXPORT:-0}" != 1 ]; then
  ( cd "$REPO/work" && CHIP_FLOORPLAN=1 fc_shell -batch -f "$HERE/chip_sta_export.tcl" > "$O/export.log" 2>&1 )
fi
for spec in "slow $PT_SC_DB_slow $PT_IO_DB_slow typ_125" \
            "typical $PT_SC_DB_typical $PT_IO_DB_typical typ_25" \
            "fast $PT_SC_DB_fast $PT_IO_DB_fast typ_-40"; do
  set -- $spec
  spef=$C/chip_top.$4.spef
  [ -s "$spef" ] || { echo "ERROR: no $spef"; exit 1; }
  ( cd "$O" && PATH="$PT_HOME_DIR/bin:$PATH" pt_shell -x "set CORNER $1; set VLOG $C/chip_top.v; \
      set SDC_FILE $HERE/chip_sta.sdc; set SPEF_FILE $spef; set SC_DB $2; set IO_DB $3; \
      set SRAM_DB $PT_SRAM_DB; set REPORT_DIR $O; source $HERE/chip_sta_corner.tcl" > "$O/sta_pt.$1.log" 2>&1 ) || true
done
# summary for make report: worst slack of every path group at every corner, design rule violations
python3 - "$O" "$REPO" <<'EOF'
import glob, re, subprocess, sys, datetime
o, repo = sys.argv[1], sys.argv[2]
worst, fail, n = None, [], 0
for f in sorted(glob.glob(o + "/report_qor.*.rpt")):
    n += 1
    corner, grp = f.split(".")[-2], None
    for line in open(f):
        m = re.search(r"Timing Path Group '(.+?)' \((\w+)_delay", line)
        if m:
            grp = (m.group(1).strip("*"), "setup" if m.group(2) == "max" else "hold")
        m = re.search(r"Critical Path Slack:\s+(-?[\d.]+)", line)
        if m and grp:
            v = float(m.group(1))
            worst = v if worst is None or v < worst else worst
            if v < 0:
                fail.append("%s/%s/%s=%g" % (corner, grp[0], grp[1], v))
# a VIOLATED line at 0.00 slack is only rounding ("increase significant digits"): not counted
drv = sum(1 for f in glob.glob(o + "/report_drv.*.rpt") for l in open(f) if "VIOLATED" in l and "significant digits" not in l)
commit = subprocess.run(["git", "-C", repo, "rev-parse", "--short", "HEAD"], stdout=subprocess.PIPE, universal_newlines=True).stdout.strip()
ok = n == 3 and not fail and drv == 0
s = (f"date: {datetime.datetime.now().isoformat(timespec='seconds')}\ncommit: {commit}\ncorners_timed: {n}\n"
     f"worst_slack_ns: {worst}\nviolations: {','.join(fail) or 'none'}\ndrv_violations: {drv}\n"
     f"status: {'PASS' if ok else 'FAIL'}\n")
open(o + "/summary.txt", "w").write(s)
print(s, end="")
EOF
