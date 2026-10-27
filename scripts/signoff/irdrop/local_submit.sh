#!/bin/sh
# Local job submission for FC set_host_options -submit_command. analyze_rail submits its worker job with rsh by
# default, even on one machine. Rocky has no rsh and no passwordless ssh to itself (the job then waits for a worker,
# GRD.013), so this runs the job command as a local subprocess.
exec "$@"
