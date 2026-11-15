#!/bin/bash
# Copy the step logs and the Formality guidance files (SVF) of a build into its run folder
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: ../scripts/utils/archive_run.sh <step>      (the Makefile calls it in work/ after every step)
# in:  work/logs/<step>.log, work/default-*.svf
# out: outputs/latest/logs/, outputs/latest/svf/ (only after finish and pt_export, the other steps do nothing)
#
# cp -p keeps the modification times: run_lec.sh pairs each SVF with its step log by that time.

step=$1
run_dir=../outputs/latest
netlist_steps="read_rtl floorplan synthesis cts route finish"

case "$step" in
  finish | pt_export) ;;
  *) exit 0 ;;
esac
if [ ! -d "$run_dir" ]; then
  echo "archive_run: no outputs/latest, logs and SVF stay in work/"
  exit 0
fi
mkdir -p "$run_dir/logs" "$run_dir/svf"

if [ "$step" = pt_export ]; then
  cp -p logs/pt_export.log "$run_dir/logs/"
  exit 0
fi

# Each step session writes one default-*.svf. It has the same modification time as the step log.
for s in $netlist_steps; do
  cp -p "logs/$s.log" "$run_dir/logs/"
  log_time=$(stat -c %Y "logs/$s.log")
  for svf in default-*.svf; do
    [ "$(stat -c %Y "$svf")" = "$log_time" ] && cp -p "$svf" "$run_dir/svf/"
  done
done
echo "archive_run: logs and SVF of this build are in $(readlink -f "$run_dir")/{logs,svf}"
