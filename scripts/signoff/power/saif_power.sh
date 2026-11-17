#!/bin/bash
# Power of a run from the switching activity of a gate-level simulation: active (the core runs) and idle (WFI)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: scripts/signoff/power/saif_power.sh      (env: RUN, PP_CORNERS, default typical)
# in:  <run>/croc_soc.v, <run>/sta_pt/croc_soc.typical.sdf (make sta-pt), sim/sw/gls_mini
# out: <run>/power_saif/: sim/ (VCS, active.saif, idle.saif), active/ and idle/ (PrimePower reports), summary.txt
#
# The simulation is the VCS SDF boot of the gls check (tb_macro.v, program gls_mini over JTAG) at the max delays.
# Active: from the resume until GLS OK on the UART. Idle: 1 ms after status_o falls, with the core in WFI.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../../utils/env.sh"
sdf=$RUN/sta_pt/$TOP.typical.sdf
need "$sdf" POWER-SAIF "no SDF in the run folder: run make sta-pt RUN=... first."
out=$RUN/power_saif
mkdir -p "$out"

VCS_EXTRA=+define+SAIF "$REPO/scripts/signoff/gls/vcs_sdf.sh" "$RUN/$TOP.v" "$sdf" max "$out/sim" > "$out/sim.log" 2>&1
for w in active idle; do
  need "$out/sim/$w.saif" POWER-SAIF "the simulation wrote no $w.saif, see $out/sim.log and $out/sim/run.log."
done

for w in active idle; do
  PP_CORNERS=${PP_CORNERS:-typical} PP_SAIF=$out/sim/$w.saif PP_SAIF_INSTANCE=tb_macro/dut PP_OUT=$out/$w \
    "$here/power.sh" > "$out/$w.log" 2>&1 || { tail -20 "$out/$w.log"; exit 1; }
done

{
  for w in active idle; do
    for r in "$out/$w"/report_power_summary.*.rpt; do
      c=${r##*summary.}; c=${c%.rpt}
      echo "$w $c: $(grep 'Total Power' "$r" | awk '{print $4, $5}')"
    done
  done
  echo "annotated nets (active): $(grep -m1 -i 'annotated' "$out/active.log")"
} > "$out/summary.txt"
cat "$out/summary.txt"
