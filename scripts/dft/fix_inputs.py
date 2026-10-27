#!/usr/bin/env python3
"""Turn the Fusion Compiler outputs in this folder into inputs that TestMAX ATPG (TetraMAX) accepts.

usage: fix_inputs.py <netlist.v> <protocol.stil> <out dir> <scan length>

Netlist (what the tool complained about, in this order):
  - one comment line of 80 000 characters in the header (limit is 50 000)      -> comment lines dropped
  - power pins .VDD/.VSS on standard cells; the PDK simulation models have none  -> connections dropped
  - fillcap decoupling cells (only power pins, no logic, no model)               -> instances dropped
Protocol (`write_test_protocol` writes only the capture procedures, "Minimal STIL"):
  - no ScanStructures and no load_unload, so the tool sees every scan flop as nonscan  -> both added
  - scan_se_i is 0 in every capture procedure
The chain length is checked by the tool itself ("Chain c1 successfully traced with N scan_cells").
"""
import re
import sys

net, stil, out = sys.argv[1], sys.argv[2], sys.argv[3]
length = int(sys.argv[4])                # run_dft.sh: from the synthesis log of the run

s = "".join(l for l in open(net) if not l.startswith("//"))
s = re.sub(r",\s*\.VDD\s*\(\s*VDD\s*\)", "", s)
s = re.sub(r",\s*\.VSS\s*\(\s*VSS\s*\)", "", s)
s, n_fill = re.subn(r"^gf180mcu_fd_sc_mcu7t5v0__fillcap_\d+\s+\S+\s*\([^;]*?\)\s*;\s*\n", "", s, flags=re.M | re.S)
left = len(re.findall(r"\.V(?:DD|SS)\s*\(", s))
open(out + "/croc_soc_atpg.v", "w").write(s)
print(f"netlist: {n_fill} fillcap instances removed, {left} power pin connections left")

p = open(stil).read()
structures = f'''ScanStructures {{
    ScanChain "c1" {{
        ScanLength {length};
        ScanIn "scan_si_i";
        ScanOut "scan_so_o";
    }}
}}
'''
load_unload = '''    "load_unload" {
        W "_default_WFT_";
        C {
            "all_inputs" = 01N10 \\r12 N ;
            "all_outputs" = \\r20 X ;
        }
        V {
            "clk_i" = 0;
            "jtag_tck_i" = 0;
            "scan_se_i" = 1;
            "testmode_i" = 1;
            "rst_ni" = 1;
        }
        Shift {
            V {
                "clk_i" = P;
                "jtag_tck_i" = P;
                "scan_si_i" = #;
                "scan_so_o" = #;
            }
        }
    }
'''
assert "\nProcedures {" in p and "ScanStructures" not in p
p = p.replace("\nProcedures {\n", "\n" + structures + "Procedures {\n" + load_unload, 1)
p, n_f = re.subn(r'(        F \{\n            "testmode_i" = 1;\n)', r'\1            "scan_se_i" = 0;\n', p)
open(out + "/croc_soc_scan.stil", "w").write(p)
print(f"protocol: ScanStructures + load_unload added, scan_se_i = 0 in {n_f} capture procedures")
