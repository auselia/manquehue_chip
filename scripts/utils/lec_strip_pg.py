#!/usr/bin/env python3
# Remove from the croc_soc netlist what Formality must not compare: supply pins and ports, physical-only cells
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: lec_strip_pg.py <in.v> <out.v>      (called by signoff/lec/lec_rtl_vs_gate.tcl)
# in:  the gate-level netlist of a run
# out: the netlist without supplies and physical-only cells
#
# Formality takes the VDD/VSS ports as unmatched drivers and the fill cells as black boxes. With them, most compare
# points fail as X sources. The RTL has none of them.
import re
import sys

src, dst = sys.argv[1:3]
with open(src) as f:
    netlist = f.read()

# fillcap, fill, filltie, endcap and antenna instances: no signal pins, no logic
physical_cell = re.compile(r"(?m)^gf180mcu_fd_sc_mcu7t5v0__(?:fillcap|fill|filltie|endcap|antenna)\w*"
                           r"\s+\S+\s*\([^;]*\)\s*;\n")
netlist, n_physical = physical_cell.subn("", netlist)

# the .VDD/.VSS/.VNW/.VPW pin connections of every instance
pg_pin = r"\.(?:VDD|VSS|VNW|VPW)\s*\(\s*(?:VDD|VSS)\s*\)"
netlist, n_before_comma = re.subn(pg_pin + r"\s*,\s*", "", netlist)
netlist, n_after_comma = re.subn(r"\s*,\s*" + pg_pin, "", netlist)
netlist, n_only_pg = re.subn(r"\(\s*" + pg_pin + r"\s*\)", "( )", netlist)

# VDD and VSS in the port list of the module, and their declarations
netlist = re.sub(r"\s*,\s*(?:VDD|VSS)\b(?=[^;]*\)\s*;)", "", netlist, count=2)
netlist = re.sub(r"(?m)^(?:input|inout|supply1|supply0)\s+(?:VDD|VSS)\s*;\n", "", netlist)

with open(dst, "w") as f:
    f.write(netlist)
n_pins = n_before_comma + n_after_comma + n_only_pg
print(f"lec_strip_pg: removed {n_physical} physical-only cells, {n_pins} PG pin connections")
