#!/usr/bin/env python3
"""Locate a scan-test failure from the FAIL lines of tb_atpg.v (or of a tester log in the same form).

usage: diagnose.py <patterns_stuck.stil> <log> [<log> ...] [--tmax <failure file to write for run_diagnosis>]

A FAIL line is   FAIL kind=shift|capture pat=<k> j=<shift cycle> bit=<output bit> exp=<0|1> got=<0|1|x>
  kind=shift   scan_so_o differs while the unload of pattern k-1 is shifted out (load/unload k). Shift cycle j delivers
               the cell with chain index (LEN-1-j) where index 0 is the cell next to scan_si_i (order of ScanCells).
  kind=capture an output pin differs in the capture cycle of pattern k (bit order of the _po group).
"""
import collections
import re
import sys

PO = "status_o jtag_tdo_o uart_tx_o qspi_clk_o qspi_sd_o[3] qspi_sd_o[2] qspi_sd_o[1] qspi_sd_o[0] qspi_sd_en_o[3] " \
     "qspi_sd_en_o[2] qspi_sd_en_o[1] qspi_sd_en_o[0] qspi_csn_o[2] qspi_csn_o[1] qspi_csn_o[0] gpio_o[1] gpio_o[0] " \
     "gpio_out_en_o[1] gpio_out_en_o[0] scan_so_o".split()

args = sys.argv[1:]
tmax_out = None
if "--tmax" in args:
    i = args.index("--tmax")
    tmax_out = args[i + 1]
    del args[i:i + 2]
stil = open(args[0]).read()
block = stil[stil.index("ScanCells {"):]
block = block[:block.index("}")]
cells = [m.group(1).split(".", 1)[-1] for m in re.finditer(r'"([^"]+)"\s*\n?\s*[A-Z]_;', block)]
L = len(cells)
print(f"chain: {L} cells (index 0 next to scan_si_i, {L-1} next to scan_so_o)")

fails = []
for p in args[1:]:
    for line in open(p):
        m = re.match(r"FAIL kind=\s*(\w+) pat=(\d+) j=(\d+) bit=(\d+) exp=(\S) got=(\S)", line)
        if m:
            fails.append((m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4)), m.group(5), m.group(6)))
if not fails:
    print("no FAIL lines: nothing to locate")
    sys.exit(0)

if tmax_out:
    # pattern-based failure file of TestMAX ATPG: pattern_num output_port [cell_position]. Pattern k is the one whose
    # capture is unloaded in load/unload k+1, the cell position is the shift cycle j of the unload
    with open(tmax_out, "w") as fo:
        seen = set()
        for kind, pat, j, bit, e, g in fails:
            line = f"{pat - 1} scan_so_o {j}" if kind == "shift" else f"{pat} {PO[bit]}"
            if line not in seen:
                seen.add(line)
                fo.write(line + "\n")
    print(f"wrote {tmax_out} (pattern-based failure file for run_diagnosis)")

shift = [f for f in fails if f[0] == "shift"]
cap = [f for f in fails if f[0] == "capture"]
print(f"{len(fails)} failing output values: {len(shift)} on scan_so_o during unload, {len(cap)} on outputs in capture")

if cap:
    c = collections.Counter(PO[f[3]] for f in cap)
    print("failing outputs in capture cycles:", ", ".join(f"{k} x{v}" for k, v in c.most_common()))

if shift:
    byidx = collections.defaultdict(list)
    for _, pat, j, bit, e, g in shift:
        byidx[L - 1 - j].append((pat - 1, e, g))     # capture of pattern pat-1 is what is unloaded in load/unload pat
    pats = sorted({f[1] for f in shift})
    print(f"unload failures in load/unloads {pats[0]}..{pats[-1]}; {len(byidx)} different chain positions")
    print("most frequent failing cells (chain index, cell, patterns failing, values expected -> read):")
    for idx, v in sorted(byidx.items(), key=lambda kv: -len(kv[1]))[:12]:
        vals = collections.Counter(f"{e}->{g}" for _, e, g in v)
        print(f"  {idx:5d}  {cells[idx]:70s} x{len(v):3d}  {dict(vals)}")
    # A defect on the scan path breaks the load too, so the captured state is wrong everywhere and the failing cells
    # carry no position information: the signature is many failing cells, in every pattern, nearly all read as the same value.
    top = collections.Counter(g for _, _, _, _, _, g in shift).most_common(1)[0]
    if len(byidx) > 200 and top[1] > 0.9 * len(shift):
        print(f"-> scan path defect: {len(byidx)} different cells fail and {100 * top[1] // len(shift)} % of the failing reads are "
              f"{top[0]}. The cell names above are not the defect. Locate it by simulation: "
              f"run_diagnosis <failure file> -chain_failure (--tmax writes the file)")
        sys.exit(0)
    jmin = min(f[2] for f in shift)
    idxmax = L - 1 - jmin
    lo = min(byidx)
    # a defect on the scan path leaves every cell upstream of it with the same read value
    stuck = collections.Counter(g for _, _, _, _, _, g in shift)
    print(f"failing positions run from chain index {lo} to {idxmax}; read values on scan_so_o: {dict(stuck)}")
    if len(byidx) > 20 and len(stuck) == 1:
        print(f"-> looks like a scan-path break or stuck path: scan_so_o is stuck at {list(stuck)[0]} for chain index "
              f"<= {idxmax}; the defect is at or just after cell {idxmax}: {cells[idxmax]}")
    elif len(byidx) <= 20:
        print("-> isolated cells fail: a capture-side defect in the logic cone of the cells above (D input cone), "
              "or in the cell itself; intersect the cones of the listed cells to narrow it down")
