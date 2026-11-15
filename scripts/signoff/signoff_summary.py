#!/usr/bin/env python3
# Summary of the sign-off of a run: PrimeTime STA, design rules, Formality, KLayout LVS and DRC
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/signoff_summary.py      (env: RUN, default outputs/latest; CHECKS_OUT; DRC_WAIVED)
# in:  <run>/sta_pt/*.rpt, <run>/lec_fm/report_verification_status.rpt, <run>/lvs/*.lyrdb, <run>/*_drc_*.lyrdb
# out: <run>/checks/signoff/summary.txt ("key: value" lines, the last one status: PASS or FAIL)
import datetime
import glob
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "scripts", "lib"))
import config  # noqa: E402  (scripts/lib/config.py)

# Rules that fire only inside the official PDK SRAM layout. The wafer.space precheck does not report them.
# They are counted apart and do not fail the sign-off.
DRC_WAIVED = os.environ.get("DRC_WAIVED", "NW.2b_5V_")


def first_file(pattern):
    files = sorted(glob.glob(pattern))
    return files[0] if files else None


def read_lines(path):
    if not path or not os.path.exists(path):
        return []
    with open(path) as f:
        return f.read().splitlines()


def clock_slack(qor_report, kind):
    """The critical path slack of path group 'clock' in a report_qor file. kind: max_delay/setup or min_delay/hold."""
    lines = read_lines(qor_report)
    for i, line in enumerate(lines):
        if f"Timing Path Group 'clock' ({kind})" in line:
            for following in lines[i:i + 7]:
                if "Critical Path Slack" in following:
                    return following.split()[3]
    return ""


def all_groups(sta_dir):
    """The worst slack of all path groups at all corners, and the list of the negative ones."""
    worst, failing = None, []
    for report in sorted(glob.glob(sta_dir + "/report_qor.*.rpt")):
        corner = report.split(".")[-2]
        group = None
        for line in read_lines(report):
            header = re.search(r"Timing Path Group '(.+?)' \((\w+)_delay", line)
            if header:
                group = (header.group(1).strip("*"), "setup" if header.group(2) == "max" else "hold")
            slack = re.search(r"Critical Path Slack:\s+(-?[\d.]+)", line)
            if slack and group:
                value = float(slack.group(1))
                if worst is None or value < worst:
                    worst = value
                if value < 0:
                    failing.append("%s/%s/%s=%g" % (corner, group[0], group[1], value))
    return (str(worst) if worst is not None else "n/a"), (",".join(failing) or "none")


def drv_violations(sta_dir):
    """VIOLATED lines of the design rule reports. A VIOLATED line at 0.00 slack is rounding: not counted."""
    reports = sorted(glob.glob(sta_dir + "/report_drv.*.rpt"))
    if not reports:
        return "n/a"
    lines = [line for report in reports for line in read_lines(report)]
    return str(sum(1 for line in lines if "VIOLATED" in line and "significant digits" not in line))


def unconstrained_endpoints(sta_dir):
    for report in sorted(glob.glob(sta_dir + "/check_timing.*.rpt")):
        for line in read_lines(report):
            if re.search(r"endpoint.* not constrained", line):
                count = re.search(r"There (?:is|are) (\d*)", line)
                return count.group(1) if count else ""
    return "0"


def lec_failing_points(run):
    for line in read_lines(run + "/lec_fm/report_verification_status.rpt"):
        failing = re.match(r"Failing \(not equivalent\) *(\d*)", line)
        if failing:
            return failing.group(1)
    return "n/a"


def lvs_errors(run):
    lyrdb = first_file(run + "/lvs/*.lyrdb")
    if not lyrdb:
        return "n/a"
    return str(sum(1 for line in read_lines(lyrdb) if "<item>" in line))


def drc_errors(run):
    """(errors, waived) of the KLayout DRC database of the run."""
    lyrdb = first_file(run + "/*_drc_*.lyrdb")
    if not lyrdb:
        return "n/a", 0
    with open(lyrdb) as f:
        items = re.findall(r"<item>(.*?)</item>", f.read(), re.S)
    waived_rules = DRC_WAIVED.split()
    categories = [re.search(r"<category>(.*?)</category>", item).group(1).strip("'") for item in items]
    waived = sum(1 for category in categories if category in waived_rules)
    return str(len(items) - waived), waived


def main():
    run = os.path.realpath(os.environ.get("RUN") or REPO + "/outputs/latest")
    if not os.path.isdir(run):
        sys.exit(f"RUN folder not found: '{run}' (set RUN=outputs/<run> or an absolute path)")
    corners = config.read()["CORNERS"].split()
    sta_dir = run + "/sta_pt"

    setup = {c: clock_slack(f"{sta_dir}/report_qor.{c}.rpt", "max_delay/setup") for c in corners}
    hold = {c: clock_slack(f"{sta_dir}/report_qor.{c}.rpt", "min_delay/hold") for c in corners}
    groups_worst, groups_failing = all_groups(sta_dir)
    drv = drv_violations(sta_dir)
    lec = lec_failing_points(run)
    lvs = lvs_errors(run)
    drc, drc_waived = drc_errors(run)

    clock_slacks = list(setup.values()) + list(hold.values())
    passed = (all(s != "" and float(s) >= 0 for s in clock_slacks) and lec == "0" and lvs == "0" and drc == "0"
              and groups_failing == "none" and drv == "0")

    commit = subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True).stdout.strip()
    summary = [
        ("run", run),
        ("date", datetime.datetime.now().astimezone().isoformat(timespec="seconds")),
        ("commit", commit),
        ("setup_wns_ns", " ".join(f"{c}={setup[c]}" for c in corners)),
        ("hold_wns_ns", " ".join(f"{c}={hold[c]}" for c in corners)),
        ("all_groups_worst_slack_ns", groups_worst),
        ("all_groups_violations", groups_failing),
        ("drv_violations", drv),
        ("unconstrained_endpoints", f"{unconstrained_endpoints(sta_dir) or 0} (reported, not a failure)"),
        ("lec_failing_points", lec),
        ("lvs_errors", lvs),
        ("drc_errors", drc),
        ("drc_waived", f"{drc_waived} ({DRC_WAIVED}, inside the PDK SRAM)"),
        ("status", "PASS" if passed else "FAIL"),
    ]
    out_dir = os.path.join(os.environ.get("CHECKS_OUT") or run + "/checks", "signoff")
    os.makedirs(out_dir, exist_ok=True)
    with open(out_dir + "/summary.txt", "w") as f:
        f.write("".join(f"{key}: {value}\n" for key, value in summary))


if __name__ == "__main__":
    main()
