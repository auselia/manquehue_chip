# Settings of the physical verification checks (KLayout and IC Validator DRC, LVS and metal fill). Source it.
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# in:  env RUN (or GDS and VLOG) and every variable below. A variable that is set, even to an empty value, is kept.
# out: nothing
# shellcheck shell=bash disable=SC2034  # the scripts that source this file use the variables
. "$(dirname "${BASH_SOURCE[0]}")/../../utils/env.sh"

GDS=${GDS-$RUN/$TOP.gds}
VLOG=${VLOG-$RUN/$TOP.v}

# KLayout DRC: run_drc.py, rule_decks/, utils/ and the decks gf180mcu.drc, gf180mcu_antenna.drc, gf180mcu_density.drc
DRC_HOME=${DRC_HOME-$HOME/Documents/gf180_drc_lvs/drc/}
# Metal stack of run_drc.py and run_lvs.py: A = 3 metal layers, B = 4, C = 5
GF180MCU_OPT=${GF180MCU_OPT-C}
# KLayout run mode: flat, deep or tiling
DRC_RUN_MODE=${DRC_RUN_MODE-flat}
# More run_drc.py options, for example DRC_EXTRA="--antenna --density"
DRC_EXTRA=${DRC_EXTRA---thr=6}
# Set here, so that a PDK_ROOT of the Synopsys flow does not change the deck
_h=${DRC_HOME%/}; DRC_PDK_ROOT=${DRC_PDK_ROOT-${_h%/*}/}; DRC_PDK=${DRC_PDK-${_h##*/}}

# KLayout LVS: run_lvs.py, verilog2spice.py, fold_wells.py and the gf180mcu.lvs deck. FC writes no SPICE netlist, so
# verilog2spice.py makes one from the gate-level Verilog and the standard-cell CDL.
LVS_HOME=${LVS_HOME-$HOME/Documents/gf180_drc_lvs/lvs/}
# KLayout run mode: flat, deep or tiling (deep is the tested one)
LVS_RUN_MODE=${LVS_RUN_MODE-deep}
LVS_SUB=${LVS_SUB-VSS}
# The ciel PDK. Its CDL has the cell names of write_verilog. Do not use gf180_drc_lvs/lvs/testing (test cells) or
# ~/pdk_synopsys/cdl (most cells are missing). The standard-cell CDL is the same in the variants A to D.
LVS_PDK_KIT=${LVS_PDK_KIT-$HOME/.ciel/gf180mcu$GF180MCU_OPT/libs.ref}
# fold_wells.py removes the antenna cell (its diodes break the KLayout SPICE reader) and folds VPW into VSS, as the
# substrate connect of gf180mcu.lvs does. VNW stays a pin: verilog2spice.py ties it to VDD in every instance, as
# abutment does in the layout. The result is cached in outputs/.cache/.
LVS_SC_CDL=${LVS_SC_CDL-$LVS_PDK_KIT/$SC_LIB/cdl/$SC_LIB.cdl}
LVS_WELL_TIES=${LVS_WELL_TIES---tie VPW=VSS}
# Gives the CDL models (nfet_05v0, pfet_05v0) the device class names of gf180mcu.lvs (nmos_5p0, pmos_5p0), so KLayout
# pairs the transistors without same_device_classes (that helper fails in KLayout 0.30.9).
LVS_MODEL_RENAME=${LVS_MODEL_RENAME---rename-model nfet_05v0=nmos_5p0 --rename-model pfet_05v0=pmos_5p0}
# Hard macros without a transistor-level CDL (the SRAMs) are black boxes by their pins. They need their own
# sign-off. Sizes that the design does not use do no harm.
LVS_BLACKBOX_CDL=${LVS_BLACKBOX_CDL-$(ls "$LVS_PDK_KIT"/gf180mcu_fd_ip_sram/cdl/gf180mcu_fd_ip_sram__sram*.cdl 2>/dev/null | tr '\n' ' ')}
# The same macros are black boxes in the layout: the LVS removes their device layers in a copy of the GDS
# (blackbox_gds_cells.rb) and keeps metal, vias and pin labels. The GDS of the run does not change. Empty: compare
# the full GDS.
if [ -z "${LVS_BLACKBOX_CELLS+set}" ]; then
  LVS_BLACKBOX_CELLS=$(for f in $LVS_BLACKBOX_CDL; do f=${f##*/}; printf '%s ' "${f%.*}"; done)
fi
LVS_BLACKBOX_CELLS=$(echo $LVS_BLACKBOX_CELLS)
# Cells out of the compare on both sides (comma-separated substrings). The fillcap cells connect only VDD and VSS,
# so the compare cannot pair instances of the same size one to one. Empty: compare every instance.
LVS_EXCLUDE_FROM_COMPARE=${LVS_EXCLUDE_FROM_COMPARE-fillcap}
# run_lvs.py options of the tested croc_soc run
LVS_FLAGS=${LVS_FLAGS---set_spice_comments --set_net_only --set_top_lvl_pins --set_combine --set_purge --set_purge_nets}
# More run_lvs.py options, for example LVS_EXTRA="--thr=6 --set_verbose"
LVS_EXTRA=${LVS_EXTRA---thr=6}
_h=${LVS_HOME%/}; LVS_PDK_ROOT=${LVS_PDK_ROOT-${_h%/*}/}; LVS_PDK=${LVS_PDK-${_h##*/}}
# Device class map of lvs_compare.rb. Empty: LVS_MODEL_RENAME already gives both sides the same names.
LVS_DEVICE_CLASS_MAP=${LVS_DEVICE_CLASS_MAP-}
FOLDED_SC_CDL=$CACHE/$SC_LIB.folded.cdl

# IC Validator: a second DRC and LVS engine with the ICV decks of the Synopsys PDK. LVS uses the same
# verilog2spice.py and fold_wells.py, without the model rename.
ICV_PDK_HOME=${ICV_PDK_HOME-$HOME/pdk_synopsys}
ICV_HOST_INIT=${ICV_HOST_INIT-4}
# Optional runset config for icv -runset_config (a path in the repo). Empty: the decks run as they are. The GDS of
# 06_finish.tcl has the 1 nm database unit that the decks expect.
ICV_RUNSET_CONFIG=${ICV_RUNSET_CONFIG-}
# DRC deck: the foundry deck DRC_ICV (needs the settings below) or DRC_ICV_MODIFIED (no settings, but its README
# says that it can miss rules).
ICV_DRC_RUNSET=${ICV_DRC_RUNSET-$ICV_PDK_HOME/DRC_ICV/DRC/ICV/gf180mcu_drc.rs}
# Settings of DRC_ICV. ICV_BEOL_STACK matches GF180MCU_OPT (A = 1P3M, B = 1P4M, C = 1P5M).
ICV_BEOL_STACK=${ICV_BEOL_STACK-1P5M}
ICV_TOPMETAL=${ICV_TOPMETAL-11KA}
ICV_MIMCAP=${ICV_MIMCAP-OPT_A}
ICV_PADBONDING=${ICV_PADBONDING-WEDGE}
ICV_LATCH_CHECK=${ICV_LATCH_CHECK-DECK_ONLY}
# More icv options, for example ICV_DRC_EXTRA="-svc *density*"
ICV_DRC_EXTRA=${ICV_DRC_EXTRA-}
ICV_LVS_RUNSET=${ICV_LVS_RUNSET-$ICV_PDK_HOME/LVS_ICV/LVS/ICV/cmos018hv.3p3.6v.lvs.rs}
ICV_LVS_HOME=${ICV_LVS_HOME-$(dirname "$ICV_LVS_RUNSET")}
# More icv options, for example ICV_LVS_EXTRA="-vueshort"
ICV_LVS_EXTRA=${ICV_LVS_EXTRA-}
# LVS_ICV declares NFET_05V0 and PFET_05V0, and ICV compares names without case, so there is no model rename.
FOLDED_SC_CDL_ICV=$CACHE/$SC_LIB.icv.folded.cdl
# Metal fill for the density sign-off: croc_metal_fill.rs (made from gf180mcu_fill.rs of DRC_ICV_MODIFIED, see its
# header). It includes gf180mcu_layers.rh from ICV_FILL_INCLUDE_DIR.
ICV_FILL_RUNSET=${ICV_FILL_RUNSET-scripts/signoff/pv/croc_metal_fill.rs}
ICV_FILL_INCLUDE_DIR=${ICV_FILL_INCLUDE_DIR-$ICV_PDK_HOME/DRC_ICV_MODIFIED/DRC/ICV}
# More icv options, for example ICV_FILL_EXTRA="-vue"
ICV_FILL_EXTRA=${ICV_FILL_EXTRA-}

# fold_cdl <tag> <out> <fold_wells.py options>: the folded standard-cell CDL, made again when the CDL is newer
fold_cdl() {
  local tag=$1 out=$2; shift 2
  mkdir -p "$CACHE"
  if [ ! -e "$out" ] || [ "$LVS_SC_CDL" -nt "$out" ]; then
    echo "[$tag] Preparing standard-cell CDL ($*): $out"
    python3 "$LVS_HOME/fold_wells.py" "$@" "$LVS_SC_CDL" "$out" || exit 1
  fi
}
# spice <tag> <folded CDL> <out dir>: the SPICE netlist <out dir>/<TOP>.sp from the gate-level Verilog
spice() {
  echo "[$1] Verilog -> SPICE ($TOP.sp) with verilog2spice.py"
  local bb=() f
  for f in $LVS_BLACKBOX_CDL; do bb+=(--blackbox-cdl "$f"); done
  python3 "$LVS_HOME/verilog2spice.py" -v "$VLOG_REAL" -c "$2" "${bb[@]}" -o "$3/$TOP.sp" 2>&1 | tee "$3/verilog2spice.log"
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    echo "[$1] ERROR: verilog2spice.py found missing cells (exit $rc). See $3/verilog2spice.log: the CDL of a macro is"
    echo "[$1] probably not in LVS_BLACKBOX_CDL."
    exit 1
  fi
}
# blackbox_gds <tag> <out dir>: sets LVS_GDS, the GDS that LVS compares (a copy with the macros as black boxes)
blackbox_gds() {
  LVS_GDS=$GDS_REAL
  [ -n "$LVS_BLACKBOX_CELLS" ] || return 0
  echo "[$1] Black boxes in a copy of the GDS ($LVS_BLACKBOX_CELLS). The GDS of the run does not change."
  klayout -b -r "$LVS_HOME/blackbox_gds_cells.rb" -rd input="$GDS_REAL" -rd output="$2/$TOP.lvs_blackbox.gds" \
    -rd cells="${LVS_BLACKBOX_CELLS// /,}" 2>&1 | tee "$2/blackbox_gds.log"
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then echo "[$1] ERROR: blackbox_gds_cells.rb failed (exit $rc), see $2/blackbox_gds.log"; exit 1; fi
  LVS_GDS=$2/$TOP.lvs_blackbox.gds
}
