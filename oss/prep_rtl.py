#!/usr/bin/env python3
"""Generate the open-flow RTL view into oss/build/ (the RTL in rtl/ is not modified).

  - tc_sram_oss.sv : rtl/tech_cells/gf180/tc_sram.sv without the VDD/VSS connections to the SRAM macro. The
                     Fusion Compiler flow connects them in the netlist; in the open flow OpenROAD connects power
                     pins by name (global connections), and constants on those pins would become tie cells.
  - sram_blackbox.v: port-only stub of gf180mcu_fd_ip_sram__sram512x8m8wm1 (the vendor model has specify blocks
                     Yosys cannot parse; the liberty has no VDD/VSS ports).
  - croc_oss.flist : flists/croc.flist with the SRAM wrapper replaced and paths made absolute.
"""
import os, re, sys
here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.dirname(here)
out = os.path.join(here, "build"); os.makedirs(out, exist_ok=True)

src = open(os.path.join(repo, "rtl/tech_cells/gf180/tc_sram.sv")).read()
new, n = re.subn(r"\n\s*\.VDD\s*\(\s*1'b1\s*\),[^\n]*\n\s*\.VSS\s*\(\s*1'b0\s*\)[^\n]*", "", src)
assert n >= 1, "no VDD/VSS connections found"
new = re.sub(r"(\.Q\s*\([^\n]*?\))\s*,(\s*//[^\n]*)?\n(\s*\);)", r"\1\2\n\3", new)
open(os.path.join(out, "tc_sram_oss.sv"), "w").write(new)
print("tc_sram_oss.sv: removed %d VDD/VSS connection pair(s)" % n)

open(os.path.join(out, "sram_blackbox.v"), "w").write("""// port-only stub of the PDK SRAM macro (power pins are connected by OpenROAD)
(* blackbox *)
module gf180mcu_fd_ip_sram__sram512x8m8wm1 (
  input         CLK,
  input         CEN,
  input         GWEN,
  input  [7:0]  WEN,
  input  [8:0]  A,
  input  [7:0]  D,
  output [7:0]  Q
);
endmodule
""")

lines = []
fl = os.path.join(repo, "flists/croc.flist")
for l in open(fl):
    s = l.strip()
    if s.startswith("+incdir+"):
        l = "+incdir+" + os.path.normpath(os.path.join(repo, "flists", s[len("+incdir+"):])) + "\n"
    elif s and not s.startswith("#") and not s.startswith("+"):
        p = os.path.normpath(os.path.join(repo, "flists", s))
        if p.endswith("tech_cells/gf180/tc_sram.sv"):
            p = os.path.join(out, "tc_sram_oss.sv")
        l = p + "\n"
    lines.append(l)
open(os.path.join(out, "croc_oss.flist"), "w").write("".join(lines))
print("croc_oss.flist:", sum(1 for l in lines if l.strip() and not l.startswith(("#", "+"))), "files")
