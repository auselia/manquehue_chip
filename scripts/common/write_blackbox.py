#!/usr/bin/env python3
"""Write the blackbox stub of the top module from its gate-level netlist.

usage: write_blackbox.py <netlist.v> <stub.v> [top module, default croc_soc]

The stub has the module header and the port declarations of the netlist, nothing else. The chip-level flow
(wafer.space template, librelane/macros/macros_5v.yaml) reads it as the Verilog view of the hard macro, so the port
list there always matches the GDS and LEF of the same run. Called by scripts/06_finish.tcl.
"""
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
top = sys.argv[3] if len(sys.argv) > 3 else "croc_soc"

header, decls = None, []
with open(src) as f:
    inside = False
    buf = ""
    for line in f:
        if not inside:
            if re.match(r"\s*module\s+%s\b" % re.escape(top), line):
                inside = True
                buf = line
                if ";" in line:
                    header = buf
            continue
        if header is None:
            buf += line
            if ";" in line:
                header = buf
            continue
        m = re.match(r"\s*(input|output|inout)\b", line)
        if m:
            decls.append(line.strip())
        elif decls and line.strip():
            break                          # first line after the port declarations

if header is None or not decls:
    sys.exit("write_blackbox.py: no module %s with port declarations in %s" % (top, src))

ports = [p.strip() for p in re.search(r"\((.*)\)", header, re.S).group(1).split(",")]
with open(dst, "w") as f:
    f.write("// Blackbox stub of %s, written by scripts/common/write_blackbox.py from %s.\n" % (top, src.split("/")[-1]))
    f.write("// Port list and directions of the gate-level netlist of the same run. Do not edit.\n\n")
    f.write("(* blackbox *)\nmodule %s (\n" % top)
    f.write(",\n".join("    " + p for p in ports) + "\n);\n\n")
    for d in decls:
        f.write(re.sub(r"\s+", " ", d).replace(" ;", ";") + "\n")
    f.write("\nendmodule\n")
print("INFO: Wrote blackbox -> %s (%d ports)" % (dst, len(ports)))
