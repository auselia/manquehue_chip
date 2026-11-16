# The design of the macro
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# in:  nothing. Tcl reads this file with source. Bash and Make read it with scripts/lib/config.py.
# out: nothing
#
# Only "set NAME value" lines and comments. The machine paths (PDK, tools) are in scripts/utils/env.sh and
# scripts/impl/lib/setup.tcl, with the same environment variables.

# The top module of the RTL, and the name of every file of a run (outputs/<run>/<TOP_MODULE>.gds, ...)
set TOP_MODULE croc_soc
