#!/bin/bash
# Chip GDS for the wafer.space precheck, from outputs/chip_final/chip_top.gds (06_finish.tcl), into outputs/chip_finish
# (or OUT):
#   chip_top.gds       seal ring, no fill
#   fill/chip_top.gds  FILL=1 only: seal ring and the PDK fill (fill_all.rb, Metal2_ignore_active as the template).
#                      The PDK fill also fills the pad ring.
# and the precheck of each (precheck_nofill.log, precheck_fill.log). The precheck wants the file named like its top cell.
# usage: scripts/chip/chip_finish.sh   (env: IN, OUT, FILL=1, COB=1 for --cob)
# The PDK scripts come from the template copy (gf180mcu/) and run in its nix-shell, as in LibreLane.
set -e
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../utils/env.sh"
REPO=$(cd "$HERE/../.." && pwd)
O=${OUT:-$REPO/outputs/chip_finish}
mkdir -p "$O/fill"
IN=${IN:-$REPO/outputs/chip_final/chip_top.gds}
[ -s "$IN" ] || { echo "ERROR: no $IN (run make chip_finish_fc)"; exit 1; }
KS=$TEMPLATE_DIR/gf180mcu/gf180mcuD/libs.tech/klayout/tech/scripts
OPT=""; [ "${COB:-0}" = 1 ] && OPT="--cob"
cd "$TEMPLATE_DIR"
# the PDK scripts find their data through PDK_ROOT and PDK (the PDK copy of the template, as LibreLane runs them)
KENV="export PDK_ROOT=$TEMPLATE_DIR/gf180mcu PDK=gf180mcuD;"
nix-shell --run "klayout -b -r $HERE/gds_dbu.py -rd input=$IN -rd output=$O/chip_route_dbu.gds" > "$O/dbu.log" 2>&1
nix-shell --run "$KENV python3 $KS/sealring.py --input $O/chip_route_dbu.gds --output $O/chip_top.gds --die-width 1936 --die-height 5122" \
    > "$O/sealring.log" 2>&1
if [ "${FILL:-0}" = 1 ]; then
    nix-shell --run "$KENV klayout -b -zz -r $KS/fill_all.rb -rd input=$O/chip_top.gds -rd output=$O/fill/chip_top.gds -rd Metal2_ignore_active=1" \
        > "$O/fill.log" 2>&1
fi
rm -f "$O/chip_route_dbu.gds"
GS=nofill; [ "${FILL:-0}" = 1 ] && GS="nofill fill"
for g in $GS; do
    [ $g = nofill ] && G=$O/chip_top.gds || G=$O/fill/chip_top.gds
    ( nix-shell --run "export PDK_ROOT=$PDK_ROOT PDK=gf180mcuD PYTHONPATH=$PRECHECK_PYTHONPATH; cd $PRECHECK_DIR && \
        python3 precheck.py --input $G --slot $SLOT $OPT --workers 2 --threads 5 --output $O/${g}_checked.oas" ) \
        > "$O/precheck_$g.log" 2>&1 || true
    if grep -q "Precheck successfully completed" "$O/precheck_$g.log"; then echo "precheck $g: PASS"; else echo "precheck $g: FAIL (precheck_$g.log)"; fi
done
