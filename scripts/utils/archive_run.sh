#!/bin/bash
# Called by the Makefile in work/ after the finish and pt_export steps: puts the step logs and the Formality guidance
# files (SVF) of the build into the run folder outputs/latest/, so the run is self-contained.
#   finish     -> outputs/latest/logs/<step>.log of the six netlist-changing steps + outputs/latest/svf/default-*.svf
#   pt_export  -> outputs/latest/logs/pt_export.log only (the other logs stay those of the finish step)
# The modification times are kept (cp -p): scripts/fm/run_lec.sh matches every SVF to its step log by that time.
step=$1
case "$step" in finish|pt_export) ;; *) exit 0 ;; esac
latest=../outputs/latest
[ -d "$latest" ] || { echo "archive_run: no outputs/latest, logs and SVF stay in work/"; exit 0; }
mkdir -p "$latest/logs" "$latest/svf"
if [ "$step" = pt_export ]; then
  cp -p logs/pt_export.log "$latest/logs/"
  exit 0
fi
for s in read_rtl floorplan synthesis cts route finish; do
  cp -p "logs/$s.log" "$latest/logs/"
  t=$(stat -c %Y "logs/$s.log")
  for c in default-*.svf; do
    [ "$(stat -c %Y "$c")" = "$t" ] && cp -p "$c" "$latest/svf/"
  done
done
echo "archive_run: logs and SVF of this build are in $(readlink -f "$latest")/{logs,svf}"
