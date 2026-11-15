# Shared settings of the verification scripts. Source it. Every value can be overridden from the environment or
# from scripts/utils/local.env (not in git). No script writes to /tmp: results go to <run>/checks/<step>/.
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# corners, libraries and clocks (config/*.tcl): CORNERS, SC_LIB, CORNER_<corner>_LIB, ...
eval "$(python3 "$REPO/scripts/lib/config.py" sh)"
[ -f "$REPO/scripts/utils/local.env" ] && . "$REPO/scripts/utils/local.env"

TOP=croc_soc
CACHE=$REPO/outputs/.cache                                    # converted libraries and folded CDLs
# the Fusion Compiler run under test (outputs/<run>, outputs/latest is the newest)
RUN=$(readlink -f "${RUN:-$REPO/outputs/latest}" 2>/dev/null || true)
CHECKS_OUT=${CHECKS_OUT:-$RUN/checks}

# tools and data
PDK_ROOT=${PDK_ROOT:-$HOME/.ciel}
PDK_DB=${PDK_DB:-$HOME/pdk_synopsys/db}                      # Synopsys .db of the PDK (sta, lec, etm)
SRAM_DB=${SRAM_DB:-$CACHE/$SRAM_LIB.db}
[ -e "$SRAM_DB" ] || SRAM_DB=$HOME/Documents/manquehue_chip/outputs/.cache/$SRAM_LIB.db
PT_HOME=${PT_HOME:-${PT_HOME_DIR:-/usr/synopsys/prime/Y-2026.03-SP2}}   # PT_HOME_DIR: the old name, still read
LC_HOME=${LC_HOME:-${LC_HOME_DIR:-/usr/synopsys/lc/Y-2026.03-SP1}}         # Library Compiler (SRAM .lib to .db)
ICV_HOME_DIR=${ICV_HOME_DIR:-/usr/synopsys/icvalidator/Y-2026.03-SP2}
TMAX_HOME=${TMAX_HOME:-/usr/synopsys/txs/Y-2026.03-SP2}
VCS_HOME=${VCS_HOME:-/usr/synopsys/vcs/Y-2026.03-SP2}            # always with -full64 (no 32-bit install)
SNPSLMD_LICENSE_FILE=${SNPSLMD_LICENSE_FILE:-27020@localhost}
TEMPLATE_DIR=${TEMPLATE_DIR:-$HOME/Documents/waferspace_manquehue}   # wafer.space template (chip flow, simulators via nix-shell)
PRECHECK_DIR=${PRECHECK_DIR:-$HOME/Documents/gf180mcu-precheck}
PRECHECK_PYTHONPATH=${PRECHECK_PYTHONPATH:-/nix/store/mxgvi3js4wjqh7azybkj4zx3fixh2cvb-python3.13-qrcode-8.2/lib/python3.13/site-packages}
SLOT=${SLOT:-0p5x1}
JOBS=${JOBS:-9}                                               # parallel simulations (pattern replay, March test)
NPAT=${NPAT:-100000}                                          # patterns replayed in the gate-level simulation (default: all)
DFT_REPLAY=${DFT_REPLAY:-parallel}                            # parallel: chain loaded by force (seconds), serial: shifted (hours)
IVERILOG_BIN=${IVERILOG_BIN:-$(ls -d /nix/store/*-iverilog-*/bin 2>/dev/null | head -1)}
[ -n "$IVERILOG_BIN" ] && PATH=$IVERILOG_BIN:$PATH
export SNPSLMD_LICENSE_FILE PDK_ROOT PATH

# need <path> <tag> <message>: stop with the message when the file or folder does not exist
need() { [ -e "$1" ] || { echo "[$2] ERROR: $3"; exit 1; }; }
# print "key: value" to the summary file of a step
summary() { echo "$1: $2" >> "$SUMMARY"; }
step_begin() { [ -d "$RUN" ] || { echo "RUN folder not found: '$RUN' (set RUN=outputs/<run> or an absolute path)" >&2; exit 1; }; STEP=$1; STEP_DIR=$CHECKS_OUT/$STEP; mkdir -p "$STEP_DIR"; SUMMARY=$STEP_DIR/summary.txt; : > "$SUMMARY"; summary run "$RUN"; summary date "$(date -Is)"; summary commit "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"; }
