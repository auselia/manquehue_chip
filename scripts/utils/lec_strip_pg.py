#!/usr/bin/env python3
"""Prepare the final croc_soc netlist for Formality: drop what is not logic.

usage: lec_strip_pg.py <in.v> <out.v>

The signoff netlist carries the power ports (VDD/VSS), a .VDD/.VSS pin on every cell and the
physical-only cells (fillcap, tap, endcap, antenna). Formality treats the supply ports as unmatched
drivers and the fill cells as black boxes, which turned most of the design into X sources and made
almost every compare point fail. The RTL has none of these, so they are removed here:
  - power/ground pin connections on every instance
  - VDD/VSS port declarations and their entries in the module port list
  - instances of fillcap/filltie/endcap/antenna cells (no signal pins, no logic)
"""
import re, sys

src, dst = sys.argv[1:3]
t = open(src).read()

phys = re.compile(r"(?m)^gf180mcu_fd_sc_mcu7t5v0__(?:fillcap|fill|filltie|endcap|antenna)\w*\s+\S+\s*\([^;]*\)\s*;\n")
t, n_phys = phys.subn("", t)

pg = r"\.(?:VDD|VSS|VNW|VPW)\s*\(\s*(?:VDD|VSS)\s*\)"
t, n1 = re.subn(pg + r"\s*,\s*", "", t)       # pin followed by a comma
t, n2 = re.subn(r"\s*,\s*" + pg, "", t)       # last pin, preceded by a comma
t, n3 = re.subn(r"\(\s*" + pg + r"\s*\)", "( )", t)  # instance with only PG pins

t = re.sub(r"\s*,\s*(?:VDD|VSS)\b(?=[^;]*\)\s*;)", "", t, count=2)   # module port list entries
t = re.sub(r"(?m)^(?:input|inout|supply1|supply0)\s+(?:VDD|VSS)\s*;\n", "", t)
open(dst, "w").write(t)
print(f"lec_strip_pg: removed {n_phys} physical-only cells, {n1 + n2 + n3} PG pin connections")
