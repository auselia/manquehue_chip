#!/usr/bin/env python3
"""Make testbench variants of tb_atpg.v with one stuck-at defect forced on a net of the netlist (diagnosis demo).
usage: make_faults.py <patterns_stuck.stil> <croc_soc_atpg.v> <tb_atpg.v> <out dir>"""
import re
import sys

stil = open(sys.argv[1]).read()
net = open(sys.argv[2]).read()
tb = open(sys.argv[3]).read()
out = sys.argv[4]
blk = stil[stil.index("ScanCells {"):]
blk = blk[:blk.index("}")]
cells = [m.group(1).split(".", 1)[-1] for m in re.finditer(r'"([^"]+)"\s*\n?\s*[A-Z]_;', blk)]

def pins(inst):
    m = re.search(r"^\S+\s+" + re.escape(inst) + r"\s*\((.*?)\)\s*;", net, re.M | re.S)
    return dict(re.findall(r"\.(\w+)\s*\(\s*([^)\s]+)\s*\)", m.group(1)))

plain = lambda n: re.fullmatch(r"[A-Za-z_]\w*", n) is not None
cases = []
# A: a flop output stuck at 1 (functional logic or the cell itself), chain index 2500
# B: the scan input of a flop stuck at 0: a break of the scan path, chain index 1500
# C: the data input net of a flop stuck at 0 (capture-side defect), chain index 800
for tag, idx, pin, val in (("a_q_sa1", 2500, "Q", 1), ("b_scanpath_sa0", 1500, "SI", 0), ("c_d_sa0", 800, "D", 0)):
    i = idx
    while True:
        p = pins(cells[i])
        if pin in p and plain(p[pin]):
            break
        i += 1
    cases.append((tag, i, cells[i], pin, p[pin], val))
    t = tb.replace("  wire [19:0] po =", f"  initial force dut.{p[pin]} = 1'b{val};   // injected defect: {tag}\n  wire [19:0] po =", 1)
    assert t != tb
    open(f"{out}/tb_atpg_{tag}.v", "w").write(t.replace("module tb_atpg;", f"module tb_atpg_{tag};"))
for c in cases:
    print("%-16s chain index %4d  cell %-60s pin %-3s net %-40s stuck-at-%d" % c)
