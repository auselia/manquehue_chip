#!/usr/bin/env python3
"""Trace the scan chain of the croc_soc netlist from scan_so_o back to scan_si_i.

usage: scan_chain_trace.py <croc_soc.v>
prints: cells=<scan cells + non-scan cells> scan=<N> nonscan=<M> inversions=<K>

The chain runs through the SI pin of each scan flop. Fusion Compiler keeps registers that already shift (shift
register identification) as non-scan flops inside the chain, reached through their functional D pin. Between two
cells there can be buffers and inverters (high-fanout repair). An odd number of inverters makes the chain return
the shifted stream inverted, which scripts/sim/run_gls_scan.sh passes to rtl/test/tb_scan_shift.sv.
"""
import re
import sys

t = open(sys.argv[1]).read()
drv, insts = {}, {}
for m in re.finditer(r"^(gf180mcu_fd_sc_mcu7t5v0__\w+)\s+(\S+)\s*\((.*?)\)\s*;", t, re.M | re.S):
    cell, inst, body = m.groups()
    pins = dict(re.findall(r"\.(\w+)\s*\(\s*([^)\s]+)\s*\)", body))
    insts[inst] = (cell, pins)
    for out in ("Q", "QN", "Z", "ZN"):
        if out in pins:
            drv[pins[out]] = (inst, out)

net, scan, nonscan, inv = "scan_so_o", 0, 0, 0
while net != "scan_si_i":
    if net not in drv:
        sys.exit("scan_chain_trace.py: no driver for net %s" % net)
    inst, out = drv[net]
    cell, pins = insts[inst]
    if out in ("QN", "ZN"):
        inv += 1
    signal = [k for k in pins if k not in ("VDD", "VSS", "Q", "QN", "Z", "ZN")]
    if "SI" in pins:
        scan += 1
        net = pins["SI"]
    elif "D" in pins:
        nonscan += 1
        net = pins["D"]
    elif signal == ["I"]:
        net = pins["I"]
    else:
        sys.exit("scan_chain_trace.py: chain leaves through %s (%s), pins %s" % (inst, cell, signal))
print("cells=%d scan=%d nonscan=%d inversions=%d" % (scan + nonscan, scan, nonscan, inv))
