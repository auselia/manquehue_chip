#!/bin/bash
# Inputs of an ATPG run from a Fusion Compiler run: netlist, cell models, SRAM black box. Nothing needs the ATPG tool.
# usage: RUN=<run> OUT=<dir> scripts/dft/prepare_inputs.sh
set -e
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../utils/env.sh"
OUT=${OUT:?output dir}; mkdir -p "$OUT"
V=$PDK_ROOT/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/verilog
export RUN OUT V HERE
python3 - <<'PY'
import os, re
run, out, v, here = os.environ["RUN"], os.environ["OUT"], os.environ["V"], os.environ["HERE"]
t = open(run + "/croc_soc.v").read()
t = t.replace(" , VDD , VSS ) ;", " ) ;", 1)               # power ports are not logic for the ATPG tool
t = t.replace("input  VDD ;\n", "", 1).replace("input  VSS ;\n", "", 1)
open(out + "/croc_soc_atpg.v", "w").write(t)
c = open(v + "/gf180mcu_fd_sc_mcu7t5v0.v").read().replace("buf (weak0, weak1)", "buf")
open(out + "/cells_atpg.v", "w").write(c)
open(out + "/primitives_atpg.v", "w").write(open(v + "/primitives.v").read())
open(out + "/sram_blackbox.v", "w").write(open(here + "/sram_blackbox.v").read())
used = set(re.findall(r"^\s*(gf180mcu_fd_\w+)\s+\S+\s*\(", t, re.M))
have = set(re.findall(r"^\s*module\s+(gf180mcu_fd_\w+)", c + open(out + "/sram_blackbox.v").read(), re.M))
print("cell types used:", len(used), " missing from the models:", sorted(used - have)[:5])
PY
