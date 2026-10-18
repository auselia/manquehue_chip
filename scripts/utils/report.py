#!/usr/bin/env python3
"""One-page report card of a run: collects <run>/checks/*/summary.txt into <run>/report.md.
usage: scripts/utils/report.py [run folder]   (default outputs/latest)"""
import os
import subprocess
import sys

repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
run = os.path.realpath(sys.argv[1] if len(sys.argv) > 1 else repo + "/outputs/latest")
commit = subprocess.run(["git", "-C", repo, "rev-parse", "--short", "HEAD"], stdout=subprocess.PIPE, universal_newlines=True).stdout.strip()
order = ["signoff", "scan_sta", "gls", "dft", "chip"]
rows, body = [], []
for step in order:
    f = f"{run}/checks/{step}/summary.txt"
    if not os.path.exists(f):
        rows.append((step, "not run", ""))
        continue
    kv = [l.rstrip("\n").split(": ", 1) for l in open(f) if ": " in l]
    d = dict(kv)
    rows.append((step, d.get("status", "?"), d.get("date", "")))
    body.append(f"### {step}\n\n" + "\n".join(f"- {k}: {v}" for k, v in kv if k not in ("run",)) + "\n")
ok = all(r[1] == "PASS" for r in rows)
out = [f"# Report card of {os.path.basename(run)}, repository commit {commit}", "", f"Run: `{run}`", "", "| Step | Status | Date |", "|---|---|---|"]
out += [f"| {s} | {st} | {d} |" for s, st, d in rows]
out += ["", f"**{'ALL PASS' if ok else 'NOT ALL PASS'}**", ""] + body
path = f"{run}/report.md"
open(path, "w").write("\n".join(out))
print("\n".join(out[:12 + len(rows)]))
print("written", path)
sys.exit(0 if ok else 1)
