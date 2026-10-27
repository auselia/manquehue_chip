#!/usr/bin/env python3
"""Write rtl/chip/chip_top.sv: the netlist top of the chip floorplan (CHIP_FLOORPLAN=1).

usage: scripts/chip/gen_chip_top.py   (from the repository root; make chip_top)

Input: scripts/chip/padring.txt, the pad ring that scripts/chip/chip_floorplan.tcl places. One instance per pad
(pad_<signal>) and per breaker, and croc_soc (i_croc):
  - CROC pads (table PINS): connected to croc_soc, with the pull of the wafer.space template
    (waferspace_manquehue scripts/gen_chip_top.py). Input enables of the bidirectional pads: ~output enable.
  - unused and scan pads of the CROC segment: input and output off, pulled down. The scan pads are connected when the
    scan chain is inserted at chip level.
  - DC-DC pads: only PAD is connected. The core-side pins stay open: the DC-DC wrappers drive them by abutment.
  - supply pads and breakers: no connections. FC connects the supply pins of every IO cell (chip/chip_pg_pads.tcl).
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "scripts" / "chip" / "padring.txt"
DST = ROOT / "rtl" / "chip" / "chip_top.sv"

# pad signal -> (kind, croc nets, pull). kind: in (in_c/in_s), bin (bi_24t input), bout (bi_24t output),
# bio (bi_24t bidirectional: out, oe, in). pull: pu or pd for an input that must not float.
PINS = {
    "clk_i":        ("in",   ["clk_i"], None),
    "rst_ni":       ("in",   ["rst_ni"], None),
    "ref_clk_i":    ("in",   ["ref_clk_i"], None),
    "testmode_i":   ("in",   ["testmode_i"], "pd"),     # an open pad keeps the chip out of test mode
    "jtag_tck_i":   ("in",   ["jtag_tck_i"], None),
    "jtag_trst_ni": ("in",   ["jtag_trst_ni"], None),
    "rf_dio0_i":    ("in",   ["rf_dio0_i"], "pd"),
    "jtag_tdi_i":   ("bin",  ["jtag_tdi_i"], "pu"),
    "jtag_tms_i":   ("bin",  ["jtag_tms_i"], "pu"),
    "uart_rx_i":    ("bin",  ["uart_rx_i"], "pu"),      # UART idles high
    "afe_irq_i":    ("bin",  ["afe_irq_i"], "pu"),      # WAKE_N, active low
    "spi_sd_i":     ("bin",  ["spi_sd_i"], "pd"),       # both devices release it while their CS is high
    "status_o":     ("bout", ["status_o"], None),
    "jtag_tdo_o":   ("bout", ["jtag_tdo_o"], None),
    "uart_tx_o":    ("bout", ["uart_tx_o"], None),
    "qspi_clk_o":   ("bout", ["qspi_clk_o"], None),
    "qspi_cs0_o":   ("bout", ["qspi_csn_o[0]"], None),
    "qspi_cs1_o":   ("bout", ["qspi_csn_o[1]"], None),
    "qspi_cs2_o":   ("bout", ["qspi_csn_o[2]"], None),
    "spi_sck_o":    ("bout", ["spi_sck_o"], None),
    "spi_sd_o":     ("bout", ["spi_sd_o"], None),
    "spi_cs0_o":    ("bout", ["spi_cs0_o"], None),
    "spi_cs1_o":    ("bout", ["spi_cs1_o"], None),
    "rf_rstn_o":    ("bout", ["rf_rstn_o"], None),
    "qspi_sd0_io":  ("bio",  ["qspi_sd_o[0]", "qspi_sd_en_o[0]", "qspi_sd_i[0]"], None),
    "qspi_sd1_io":  ("bio",  ["qspi_sd_o[1]", "qspi_sd_en_o[1]", "qspi_sd_i[1]"], None),
    "qspi_sd2_io":  ("bio",  ["qspi_sd_o[2]", "qspi_sd_en_o[2]", "qspi_sd_i[2]"], None),
    "qspi_sd3_io":  ("bio",  ["qspi_sd_o[3]", "qspi_sd_en_o[3]", "qspi_sd_i[3]"], None),
    "gpio0_io":     ("bio",  ["gpio_o[0]", "gpio_out_en_o[0]", "gpio_i[0]"], None),
    "gpio1_io":     ("bio",  ["gpio_o[1]", "gpio_out_en_o[1]", "gpio_i[1]"], None),
}
RESERVED = {"scan_in_i", "scan_en_i", "scan_out_o"}   # CROC segment, off until the chip-level scan chain
CROC_PADS = range(27, 73)                             # CROC segment of the ring (breakers brk_w0 and brk_e0)
SUPPLY = {"dvdd", "dvss"}

pads, brks = [], []
for line in SRC.read_text().splitlines():
    f = line.split()
    if not f or f[0].startswith("#"):
        continue
    if f[0] == "pad":
        pads.append((int(f[1]), f[2], f[3]))
    elif f[0] == "brk":
        brks.append((f[1], int(f[2])))

# croc nets: name -> width
NETS = {}
for kind, nets, _ in PINS.values():
    for n in nets:
        m = re.match(r"(\w+)(?:\[(\d+)\])?$", n)
        NETS[m.group(1)] = max(NETS.get(m.group(1), 1), int(m.group(2) or 0) + 1)
IE = {"qspi_sd_en_o": "qspi_sd_ie", "gpio_out_en_o": "gpio_ie"}


def c(net):
    return "c_" + net


def ie_of(en):
    m = re.match(r"(\w+)\[(\d+)\]$", en)
    return "%s[%s]" % (c(IE[m.group(1)]), m.group(2))


def bi(sig, a, oe, ie, pu, pd, y):
    return ("        .A   (%s),\n        .OE  (%s),\n        .CS  (1'b0),\n        .SL  (1'b0),\n"
            "        .IE  (%s),\n        .PU  (%s),\n        .PD  (%s),\n        .Y   (%s),\n"
            "        .PAD (%s)" % (a, oe, ie, pu, pd, y, sig))


ports, body, done = [], [], set()
for n, sig, cell in pads:
    master = "gf180mcu_fd_io__" + cell
    if cell in SUPPLY:
        body.append("    // pad %d: %s supply pad\n    (* keep *) %s pad_%s ();\n" % (n, sig, master, sig))
        continue
    direction = "input " if cell in ("in_c", "in_s") else "inout "
    ports.append("    %s wire %s" % (direction, sig))
    if sig in PINS:
        kind, nets, pull = PINS[sig]
        if (kind == "in") != (cell in ("in_c", "in_s")) or (kind != "in" and cell != "bi_24t"):
            raise SystemExit("gen_chip_top.py: pad %d %s is %s, not a %s pad" % (n, sig, cell, kind))
        pu = "1'b1" if pull == "pu" else "1'b0"
        pd = "1'b1" if pull == "pd" else "1'b0"
        nets = [c(x) for x in nets]
        if kind == "in":
            conn = "        .PU  (%s),\n        .PD  (%s),\n        .Y   (%s),\n        .PAD (%s)" % (pu, pd, nets[0], sig)
        elif kind == "bin":
            conn = bi(sig, "1'b0", "1'b0", "1'b1", pu, pd, nets[0])
        elif kind == "bout":
            conn = bi(sig, nets[0], "1'b1", "1'b0", pu, pd, "")
        else:
            conn = bi(sig, nets[0], nets[1], ie_of(PINS[sig][1][1]), pu, pd, nets[2])
        what = "croc_soc"
        done.add(sig)
    elif n in CROC_PADS:
        if cell != "bi_24t":
            raise SystemExit("gen_chip_top.py: spare pad %d %s is %s, not bi_24t" % (n, sig, cell))
        conn = bi(sig, "1'b0", "1'b0", "1'b0", "1'b0", "1'b1", "")
        what = "scan pad, off until the chip-level scan chain" if sig in RESERVED else "spare pad, off"
    else:
        pin = "ASIG5V" if cell == "asig_5p0" else "PAD"
        conn = "        .%s (%s)" % (pin, sig)
        what = "DC-DC pad, core side driven by the DC-DC wrapper"
    body.append("    // pad %d: %s (%s)\n    (* keep *) %s pad_%s (\n%s\n    );\n" % (n, sig, what, master, sig, conn))

for brk, n in brks:
    body.append("    // ring breaker after pad %d: cuts DVDD, DVSS and VDD, VSS runs through\n"
                "    (* keep *) gf180mcu_fd_io__brk5 %s ();\n" % (n, brk))

missing = set(PINS) - done
if missing:
    raise SystemExit("gen_chip_top.py: croc pins without a pad: %s" % ", ".join(sorted(missing)))

decl = "".join("    wire %s%s;\n" % ("[%d:0] " % (w - 1) if w > 1 else "", c(n)) for n, w in NETS.items())
decl += "    wire [3:0] %s = ~%s;\n" % (c("qspi_sd_ie"), c("qspi_sd_en_o"))
decl += "    wire [1:0] %s = ~%s;\n" % (c("gpio_ie"), c("gpio_out_en_o"))
croc = "    croc_soc i_croc (\n" + ",\n".join("        .%-14s (%s)" % (n, c(n)) for n in NETS) + "\n    );\n"

out = ("// GENERATED by scripts/chip/gen_chip_top.py from scripts/chip/padring.txt; do not edit.\n"
       "// Chip top of the croc flow (CHIP_FLOORPLAN=1): the AC3E pad ring and croc_soc on its CROC pads.\n\n"
       "module chip_top (\n" + ",\n".join(ports) + "\n);\n\n"
       "    // core side of the CROC pads\n" + decl + "\n" + "".join(body) + "\n" + croc + "\nendmodule\n")
DST.parent.mkdir(parents=True, exist_ok=True)
DST.write_text(out)
print("wrote %s: %d pads, %d breakers, %d croc pins on pads" % (DST.relative_to(ROOT), len(pads), len(brks), len(done)))
