# Shared settings and helpers of the check scripts. Source it, do not run it.
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# in:  env RUN (default outputs/latest), config/*.tcl, scripts/utils/local.env (optional, not in git)
# out: variables and the functions need, summary and step_begin
#
# Every setting below keeps a value that is already in the environment. local.env can set any of them.
# shellcheck shell=bash disable=SC2034  # the scripts that source this file read the variables

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
eval "$(python3 "$REPO/scripts/lib/config.py" sh)"
[ -f "$REPO/scripts/utils/local.env" ] && . "$REPO/scripts/utils/local.env"

# The run under test and where its checks write
TOP=croc_soc
RUN=$(readlink -f "${RUN:-$REPO/outputs/latest}" 2>/dev/null || true)
CHECKS_OUT=${CHECKS_OUT:-$RUN/checks}
CACHE=$REPO/outputs/.cache

# PDK data. The PDK has the SRAM as .lib only: sram_db converts it into SRAM_DB.
PDK_ROOT=${PDK_ROOT:-$HOME/.ciel}
PDK_DB=${PDK_DB:-$HOME/pdk_synopsys/db}
PT_SRAM_LIB=${PT_SRAM_LIB:-$HOME/pdk_synopsys/lib/$SRAM_LIB.lib}
SRAM_DB=$CACHE/$SRAM_LIB.db

# Synopsys tools. PT_HOME_DIR is the name that the Makefile of waferspace_manquehue passes.
PT_HOME=${PT_HOME:-${PT_HOME_DIR:-/usr/synopsys/prime/Y-2026.03-SP2}}
LC_HOME=${LC_HOME:-${LC_HOME_DIR:-/usr/synopsys/lc/Y-2026.03-SP1}}
ICV_HOME_DIR=${ICV_HOME_DIR:-/usr/synopsys/icvalidator/Y-2026.03-SP2}
TMAX_HOME=${TMAX_HOME:-/usr/synopsys/txs/Y-2026.03-SP2}
VCS_HOME=${VCS_HOME:-/usr/synopsys/vcs/Y-2026.03-SP2}   # 64-bit only: call vcs with -full64
SNPSLMD_LICENSE_FILE=${SNPSLMD_LICENSE_FILE:-27020@localhost}

# Open-source simulators: Icarus from the Nix store, Verilator through the nix-shell of the wafer.space template
TEMPLATE_DIR=${TEMPLATE_DIR:-$HOME/Documents/waferspace_manquehue}
iverilog_bin=$(ls -d /nix/store/*-iverilog-*/bin 2>/dev/null | head -1)
[ -n "$iverilog_bin" ] && PATH=$iverilog_bin:$PATH

# DFT and simulation options
JOBS=${JOBS:-9}                     # parallel simulations (pattern replay, March test)
NPAT=${NPAT:-100000}                # patterns replayed on the netlist (the default replays all)
DFT_REPLAY=${DFT_REPLAY:-parallel}  # parallel: chain loaded by force (minutes), serial: shifted (hours)

export SNPSLMD_LICENSE_FILE PDK_ROOT PATH

# need <path> <tag> <message>: stop with the message when the file or folder does not exist
need() {
  [ -e "$1" ] && return 0
  echo "[$2] ERROR: $3"
  exit 1
}

# sram_db <tag>: convert the SRAM .lib into SRAM_DB (Library Compiler) when the .db is missing or older
sram_db() {
  [ -e "$SRAM_DB" ] && [ ! "$PT_SRAM_LIB" -nt "$SRAM_DB" ] && return 0
  mkdir -p "$CACHE"
  echo "[$1] Compiling the SRAM liberty into a .db (Library Compiler): $SRAM_DB"
  # lc_shell writes its own log files into the folder it runs in
  ( cd "$CACHE" && PATH="$LC_HOME/bin:$PATH" lc_shell -x \
      "read_lib $PT_SRAM_LIB; write_lib $SRAM_LIB -format db -output $SRAM_DB; exit" ) 2>&1 | tee "$CACHE/lc_sram.log"
  need "$SRAM_DB" "$1" "SRAM .db compile failed, see $CACHE/lc_sram.log"
}

# summary <key> <value>: add a "key: value" line to the summary of the current check
summary() {
  echo "$1: $2" >> "$SUMMARY"
}

# step_begin <check>: create <run>/checks/<check>/ and start its summary.txt (sets STEP_DIR and SUMMARY)
step_begin() {
  local check=$1
  if [ ! -d "$RUN" ]; then
    echo "RUN folder not found: '$RUN' (set RUN=outputs/<run> or an absolute path)" >&2
    exit 1
  fi
  STEP_DIR=$CHECKS_OUT/$check
  SUMMARY=$STEP_DIR/summary.txt
  mkdir -p "$STEP_DIR"
  : > "$SUMMARY"
  summary run "$RUN"
  summary date "$(date -Is)"
  summary commit "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
}
