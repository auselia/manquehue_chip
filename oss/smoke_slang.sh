#!/bin/bash
# Phase 0 check: Yosys + slang elaborates croc_soc from the open-flow flist (std cells and SRAM macro as blackboxes)
source "$(dirname "$0")/env.sh"
python3 "$OSS_DIR/prep_rtl.py" > /dev/null || exit 1
mkdir -p /tmp/oss_smoke
SC=$STD_LIB_DIR/lib/${SCL}__tt_025C_5v00.lib
yosys -q -p "plugin -i slang; read_liberty -lib $SC; read_verilog -lib $OSS_DIR/build/sram_blackbox.v; read_slang --top croc_soc -F $OSS_DIR/build/croc_oss.flist --compat-mode --keep-hierarchy; hierarchy -top croc_soc; tee -o /tmp/oss_smoke/stat.rpt stat -width; write_verilog -noattr /tmp/oss_smoke/croc_soc_elab.v" > /tmp/oss_smoke/slang.log 2>&1
echo "rc=$?"; tail -12 /tmp/oss_smoke/slang.log | cut -c1-200; grep -E "Number of cells|sram512|ports" /tmp/oss_smoke/stat.rpt | tail -6
