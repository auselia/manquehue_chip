#!/bin/bash
# Inputs for an ATPG run on the AUS-106 netlist. Nothing here needs the ATPG tool.
set -e
cd /tmp/aus106/atpg
RUN=$(readlink -f /tmp/aus106/outputs/latest)
V=$HOME/.ciel/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/verilog
python3 - <<PY
import re, os
run, v = "$RUN", "$V"
t = open(run + "/croc_soc.v").read()
# power ports are not logic: the ATPG tool sees supply nets as constants
t = t.replace(" , VDD , VSS ) ;", " ) ;", 1)
t = t.replace("input  VDD ;\n", "", 1).replace("input  VSS ;\n", "", 1)
# SRAM power pins connect to the supply nets of the netlist: keep them, the stub declares them
open("croc_soc_atpg.v", "w").write(t)
c = open(v + "/gf180mcu_fd_sc_mcu7t5v0.v").read().replace("buf (weak0, weak1)", "buf")
open("cells_atpg.v", "w").write(c)
open("primitives_atpg.v", "w").write(open(v + "/primitives.v").read())
open("sram_blackbox.v", "w").write("""// port-only model of the SRAM macro: the ATPG tool treats it as a black box (outputs unknown)
module gf180mcu_fd_ip_sram__sram512x8m8wm1 (CLK, CEN, GWEN, WEN, A, D, Q, VDD, VSS);
  input CLK, CEN, GWEN;
  input [7:0] WEN;
  input [8:0] A;
  input [7:0] D;
  output [7:0] Q;
  inout VDD, VSS;
endmodule
""")
# every cell type of the netlist must exist in the models
used = set(re.findall(r"^\s*(gf180mcu_fd_\w+)\s+\S+\s*\(", t, re.M))
have = set(re.findall(r"^\s*module\s+(gf180mcu_fd_\w+)", c + open("sram_blackbox.v").read(), re.M))
print("cell types used:", len(used), " missing from the models:", sorted(used - have)[:5])
print("flops (dff*):", sum(1 for u in used if "__dff" in u or "__sdff" in u), "types")
PY
ls -la
