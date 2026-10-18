#!/bin/sh
# Trivial local job-submission wrapper for FC set_host_options -submit_command.
# analyze_rail defaults to using rsh to submit its distributed worker job even
# for a single-machine run (confirmed 2026-08-22: no rsh binary, no
# passwordless ssh-to-self on this box -- FC hung ~40min retrying rsh via a
# GRD.013 "waiting for worker" loop). This just execs the job command
# directly as a local subprocess instead of going through rsh/ssh/a real
# queue -- the documented escape hatch (FC UG: "If you do not specify this
# option, rsh is used").
exec "$@"
