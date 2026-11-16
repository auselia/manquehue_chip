#!/usr/bin/env python3
# Collect the summaries of the checks of a run into one page, <run>/report.md
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/utils/report.py [run folder]      (default outputs/latest; exit 1 when a check is not PASS)
# in:  <run>/checks/<check>/summary.txt
# out: <run>/report.md
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHECKS = ["signoff", "scan_sta", "gls", "dft"]  # in flow order


def read_summary(path):
    """The "key: value" lines of a summary file, in file order."""
    with open(path) as f:
        return [line.rstrip("\n").split(": ", 1) for line in f if ": " in line]


def git_commit():
    result = subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"],
                            stdout=subprocess.PIPE, universal_newlines=True)
    return result.stdout.strip()


def main():
    run = os.path.realpath(sys.argv[1] if len(sys.argv) > 1 else REPO + "/outputs/latest")

    rows, sections = [], []
    for check in CHECKS:
        path = f"{run}/checks/{check}/summary.txt"
        if not os.path.exists(path):
            rows.append((check, "not run", ""))
            continue
        pairs = read_summary(path)
        values = dict(pairs)
        rows.append((check, values.get("status", "?"), values.get("date", "")))
        lines = "\n".join(f"- {key}: {value}" for key, value in pairs if key != "run")
        sections.append(f"### {check}\n\n{lines}\n")

    not_run = [check for check, status, _ in rows if status == "not run"]
    statuses = [status for _, status, _ in rows if status != "not run"]
    all_pass = bool(statuses) and all(status == "PASS" for status in statuses)

    verdict = "**ALL PASS**" if all_pass else "**NOT ALL PASS**"
    if not_run:
        verdict += f" (not run: {', '.join(not_run)})"
    page = [f"# Report card of {os.path.basename(run)}, repository commit {git_commit()}", "",
            f"Run: `{run}`", "", "| Step | Status | Date |", "|---|---|---|"]
    page += [f"| {check} | {status} | {date} |" for check, status, date in rows]
    page += ["", verdict, ""] + sections

    path = f"{run}/report.md"
    with open(path, "w") as f:
        f.write("\n".join(page))
    print("\n".join(page[:12 + len(rows)]))
    print("written", path)
    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
