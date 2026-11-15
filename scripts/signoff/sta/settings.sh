# Settings of the PrimeTime checks of a run (sta.sh and power/power.sh). Source it.
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# in:  env RUN (or VLOG, SDC and SPEC_SDC), PT_PDK_DB_DIR or ICV_PDK_HOME, PT_SRAM_LIB
# out: nothing
# shellcheck shell=bash disable=SC2034  # the scripts that source this file use the variables
. "$(dirname "${BASH_SOURCE[0]}")/../../utils/env.sh"

# The checks read the netlist, the SDC and the SPEF of every corner that 06_finish.tcl writes into the run folder
# (common/export_signoff.tcl). Without them they stop: run make finish, or make pt_export to write them again.
VLOG=${VLOG-$RUN/$TOP.v}
SDC=${SDC-$RUN/$TOP.sdc}
# Sign-off SDC: the same constraints at SPEC_PERIOD of config/clocks.tcl (55.0 gives _55ns)
SPEC_SDC=${SPEC_SDC-$RUN/${TOP}_${SPEC_PERIOD%.0}ns.sdc}
# The .db folder of the PDK. The default follows ICV_PDK_HOME, as the IC Validator decks do.
PDK_DB=${PT_PDK_DB_DIR-${ICV_PDK_HOME-$HOME/pdk_synopsys}/db}
# The PDK has one SRAM view (tt, 25 C, 5.0 V) for all corners. It ships as .lib only: Library Compiler converts it
# once into outputs/.cache/, and again when the .lib changes.
PT_SRAM_LIB=${PT_SRAM_LIB-$HOME/pdk_synopsys/lib/$SRAM_LIB.lib}
PT_SRAM_DB=$CACHE/$SRAM_LIB.db

# sram_db <tag>: converts the SRAM .lib into PT_SRAM_DB when the .db is missing or older
sram_db() {
  mkdir -p "$CACHE"
  [ -e "$PT_SRAM_DB" ] && [ ! "$PT_SRAM_LIB" -nt "$PT_SRAM_DB" ] && return 0
  echo "[$1] Compiling the SRAM liberty into a .db (Library Compiler): $PT_SRAM_DB"
  PATH="$LC_HOME/bin:$PATH" lc_shell -x "read_lib $PT_SRAM_LIB; write_lib $SRAM_LIB -format db -output $PT_SRAM_DB; exit" \
    2>&1 | tee "$CACHE/lc_sram.log"
  need "$PT_SRAM_DB" "$1" "SRAM .db compile failed, see $CACHE/lc_sram.log"
}
# corner_inputs <corner>: sets SC_DB, IO_DB and SPEF of the corner
corner_inputs() {
  local lib=CORNER_$1_LIB spef=CORNER_$1_SPEF
  SC_DB=$PDK_DB/${SC_LIB}__${!lib}.db; IO_DB=$PDK_DB/${IO_LIB}__${!lib}.db; SPEF=$RUN_REAL/$TOP.${!spef}.spef
}
