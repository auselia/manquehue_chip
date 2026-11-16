#!/bin/sh
# Run a RedHawk-SC worker job on this machine (the submit command of set_host_options in analyze_rail.tcl)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: local_submit.sh <job command...>
#
# analyze_rail starts its worker with rsh, even on one machine. Rocky has no rsh and no passwordless ssh to itself,
# so the job waits for a worker forever (GRD.013).
exec "$@"
