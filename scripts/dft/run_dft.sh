#!/bin/bash
# Scan test chain of a run: protocol, ATPG, pattern replay on the gate-level netlist, SRAM March test.
# usage: scripts/dft/run_dft.sh      (env: RUN, JOBS, NPAT; NPAT=20 gives a quick run)
#
# 1. protocol: Fusion Compiler `write_test_protocol` on the finished block (needs work/design.dlib of this checkout),
#    else the committed baseline protocol scripts/dft/croc_soc.stil (same chain definition, valid while the scan
#    configuration is unchanged)
# 2. inputs for TestMAX ATPG from the run netlist (prepare_inputs.sh, fix_inputs.py)
# 3. ATPG (tmax -shell -tcl atpg.tcl): chain trace, coverage, patterns
# 4. replay of NPAT patterns on the netlist (sim_patterns.sh, Icarus), 0 mismatches required
# 5. March C- of the SRAM through JTAG (scripts/gls/run_sram_march.sh), fault-free case must pass
set -e
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../utils/env.sh"
step_begin dft
O=$STEP_DIR
ST=PASS

# 1. protocol
if [ -d "$REPO/work/design.dlib" ] && command -v fc_shell >/dev/null; then
  ( cd "$REPO/work" && REPO=$REPO OUT=$O/croc_soc.stil fc_shell -batch -f "$HERE/export_stil.tcl" > "$O/export_stil.log" 2>&1 )
  summary protocol "written by fc_shell from work/design.dlib"
else
  cp "$HERE/croc_soc.stil" "$O/croc_soc.stil"
  summary protocol "committed baseline (no work/design.dlib in this checkout)"
fi

# 2. inputs
RUN=$RUN OUT=$O "$HERE/prepare_inputs.sh" > "$O/prepare_inputs.log" 2>&1
python3 "$HERE/fix_inputs.py" "$O/croc_soc_atpg.v" "$O/croc_soc.stil" "$O" > "$O/fix_inputs.log" 2>&1
cp "$HERE/atpg.tcl" "$O/"

# 3. ATPG
( cd "$O" && PATH=$TMAX_HOME/bin:$PATH tmax -shell -tcl atpg.tcl > atpg.out 2>&1 ) || true
CH=$(sed -n 's/.*Chain c1 successfully traced with \([0-9]*\) scan_cells.*/\1/p' "$O/atpg.out" | head -1)
COV=$(sed -n 's/.*test coverage *\([0-9.]*\)%.*/\1/p' "$O/atpg.out" | tail -1)
PAT=$(sed -n 's/.*#internal patterns *\([0-9]*\).*/\1/p' "$O/atpg.out" | tail -1)
summary scan_cells "${CH:-n/a}"; summary stuck_at_coverage_percent "${COV:-n/a}"; summary patterns "${PAT:-n/a}"
[ -n "$CH" ] && [ -n "$COV" ] || ST=FAIL

# 4. replay on the netlist
if [ -n "$PAT" ]; then
  N=$NPAT; [ "$N" -gt "$PAT" ] && N=$PAT
  JOBS=$JOBS "$HERE/sim_patterns.sh" "$O" "$JOBS" "$N" > "$O/replay.log" 2>&1 || true
  PASSED=$(sed -n 's/^chunks passed: \([0-9]*\) of \([0-9]*\)/\1 of \2/p' "$O/replay.log" | tail -1)
  MIS=$(grep -h "MISMATCH\|FAIL kind" "$O"/sim_*.log 2>/dev/null | wc -l)
  summary replay "$N of $PAT patterns, chunks passed: ${PASSED:-n/a}, mismatches: $MIS"
  [ "$MIS" = 0 ] && [ -n "$PASSED" ] && [ "${PASSED% of *}" = "${PASSED#* of }" ] || ST=FAIL
fi

# 5. SRAM March test
if "$REPO/scripts/gls/run_sram_march.sh" "$RUN/croc_soc.v" "$O/march" > "$O/march.log" 2>&1; then :; fi
M=$(grep -h "MARCH PASS" "$O/march/run_good.log" 2>/dev/null | head -1)
D=$(grep -l "MARCH FAIL" "$O"/march/run_saf0.log "$O"/march/run_saf1.log "$O"/march/run_cfin.log "$O"/march/run_af.log 2>/dev/null | wc -l)
summary march_good "${M:-FAIL or not run}"; summary march_injected_faults_detected "$D of 4"
[ -n "$M" ] && [ "$D" = 4 ] || ST=FAIL
summary status $ST
