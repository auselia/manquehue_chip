#!/usr/bin/env python3
"""List the top-cell markers of a KLayout .lyrdb as 'llx lly urx ury category' lines (um).

Markers reported inside sub-cells are in that cell's local coordinates, so only markers in the
top cell are listed. Categories in --ignore (die-level checks that a macro cannot fix) are skipped.
"""
import argparse
import re
import sys

ap = argparse.ArgumentParser()
ap.add_argument("lyrdb")
ap.add_argument("top")
ap.add_argument("--ignore", default="DBU", help="comma-separated category prefixes to skip")
args = ap.parse_args()

ignore = tuple(x for x in args.ignore.split(",") if x)
text = open(args.lyrdb, encoding="utf-8").read()
for item in re.findall(r"<item>(.*?)</item>", text, re.S):
    cat = re.search(r"<category>'?(.*?)'?</category>", item).group(1)
    cell = re.search(r"<cell>(.*?)</cell>", item).group(1)
    if cell != args.top or cat.startswith(ignore):
        continue
    for value in re.findall(r"<value>(.*?)</value>", item):
        nums = [float(n) for n in re.findall(r"-?\d+\.?\d*", value.split(":", 1)[1])]
        xs, ys = nums[0::2], nums[1::2]
        print(min(xs), min(ys), max(xs), max(ys), cat)
