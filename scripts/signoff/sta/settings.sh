# Settings that the PrimeTime checks of a run share (sta.sh, scan_sta.sh, extract_models.sh, power/power.sh). Source it.
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# in:  env RUN (or VLOG, SDC and SPEC_SDC), PT_PDK_DB_DIR or ICV_PDK_HOME
# out: VLOG, SDC, SPEC_SDC, PDK_DB and the function corner_inputs
# shellcheck shell=bash disable=SC2034  # the scripts that source this file read the variables
. "$(dirname "${BASH_SOURCE[0]}")/../../utils/env.sh"

# 06_finish.tcl writes the netlist, the SDC and the SPEF of every corner into the run folder (make pt_export writes
# them again). SPEC_SDC has the same constraints at SPEC_PERIOD of config/clocks.tcl: 55.0 gives croc_soc_55ns.sdc.
VLOG=${VLOG-$RUN/$TOP.v}
SDC=${SDC-$RUN/$TOP.sdc}
SPEC_SDC=${SPEC_SDC-$RUN/${TOP}_${SPEC_PERIOD%.0}ns.sdc}

# The .db folder of the PDK. Its default follows ICV_PDK_HOME, as the IC Validator decks do.
PDK_DB=${PT_PDK_DB_DIR-${ICV_PDK_HOME-$HOME/pdk_synopsys}/db}

# corner_inputs <corner> <run folder>: set SC_DB, IO_DB and SPEF of the corner
corner_inputs() {
  local corner=$1 run_dir=$2
  local lib_var=CORNER_${corner}_LIB spef_var=CORNER_${corner}_SPEF
  SC_DB=$PDK_DB/${SC_LIB}__${!lib_var}.db
  IO_DB=$PDK_DB/${IO_LIB}__${!lib_var}.db
  SPEF=$run_dir/$TOP.${!spef_var}.spef
}
