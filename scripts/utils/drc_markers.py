#!/usr/bin/env python3
# List the DRC markers of the top cell in a KLayout .lyrdb, one "llx lly urx ury category" line each (um)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: drc_markers.py <file.lyrdb> <top cell> [--ignore <prefix,...>]      (called by impl/lib/drc_eco.tcl)
# in:  the .lyrdb of a KLayout DRC run
# out: stdout
#
# A marker inside a sub-cell has the local coordinates of that cell, so only top-cell markers are listed.
# --ignore skips categories that the macro cannot fix (default DBU, a die-level check).
import argparse
import re

parser = argparse.ArgumentParser()
parser.add_argument("lyrdb")
parser.add_argument("top")
parser.add_argument("--ignore", default="DBU", help="comma-separated category prefixes to skip")
args = parser.parse_args()

ignored = tuple(prefix for prefix in args.ignore.split(",") if prefix)
with open(args.lyrdb, encoding="utf-8") as f:
    text = f.read()

for item in re.findall(r"<item>(.*?)</item>", text, re.S):
    category = re.search(r"<category>'?(.*?)'?</category>", item).group(1)
    cell = re.search(r"<cell>(.*?)</cell>", item).group(1)
    if cell != args.top or category.startswith(ignored):
        continue
    # a value is "<shape type>: (x,y;x,y;...)": its bounding box is the marker
    for value in re.findall(r"<value>(.*?)</value>", item):
        numbers = [float(n) for n in re.findall(r"-?\d+\.?\d*", value.split(":", 1)[1])]
        xs, ys = numbers[0::2], numbers[1::2]
        print(min(xs), min(ys), max(xs), max(ys), category)
