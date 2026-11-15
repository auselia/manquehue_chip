#!/usr/bin/env python3
"""Write the scan-cell include of the parallel-load test bench (sim/tb/tb_atpg.v with +define+PARALLEL).

usage: scan_cells_vh.py scan_cells.rpt croc_soc_atpg.v <out dir>

scan_cells.rpt is `report_scan_cells -all` of TestMAX (atpg.tcl): chain, cell, type, inv, gate, instance (type).
Cell 0 is at scan_so_o. The inversions along the chain come from the netlist: the scan path from the Q of each cell
to the scan input of the next (SI, or D of a plain flop), through buffers, inverters and scan multiplexers.

The serial load does not always move a value by one cell per shift. Each shift cycle pulses clk_i (high 50-70 ns)
and then jtag_tck_i (high 75-90 ns). A cell clocked later in the cycle than the cell before it takes the new value
of that cell, so one value of the string is lost there. This script traces the clock of every cell to its port
through buffers, inverters, clock gates and xor gates with a static input (testmode_i), and gives each cell the time of its clock edge. Then it simulates the
LEN shifts of a load and of an unload on symbols:
  load    the value of every cell after the load, as a bit of the load string (or a constant where it depends only
          on the state before the load, which the patterns do not set)
  unload  for every position of the unload string, the cell whose captured value scan_so_o shows there
The include has three tasks for the test bench:
  par_force(s)    forces the state flop of every cell to its value after load string s. The force is on MGM_D0, the
                  input of the state flop in every cell model (MGM_D0 = ~D after the scan multiplexer, Q = D), so it
                  touches no net outside the cell. One clock with scan_se_i = 1 then loads the chain.
  par_release     releases these forces
  par_read(u)     u = the unload string that scan_so_o would show, from the Q pins of the cells (0 at a position that
                  no captured value reaches: the patterns mask it)
"""
import os
import re
import sys

rpt, netlist, out = sys.argv[1], sys.argv[2], sys.argv[3]
# the inputs that the protocol holds constant during the shift (croc_soc_scan.stil, test_setup)
STATIC = {"testmode_i": 1, "scan_se_i": 1}
EDGE = {("clk_i", 0): 50, ("clk_i", 1): 70, ("jtag_tck_i", 0): 75, ("jtag_tck_i", 1): 90}

cells = []
for line in open(rpt):
    m = re.match(r"\s*(\S+)\s+(\d+)\s+MASTER\s+([NI]{2})\s+\d+\s+(\S+)\s+\((\S+)\)", line)
    if m:
        cells.append((int(m.group(2)), m.group(3)[1] == "I", m.group(4), m.group(5)))
cells.sort()
LEN = len(cells)
assert [c[0] for c in cells] == list(range(LEN)), "cell numbers are not 0 .. LEN-1"

# clock of every cell: follow CLK back through buffers, inverters and clock gates to a port
text = open(netlist).read()
inst, drv = {}, {}
for m in re.finditer(r"(gf180mcu_fd_\w+)\s+(\S+)\s*\((.*?)\)\s*;", text, re.S):
    pins = dict(re.findall(r"\.(\w+)\s*\(\s*(\S+)\s*\)", m.group(3)))
    inst[m.group(2)] = (m.group(1), pins)
    for k in ("Q", "Z", "ZN"):
        if k in pins:
            drv[pins[k]] = m.group(2)
for a, b in re.findall(r"assign\s+(\S+)\s*=\s*(\S+)\s*;", text):
    drv.setdefault(a, ("assign", b))


def edge(net):
    inv = 0
    for _ in range(100):
        if net in ("clk_i", "jtag_tck_i"):
            return EDGE[(net, inv)]
        d = drv.get(net)
        if isinstance(d, tuple):
            net = d[1]
            continue
        if d is None:
            raise SystemExit("clock net %s: no driver and not a clock port" % net)
        typ, pins = inst[d]
        kind = typ.split("__")[1]
        if re.match(r"(clk)?inv_", kind):
            inv ^= 1
            net = pins["I"]
        elif re.match(r"(clk|dly)?buf_|dly[a-z]*_", kind):
            net = pins["I"]
        elif kind.startswith("icg"):
            net = pins["CLK"]
        elif re.match(r"x(n)?or2_", kind) and STATIC.get(pins["A2"]) is not None:
            # a gate with a pin that is static in test mode: xor inverts the clock when that pin is 1, xnor when it is 0
            inv ^= STATIC[pins["A2"]] ^ kind.startswith("xnor")
            net = pins["A1"]
        elif re.match(r"x(n)?or2_", kind) and STATIC.get(pins["A1"]) is not None:
            inv ^= STATIC[pins["A1"]] ^ kind.startswith("xnor")
            net = pins["A2"]
        else:
            raise SystemExit("clock net %s: driven by %s (%s), not a buffer, inverter or clock gate" % (net, d, kind))
    raise SystemExit("clock net %s: no port after 100 cells" % net)


t = [edge(inst[c[2]][1]["CLK"]) for c in cells]


def static(net):
    # value of a net that only depends on the static inputs, or None
    inv = 0
    for _ in range(100):
        if net in STATIC:
            return STATIC[net] ^ inv
        d = drv.get(net)
        if isinstance(d, tuple):
            net = d[1]
            continue
        if d is None:
            return None
        typ, pins = inst[d]
        kind = typ.split("__")[1]
        if re.match(r"(clk)?inv_", kind):
            inv ^= 1
        elif not re.match(r"(clk|dly)?buf_|dly[a-z]*_", kind):
            return None
        net = pins["I"]
    return None


def scan_path(net, stop):
    # inversion from a net in `stop` (a Q net of the chain or a port) to `net`, through buffers, inverters and scan
    # multiplexers (mux2 with a static select). Returns (start net, inversion).
    inv = 0
    for _ in range(100):
        if net in stop:
            return net, inv
        d = drv.get(net)
        if isinstance(d, tuple):
            net = d[1]
            continue
        if d is None:
            raise SystemExit("scan path at %s: no driver" % net)
        typ, pins = inst[d]
        kind = typ.split("__")[1]
        if re.match(r"(clk)?inv_", kind):
            inv ^= 1
            net = pins["I"]
        elif re.match(r"(clk|dly)?buf_|dly[a-z]*_", kind):
            net = pins["I"]
        elif kind.startswith("mux2") and static(pins["S"]) is not None:
            net = pins["I1"] if static(pins["S"]) else pins["I0"]
        else:
            raise SystemExit("scan path at %s: driven by %s (%s)" % (net, d, kind))
    raise SystemExit("scan path at %s: too long" % net)


# inversion from scan_si_i to every cell, from the netlist (the inv column of the report is not used)
qnet = [inst[c[2]][1]["Q"] for c in cells]
scan_in = []
for c in cells:
    pins = inst[c[2]][1]
    scan_in.append(pins["SI"] if "SI" in pins else pins["D"])
invsi = [0] * LEN
start, inv = scan_path(scan_in[LEN - 1], {"scan_si_i"})
assert start == "scan_si_i", start
invsi[LEN - 1] = inv
for p in range(LEN - 2, -1, -1):
    start, inv = scan_path(scan_in[p], {qnet[p + 1]})
    invsi[p] = invsi[p + 1] ^ inv
start, inv_out = scan_path("scan_so_o", {qnet[0]})
report_bad = sum(1 for p in range(LEN) if invsi[p] != cells[p][1])


# one shift: cell p takes cell p+1 (scan_si_i for the last cell), the new value if that cell is clocked earlier
def shift(state, si_sym):
    new = [None] * LEN
    for p in range(LEN - 1, -1, -1):
        if p == LEN - 1:
            src, sinv = si_sym, invsi[p]
        else:
            src = new[p + 1] if t[p + 1] < t[p] else state[p + 1]
            sinv = invsi[p] ^ invsi[p + 1]
        new[p] = None if src is None else (src[0], src[1] ^ sinv)
    return new


# load: symbol ("s", j) is bit j of the load string, None is the state before the load
state = [None] * LEN
for j in range(LEN):
    state = shift(state, (("s", j), 0))
load = state
# unload: symbol ("c", p) is the captured value of cell p, observed at scan_so_o (inversion of cell 0 to the output)
state = [(("c", p), 0) for p in range(LEN)]
unload = []
for j in range(LEN):
    v = state[0]
    unload.append(None if v is None else (v[0], v[1] ^ inv_out))
    state = shift(state, None)

lost = sum(v is None for v in load)
moved = sum(1 for p, v in enumerate(load) if v is not None and v[0][1] != p)
force, release, read = [], [], []
for p in range(LEN):
    _, _, name, typ = cells[p]
    pin = "%s.%s_inst.MGM_D0" % (name, typ.rsplit("_", 1)[0])
    v = load[p]
    cond = "1'b0" if v is None else ("%ss[%d]" % ("~" if v[1] else "", v[0][1]))
    # Icarus evaluates the right side of a procedural force only once, so each cell gets a constant (MGM_D0 = ~value)
    force.append("    if (%s) force dut.%s = 1'b0; else force dut.%s = 1'b1;\n" % (cond, pin, pin))
    release.append("    release dut.%s;\n" % pin)
for j in range(LEN):
    v = unload[j]
    if v is None:
        read.append("    u[%d] = 1'b0;\n" % j)
    else:
        read.append("    u[%d] = %sdut.%s.Q;\n" % (j, "~" if v[1] else "", cells[v[0][1]][2]))
vh = ("// GENERATED by scripts/signoff/dft/scan_cells_vh.py from %s; do not edit.\n" % os.path.basename(rpt) +
      "localparam integer PAR_LEN = %d;\n" % LEN +
      "task par_force(input [0:PAR_LEN-1] s);\n  begin\n" + "".join(force) + "  end\nendtask\n" +
      "task par_release;\n  begin\n" + "".join(release) + "  end\nendtask\n" +
      "task par_read(output [0:PAR_LEN-1] u);\n  begin\n" + "".join(read) + "  end\nendtask\n")
open(os.path.join(out, "tb_atpg_cells.vh"), "w").write(vh)
times = {}
for x in t:
    times[x] = times.get(x, 0) + 1
print("%d scan cells, clock edges at %s ns, %d cells take a moved bit, %d cells load no bit of the string, "
      "%d unload positions show no cell, inversion differs from the report at %d cells"
      % (LEN, dict(sorted(times.items())), moved, lost, sum(v is None for v in unload), report_bad))
