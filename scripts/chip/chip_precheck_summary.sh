#!/bin/bash
# Summary of the chip checks after the wafer.space precheck, for make report: outputs/chip_finish/summary.txt.
# usage: scripts/chip/chip_precheck_summary.sh   (called by chip_finish.sh, or alone on the outputs of a run)
# Counts of the precheck (KLayout DRC, antenna, Magic DRC, density) and of check_lvs in Fusion Compiler (opens and
# shorts). The status is FAIL while any of them is not 0: the DC-DC wrappers still have errors.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
O=$REPO/outputs/chip_finish
L=$O/precheck_nofill.log
S=$O/summary.txt
n() { grep -aoE "[0-9]+ $1 errors found" "$L" 2>/dev/null | tail -1 | awk '{print $1}'; }
KD=$(n "KLayout DRC"); KA=$(n "KLayout antenna"); MD=$(n "Magic DRC")
DEN=$(grep -aq "KLayout density errors clear" "$L" 2>/dev/null && echo 0 || echo "not clear")
LVS=$REPO/outputs/chip_final/check_lvs.rpt
OPEN=$(sed -n 's/^Total number of open nets is \([0-9]*\).*/\1/p' "$LVS" 2>/dev/null)
SHORT=$(sed -n 's/^Total number of short violations is \([0-9]*\).*/\1/p' "$LVS" 2>/dev/null)
{
  echo "date: $(date -Iseconds)"
  echo "commit: $(git -C "$REPO" rev-parse --short HEAD)"
  echo "precheck_klayout_drc: ${KD:-0}"
  echo "precheck_antenna: ${KA:-0}"
  echo "precheck_magic_drc: ${MD:-0}"
  echo "precheck_density: $DEN"
  echo "fc_check_lvs_open_nets: ${OPEN:-n/a} ($(sed -n 's/^Open nets are //p' "$LVS" 2>/dev/null))"
  echo "fc_check_lvs_shorts: ${SHORT:-n/a}"
  ST=PASS
  for v in "${KD:-0}" "${KA:-0}" "${MD:-0}" "$DEN" "${OPEN:-x}" "${SHORT:-x}"; do [ "$v" = 0 ] || ST=FAIL; done
  echo "status: $ST"
} > "$S"
cat "$S"
