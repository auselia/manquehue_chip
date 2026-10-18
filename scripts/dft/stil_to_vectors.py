#!/usr/bin/env python3
"""Convert the stuck-at patterns that TestMAX ATPG writes (STIL) into plain vector files for a tester or a simulator.

usage: stil_to_vectors.py patterns_stuck.stil <out dir>

The Pattern block is a list of  Call "load_unload" {scan_si_i=...; scan_so_o=...;}  and  Call "multiclock_capture"
{_pi=...; _po=...;}  statements. One file per quantity, one line per load/unload (574 lines) or capture (573 lines):

  si.mem       scan_si_i, 3964 characters 0/1, first character is shifted in first
  so_exp.mem   scan_so_o expected during that load/unload, 1 where H, 0 where L (value of an X is 0, see so_mask)
  so_mask.mem  1 where the output is compared (H or L), 0 where it is a don't care
  pi.mem       17 inputs at the capture cycle, order of the _pi group (clk_i rst_ni ref_clk_i testmode_i jtag_tck_i
               jtag_tdi_i jtag_tms_i jtag_trst_ni uart_rx_i qspi_sd_i[3:0] gpio_i[1:0] scan_si_i scan_se_i)
  pi_pulse.mem 1 where that input is pulsed in the capture cycle (clk_i: high 50-70 ns, jtag_tck_i: high 75-90 ns,
               rst_ni: low 75-90 ns of the 100 ns cycle); the value in pi.mem is then the rest level (0, 0, 1)
  po_exp.mem   20 outputs strobed at 40 ns of the capture cycle, order of the _po group (status_o jtag_tdo_o uart_tx_o
               qspi_clk_o qspi_sd_o[3:0] qspi_sd_en_o[3:0] qspi_csn_o[2:0] gpio_o[1:0] gpio_out_en_o[1:0] scan_so_o)
  po_mask.mem  1 where compared
"""
import re
import sys

stil, out = sys.argv[1], sys.argv[2]
text = open(stil).read()
body = text[text.index('Pattern "_pattern_"'):]
calls = re.findall(r'Call\s+"(\w+)"\s*\{(.*?)\}', body, re.S)
LEN = 3964


def fields(s):
    return {k: re.sub(r"\s+", "", v) for k, v in re.findall(r'"([\w\[\]]+)"\s*=\s*([^;]*);', s)}


loads, caps = [], []
for name, s in calls:
    f = fields(s)
    if name == "load_unload":
        si = f.get("scan_si_i", "0" * LEN)
        so = f.get("scan_so_o", "X" * LEN)
        assert len(si) == LEN and len(so) == LEN and set(si) <= set("01"), (len(si), len(so))
        loads.append((si, so))
    elif name == "multiclock_capture":
        pi, po = f["_pi"], f["_po"]
        assert len(pi) == 17 and len(po) == 20, (pi, po)
        caps.append((pi, po))
    else:
        raise SystemExit("unexpected procedure " + name)
assert len(loads) == len(caps) + 1, (len(loads), len(caps))


def w(name, lines):
    open(f"{out}/{name}", "w").write("\n".join(lines) + "\n")


w("si.mem", [si for si, _ in loads])
w("so_exp.mem", ["".join("1" if c == "H" else "0" for c in so) for _, so in loads])
w("so_mask.mem", ["".join("1" if c in "HL" else "0" for c in so) for _, so in loads])
REST = {0: "0", 1: "1", 4: "0"}      # rest level of the pulsed inputs: clk_i low, rst_ni high, jtag_tck_i low
w("pi.mem", ["".join(REST[i] if c == "P" else c for i, c in enumerate(pi)) for pi, _ in caps])
w("pi_pulse.mem", ["".join("1" if c == "P" else "0" for c in pi) for pi, _ in caps])
w("po_exp.mem", ["".join("1" if c == "H" else "0" for c in po) for _, po in caps])
w("po_mask.mem", ["".join("1" if c in "HL" else "0" for c in po) for _, po in caps])
pulses = {i for pi, _ in caps for i, c in enumerate(pi) if c == "P"}
bad = {c for pi, _ in caps for c in pi} - set("01P")
print(f"{len(caps)} capture cycles, {len(loads)} load/unloads of {LEN} cells, pulsed inputs (index in _pi): {sorted(pulses)}, other characters: {bad or 'none'}")
