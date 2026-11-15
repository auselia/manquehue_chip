#!/bin/bash
# Scan test of a run: test protocol, ATPG, replay of the patterns on the gate-level netlist, SRAM March test
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/dft/dft.sh      (env: RUN, JOBS, NPAT (NPAT=20 gives a quick run), DFT_REPLAY=parallel|serial)
# in:  <run>/croc_soc.v, <run>/logs/synthesis.log, the test protocol <run>/croc_soc.stil (or work/design.dlib)
# out: <run>/checks/dft/: summary.txt, the ATPG files, the replay and March logs
set -e
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../../utils/env.sh"
step_begin dft
out=$STEP_DIR
status=PASS
models=$REPO/scripts/signoff/gate_models.py
cell_models=$PDK_ROOT/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/verilog

# 1. The test protocol (write_test_protocol of Fusion Compiler): from the run folder, or from the finish block of
#    this checkout
if [ -f "$RUN/croc_soc.stil" ]; then
  cp "$RUN/croc_soc.stil" "$out/croc_soc.stil"
  summary protocol "from the run folder"
elif [ -d "$REPO/work/design.dlib" ] && command -v fc_shell > /dev/null; then
  ( cd "$REPO/work" && REPO=$REPO OUT=$out/croc_soc.stil fc_shell -batch -f "$here/export_stil.tcl" > "$out/export_stil.log" 2>&1 )
  summary protocol "written by fc_shell from work/design.dlib"
else
  summary protocol "missing: no croc_soc.stil in the run folder and no work/design.dlib"
  summary status FAIL
  exit 1
fi

# 2. The ATPG inputs: netlist without supply ports, cell models without the bus keeper, SRAM as a black box.
#    fix_inputs.py then adapts netlist and protocol to TestMAX. The chain length is the one that synthesis traced.
python3 "$models" netlist "$RUN/croc_soc.v" "$out/croc_soc_atpg.v" --no-supply-ports
python3 "$models" cells "$cell_models/gf180mcu_fd_sc_mcu7t5v0.v" "$out/cells_atpg.v" --no-keeper
cp "$cell_models/primitives.v" "$out/primitives_atpg.v"
cp "$here/sram_blackbox.v" "$out/"
chain_length=$(sed -n "s/.*successfully traced with \([0-9]*\) scan_cells.*/\1/p" "$RUN/logs/synthesis.log" | tail -1)
python3 "$here/fix_inputs.py" "$out/croc_soc_atpg.v" "$out/croc_soc.stil" "$out" "$chain_length" > "$out/fix_inputs.log" 2>&1
cp "$here/atpg.tcl" "$out/"

# 3. ATPG: chain trace, stuck-at coverage, patterns
( cd "$out" && PATH=$TMAX_HOME/bin:$PATH tmax -shell -tcl atpg.tcl > atpg.out 2>&1 ) || true
scan_cells=$(sed -n 's/.*Chain c1 successfully traced with \([0-9]*\) scan_cells.*/\1/p' "$out/atpg.out" | head -1)
coverage=$(sed -n 's/.*test coverage *\([0-9.]*\)%.*/\1/p' "$out/atpg.out" | tail -1)
patterns=$(sed -n 's/.*#internal patterns *\([0-9]*\).*/\1/p' "$out/atpg.out" | tail -1)
summary scan_cells "${scan_cells:-n/a}"
summary stuck_at_coverage_percent "${coverage:-n/a}"
summary patterns "${patterns:-n/a}"
[ -n "$scan_cells" ] && [ -n "$coverage" ] || status=FAIL

# 4. Replay of NPAT patterns on the netlist (Icarus): 0 mismatches in every chunk
if [ -n "$patterns" ]; then
  replayed=$NPAT
  [ "$replayed" -gt "$patterns" ] && replayed=$patterns
  "$here/sim_patterns.sh" "$out" "$JOBS" "$replayed" > "$out/replay.log" 2>&1 || true
  chunks_passed=$(sed -n 's/^chunks passed: \([0-9]*\) of \([0-9]*\)/\1 of \2/p' "$out/replay.log" | tail -1)
  mismatches=$(grep -h "MISMATCH\|FAIL kind" "$out"/sim_*.log 2>/dev/null | wc -l)
  summary replay "$replayed of $patterns patterns, ${DFT_REPLAY:-parallel} load, chunks passed: ${chunks_passed:-n/a}, mismatches: $mismatches"
  [ "$mismatches" = 0 ] && [ -n "$chunks_passed" ] && [ "${chunks_passed% of *}" = "${chunks_passed#* of }" ] || status=FAIL
fi

# 5. SRAM March test: the fault-free run passes, and all four injected faults are found
"$here/sram_march.sh" "$RUN/croc_soc.v" "$out/march" > "$out/march.log" 2>&1 || true
march_result=$(grep -h "MARCH PASS" "$out/march/run_good.log" 2>/dev/null | head -1)
faults_found=$(grep -l "MARCH FAIL" "$out"/march/run_saf0.log "$out"/march/run_saf1.log "$out"/march/run_cfin.log \
  "$out"/march/run_af.log 2>/dev/null | wc -l)
summary march_good "${march_result:-FAIL or not run}"
summary march_injected_faults_detected "$faults_found of 4"
[ -n "$march_result" ] && [ "$faults_found" = 4 ] || status=FAIL
summary status $status
