#!/bin/bash
# Zero-delay gate-level simulation of the netlist of a run in Verilator, with the SoC test bench and a program
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/gls/verilator.sh <program.hex> <work dir>      (inside the nix-shell of the template)
# in:  env GLS_RUN (default outputs/latest), GLS_PLUSARGS (for example +flash=<hex>), GLS_TIMEOUT (s, default 7200),
#      FLOPDELAY (default 0.5ns, see gate_models.py), GLS_CXX, JOBS, PDK_ROOT
# out: <work dir>/run.log (the test bench output), build.log, run.status
#
# The program must fit the 2 KB SRAM. The test bench has no waveform dump here (TRACE_WAVE): a trace writes tens of GB.
# Keep the output line-buffered (stdbuf -oL), or it is lost when the run is killed.
set -e
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
run_dir=$(readlink -f "${GLS_RUN:-$repo/outputs/latest}")
program=$(readlink -f "${1:?usage: verilator.sh <program.hex> <work dir>}")
work=${2:?usage: verilator.sh <program.hex> <work dir>}
pdk=${PDK_ROOT:-$HOME/.ciel}/gf180mcuD/libs.ref
cell_models=$pdk/gf180mcu_fd_sc_mcu7t5v0/verilog
sram_models=$pdk/gf180mcu_fd_ip_sram/verilog
# g++ with -fcoroutines for Verilator --timing (the system g++ 8.5 of Rocky has none)
cxx=${GLS_CXX:-/nix/store/vr15iyyykg9zai6fpgvhcgyw7gckl78w-gcc-wrapper-14.3.0/bin/g++}
models=$repo/scripts/signoff/gate_models.py

mkdir -p "$work"
cd "$work"
python3 "$models" netlist "$run_dir/croc_soc.v" croc_soc_gls.v --no-supply-ports
python3 "$models" cells "$cell_models/gf180mcu_fd_sc_mcu7t5v0.v" cells.v --no-keeper --flop-delay "${FLOPDELAY:-0.5ns}"
python3 "$models" sram "$sram_models/gf180mcu_fd_ip_sram__sram512x8m8wm1.v" sram.v

cat > files.f <<EOF2
+incdir+$repo/rtl/apb/include
+incdir+$repo/rtl/common_cells/include
+incdir+$repo/rtl/cve2/include
+incdir+$repo/rtl/idma/include
+incdir+$repo/rtl/obi/include
+define+TARGET_FLIST
+define+TARGET_GLS
+define+FUNCTIONAL
+define+USE_POWER_PINS
+define+VERILATOR=1
+define+COMMON_CELLS_ASSERTS_OFF=1
$repo/rtl/common_verification/clk_rst_gen.sv
$repo/rtl/common_cells/cf_math_pkg.sv
$repo/rtl/riscv-dbg/dm_pkg.sv
$repo/rtl/riscv-dbg/tb/jtag_test_simple.sv
$repo/rtl/obi/obi_pkg.sv
$repo/rtl/croc_pkg.sv
$repo/rtl/user_pkg.sv
$repo/rtl/soc_ctrl/soc_ctrl_regs_pkg.sv
$repo/rtl/gpio/gpio_reg_pkg.sv
$repo/rtl/clint/clint_reg_pkg.sv
$repo/rtl/obi_timer/obi_timer_reg_pkg.sv
$repo/sim/tb/tb_croc_pkg.sv
$repo/sim/tb/croc_vip.sv
$repo/sim/models/ads7057_model.v
$repo/sim/models/spi_flash_model.v
$repo/sim/models/spi_psram_model.v
$repo/sim/models/sx1276_model.v
$repo/sim/models/sx1262_model.v
$repo/sim/tb/tb_croc_soc.sv
$cell_models/primitives.v
$work/cells.v
$work/sram.v
$work/croc_soc_gls.v
EOF2

verilator --binary -MAKEFLAGS "CXX=$cxx LINK=$cxx" -j "${JOBS:-8}" -Wno-fatal -Wno-lint -Wno-style \
  -Wno-SPECIFYIGN --timing -f files.f --top-module tb_croc_soc -o Vgls > build.log 2>&1 \
  || { echo "verilator build failed, see $work/build.log"; exit 1; }

echo "run start $(date +%T)" > run.status
set +e
# shellcheck disable=SC2086  # GLS_PLUSARGS is a list of plusargs
( time timeout "${GLS_TIMEOUT:-7200}" stdbuf -oL ./obj_dir/Vgls +binary="$program" ${GLS_PLUSARGS:-} ) > run.log 2>&1
echo "run end $(date +%T) rc=$?" >> run.status
tail -n 15 run.log
