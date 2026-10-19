###############################################################################
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Fusion Compiler flow, sign-off checks, simulation and FPGA targets
###############################################################################

SHELL := /bin/bash
.DELETE_ON_ERROR:

# Comma-separated lists for the klayout -rd arguments
empty :=
space := $(empty) $(empty)
comma := ,

# ------------------------------------------------------------------------------
# Design Configuration
# ------------------------------------------------------------------------------
TOP                := croc_soc
WORK_DIR           := work
# staging of the step logs, copied into outputs/<run>/logs/ by scripts/utils/archive_run.sh at the end of finish
LOGS_DIR           := $(WORK_DIR)/logs
OUTPUTS_DIR        := outputs
REPO_DIR           := $(shell pwd)

.DEFAULT_GOAL := help

# ------------------------------------------------------------------------------
# Sign-off run selection (shared by DRC and LVS)
# ------------------------------------------------------------------------------
# 06_finish.tcl writes every run to outputs/<TOP>_<YYYYMMDD_HHMMSS>/ and points outputs/latest at it. The checks
# read GDS and VLOG from the run folder and write their results into it.
#   make drc RUN=croc_soc_20260804_101500       a folder under outputs/, or an absolute path
#   make drc GDS=/path/to.gds VLOG=/path/to.v
RUN  ?= latest
RUN_DIR := $(if $(filter /%,$(RUN)),$(RUN),$(OUTPUTS_DIR)/$(RUN))
GDS  ?= $(RUN_DIR)/$(TOP).gds
VLOG ?= $(RUN_DIR)/$(TOP).v

# ------------------------------------------------------------------------------
# Sign-off / DRC configuration (KLayout + GF180MCU)
# ------------------------------------------------------------------------------
# run_drc.py, rule_decks/, utils/ and the decks gf180mcu.drc, gf180mcu_antenna.drc, gf180mcu_density.drc
DRC_HOME      ?= $(HOME)/Documents/gf180_drc_lvs/drc/
# Metal stack option passed to run_drc.py / run_lvs.py:  A=3LM  B=4LM  C=5LM
GF180MCU_OPT  ?= C
# KLayout run mode: flat | deep | tiling
DRC_RUN_MODE  ?= flat
# Extra run_drc.py flags, e.g. DRC_EXTRA="--antenna --density"
DRC_EXTRA     ?= --thr=6
# Set here, so that a PDK_ROOT exported for the Synopsys flow does not interfere
DRC_PDK_ROOT  ?= $(dir $(patsubst %/,%,$(DRC_HOME)))
DRC_PDK       ?= $(notdir $(patsubst %/,%,$(DRC_HOME)))

# ------------------------------------------------------------------------------
# Sign-off / LVS configuration (KLayout + GF180MCU)
# ------------------------------------------------------------------------------
# run_lvs.py, verilog2spice.py, fold_wells.py and the gf180mcu.lvs deck. FC exports no SPICE netlist, so make lvs
# builds one from the gate-level Verilog (verilog2spice.py with the standard-cell CDL) and compares it with the GDS.
LVS_HOME         ?= $(HOME)/Documents/gf180_drc_lvs/lvs/
# KLayout run mode: flat | deep | tiling (deep is the tested default)
LVS_RUN_MODE     ?= deep
# Substrate net
LVS_SUB          ?= VSS
# The ciel PDK (~/.ciel/gf180mcu<OPT> follows the active version). Its CDL has the cell names that write_verilog
# uses. Not gf180_drc_lvs/lvs/testing (test cells) and not ~/pdk_synopsys/cdl (most cells are missing). The
# standard-cell CDL is the same in the variants A to D.
LVS_PDK_KIT      ?= $(HOME)/.ciel/gf180mcu$(GF180MCU_OPT)/libs.ref
# fold_wells.py removes the `antenna` cell (its diodes break the KLayout SPICE reader) and folds VPW into VSS, as
# the global substrate connect of gf180mcu.lvs does. VNW stays a pin: verilog2spice.py ties it to VDD in every
# instance, as abutment does in the layout. The result is cached in outputs/.cache/.
LVS_SC_CDL       ?= $(LVS_PDK_KIT)/gf180mcu_fd_sc_mcu7t5v0/cdl/gf180mcu_fd_sc_mcu7t5v0.cdl
LVS_WELL_TIES    ?= --tie VPW=VSS
# Gives the CDL models (nfet_05v0, pfet_05v0) the device class names of gf180mcu.lvs (nmos_5p0, pmos_5p0), so
# KLayout pairs the transistors without same_device_classes (that helper fails in KLayout 0.30.9).
LVS_MODEL_RENAME ?= --rename-model nfet_05v0=nmos_5p0 --rename-model pfet_05v0=pmos_5p0
# Hard macros without a transistor-level CDL (the SRAMs) are black boxes by their pins and need their own sign-off.
# Sizes that the design does not use do no harm.
LVS_BLACKBOX_CDL ?= $(wildcard $(LVS_PDK_KIT)/gf180mcu_fd_ip_sram/cdl/gf180mcu_fd_ip_sram__sram*.cdl)
# The same macros are black boxes in the layout: make lvs removes their device layers in a copy of the GDS
# (blackbox_gds_cells.rb) and keeps metal, vias and pin labels. $(GDS) does not change. Empty: compare the full GDS.
LVS_BLACKBOX_CELLS ?= $(basename $(notdir $(LVS_BLACKBOX_CDL)))
# Cells left out of the compare on both sides (comma-separated substrings). The fillcap cells connect only VDD
# and VSS, so the compare cannot pair same-size instances one to one. Empty: compare every instance.
LVS_EXCLUDE_FROM_COMPARE ?= fillcap
# run_lvs.py switches of the tested croc_soc run
LVS_FLAGS        ?= --set_spice_comments --set_net_only --set_top_lvl_pins --set_combine --set_purge --set_purge_nets
# Extra run_lvs.py flags, e.g. LVS_EXTRA="--thr=6 --set_verbose"
LVS_EXTRA        ?= --thr=6
LVS_PDK_ROOT     ?= $(dir $(patsubst %/,%,$(LVS_HOME)))
LVS_PDK          ?= $(notdir $(patsubst %/,%,$(LVS_HOME)))
# Device class map for lvs_compare.rb. Empty: LVS_MODEL_RENAME already gives both sides the same names.
LVS_DEVICE_CLASS_MAP ?=

CACHE_DIR       := $(OUTPUTS_DIR)/.cache
FOLDED_SC_CDL   := $(CACHE_DIR)/gf180mcu_fd_sc_mcu7t5v0.folded.cdl

# ------------------------------------------------------------------------------
# Sign-off / DRC + LVS configuration (Synopsys IC Validator + GF180MCU)
# ------------------------------------------------------------------------------
# Second DRC and LVS engine with the ICV decks of the Synopsys PDK (DRC_ICV*, LVS_ICV), a cross-check of the
# KLayout targets. LVS uses the same verilog2spice.py and fold_wells.py, without the model rename.
ICV_HOME_DIR      ?= /usr/synopsys/icvalidator/Y-2026.03-SP2
ICV_PDK_HOME      ?= $(HOME)/pdk_synopsys
ICV_HOST_INIT     ?= 4
# Optional runset config for icv -runset_config (a path in the repo). Empty: the decks run as they are. The GDS of
# 06_finish.tcl has the 1 nm database unit that the decks expect.
ICV_RUNSET_CONFIG     ?=

# DRC deck: the foundry deck DRC_ICV (default, needs the ICV_* settings below) or DRC_ICV_MODIFIED (no settings,
# but its README says that it can miss rules):
#   make drc-icv ICV_DRC_RUNSET=$(ICV_PDK_HOME)/DRC_ICV_MODIFIED/DRC/ICV/gf180mcu_drc.rs
ICV_DRC_RUNSET   ?= $(ICV_PDK_HOME)/DRC_ICV/DRC/ICV/gf180mcu_drc.rs
# Settings of DRC_ICV. ICV_BEOL_STACK matches GF180MCU_OPT (A=1P3M B=1P4M C=1P5M). The others are the usual
# GF180MCU choices.
ICV_BEOL_STACK   ?= 1P5M
ICV_TOPMETAL     ?= 11KA
ICV_MIMCAP       ?= OPT_A
ICV_PADBONDING   ?= WEDGE
ICV_LATCH_CHECK  ?= DECK_ONLY
# Extra icv command-line options, e.g. ICV_DRC_EXTRA="-svc *density*"
ICV_DRC_EXTRA    ?=

# LVS
ICV_LVS_RUNSET   ?= $(ICV_PDK_HOME)/LVS_ICV/LVS/ICV/cmos018hv.3p3.6v.lvs.rs
ICV_LVS_HOME     ?= $(patsubst %/,%,$(dir $(ICV_LVS_RUNSET)))
# Extra icv command-line options, e.g. ICV_LVS_EXTRA="-vueshort"
ICV_LVS_EXTRA    ?=
# LVS_ICV declares NFET_05V0 and PFET_05V0, and ICV compares names without case, so there is no model rename.
# Folded and cached as FOLDED_SC_CDL.
FOLDED_SC_CDL_ICV := $(CACHE_DIR)/gf180mcu_fd_sc_mcu7t5v0.icv.folded.cdl

# Metal fill for the density sign-off: croc_metal_fill.rs (in this repo, made from gf180mcu_fill.rs of
# DRC_ICV_MODIFIED, see its header). It includes gf180mcu_layers.rh from ICV_FILL_INCLUDE_DIR. Metal1 to Metal5 end
# above the 30 % of gf180mcu_density.drc, with no new DRC violations (14 Aug).
ICV_FILL_RUNSET       ?= scripts/signoff/pv/croc_metal_fill.rs
ICV_FILL_INCLUDE_DIR  ?= $(ICV_PDK_HOME)/DRC_ICV_MODIFIED/DRC/ICV
# Extra icv command-line options, e.g. ICV_FILL_EXTRA="-vue"
ICV_FILL_EXTRA        ?=

# ------------------------------------------------------------------------------
# Sign-off STA / power - Synopsys PrimeTime + PrimePower (GF180MCU, MCMM)
# ------------------------------------------------------------------------------
# The checks read the SDC and the SPEF per corner that 06_finish.tcl writes into the run folder
# (common/export_signoff.tcl). Without them they stop and ask for make finish, or make pt_export to write them again.
PT_HOME_DIR ?= /usr/synopsys/prime/Y-2026.03-SP2
SDC  ?= $(RUN_DIR)/$(TOP).sdc
# Sign-off SDC: the same constraints at SPEC_PERIOD of setup.tcl (55.0 gives _55ns)
SPEC_SDC ?= $(RUN_DIR)/$(TOP)_55ns.sdc

# PrimeTime has no MCMM of its own (create_corner and create_mode are FC commands). sta_corner.tcl runs one
# pt_shell per corner, so the libraries of each corner are named here. The corners are the ones of mcmm.tcl.
PT_PDK_DB_DIR    ?= $(ICV_PDK_HOME)/db
PT_SC_DB_slow    ?= $(PT_PDK_DB_DIR)/gf180mcu_fd_sc_mcu7t5v0__ss_125C_4v50.db
PT_SC_DB_typical ?= $(PT_PDK_DB_DIR)/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.db
PT_SC_DB_fast    ?= $(PT_PDK_DB_DIR)/gf180mcu_fd_sc_mcu7t5v0__ff_n40C_5v50.db
PT_IO_DB_slow    ?= $(PT_PDK_DB_DIR)/gf180mcu_fd_io__ss_125C_4v50.db
PT_IO_DB_typical ?= $(PT_PDK_DB_DIR)/gf180mcu_fd_io__tt_025C_5v00.db
PT_IO_DB_fast    ?= $(PT_PDK_DB_DIR)/gf180mcu_fd_io__ff_n40C_5v50.db

# The PDK has one SRAM view (tt, 25 C, 5.0 V), used at all three corners. It ships as .lib only: Library Compiler
# converts it once into outputs/.cache/, and again when the .lib changes.
PT_SRAM_LIB ?= $(HOME)/pdk_synopsys/lib/gf180mcu_fd_ip_sram__sram512x8m8wm1__tt_025C_5v00.lib
PT_SRAM_DB  := $(CACHE_DIR)/gf180mcu_fd_ip_sram__sram512x8m8wm1__tt_025C_5v00.db
LC_HOME_DIR ?= /usr/synopsys/lc/Y-2026.03-SP1

# PrimePower without activity data gives a vectorless estimate (default toggle rate and static probability).
# Set PP_SAIF to a simulated activity file for real numbers.
PP_SAIF ?=
PP_DEFAULT_TOGGLE_RATE ?= 0.1
PP_DEFAULT_STATIC_PROB ?= 0.5
# fast by default: the scenario with power analysis in mcmm.tcl (5.5 V, the highest switching and leakage power).
# Example: PP_CORNERS="slow typical fast"
PP_CORNERS ?= fast

# ------------------------------------------------------------------------------
# Sign-off Rail Analysis - RedHawk-SC Fusion (in-design, via Fusion Compiler)
# ------------------------------------------------------------------------------
# make rail opens the finish block of work/design.dlib (not an archived run) and runs analyze_rail of RedHawk-SC on
# the routed PDN of FC. It saves nothing. Reports go to outputs/latest/rail_rh/. create_taps -top_pg takes the
# top-level VDD and VSS pins as the ideal supply, so the result shows if those pins are enough. RedHawk-SC is in
# the IC Validator install (pfsc/linux/bin/redhawk_sc, license SNPS_INDESIGN_RH_RAIL).
RAIL_PRODUCT      ?= redhawk_sc
RAIL_REDHAWK_PATH ?= $(ICV_HOME_DIR)/pfsc/linux/bin
RAIL_VOLTAGE_DROP ?= static
# Per-layer R and C for analyze_rail (RAIL-300). This RedHawk-SC takes itf, ircx or nrc, not atf. gf180mcu.itf
# comes from the PDK nxtgrd (StarRC grdgenxo -nxtgrd2itf) with the layer names mapped to the LEF names (see its
# header). grdgenxo needs the libnsl package on Rocky.
RAIL_TECH_FILE    ?= scripts/signoff/irdrop/tech/gf180mcu.itf
# Known gap: the static analysis works (worst drop 0.21 % on the 6 VDD and 6 VSS pins). dynamic_vectorless
# solves, but report_rail_result gives no per-pin values (RAIL-1120). Not root-caused.

# ------------------------------------------------------------------------------
# Fusion Compiler dynamic step rules (from scripts/0*_*.tcl)
# ------------------------------------------------------------------------------
# A target for every scripts/0*_*.tcl step: 01_read_rtl.tcl gives read_rtl, open_read_rtl and gui_read_rtl.
define MAKE_FC_RULE
.PHONY: $2 open_$2 gui_$2

$2: $(WORK_DIR)/design.dlib/$2

open_$2: $(WORK_DIR)/design.dlib/$2
	cd $(WORK_DIR) && fc_shell -f ../scripts/common/setup.tcl -x "open_lib design.dlib; open_block $2"

gui_$2: $(WORK_DIR)/design.dlib/$2
	cd $(WORK_DIR) && fc_shell -gui -f ../scripts/common/setup.tcl -x "open_lib design.dlib; open_block $2"

$(WORK_DIR)/design.dlib/$2: $3 $1
	mkdir -p $(LOGS_DIR) && cd $(WORK_DIR) && set -o pipefail; \
	fc_shell -batch -f ../$1 | tee logs/$2.log && ../scripts/utils/archive_run.sh $2
endef

TCL_FILES = $(sort $(wildcard scripts/0*_*.tcl))

DEPENDENCY :=
$(foreach file,$(TCL_FILES),\
  $(eval base := $(shell echo $(notdir $(file)) | sed -E 's/^[0-9]+_(.*)\.tcl/\1/'))\
  $(eval $(call MAKE_FC_RULE,$(file),$(base),$(DEPENDENCY)))\
  $(eval DEPENDENCY := $(WORK_DIR)/design.dlib/$(base))\
)

# Re-export of the PrimeTime inputs (06_finish.tcl writes them already): SDC, sign-off SDC, scan SDC and SPEF from
# the saved finish block into outputs/latest, without running finish again.
.PHONY: pt_export
pt_export:
	mkdir -p $(LOGS_DIR) && cd $(WORK_DIR) && set -o pipefail; \
	fc_shell -batch -f ../scripts/utils/pt_export.tcl | tee logs/pt_export.log && ../scripts/utils/archive_run.sh pt_export

# ------------------------------------------------------------------------------
# Full Flow
# ------------------------------------------------------------------------------
.PHONY: all
all: $(DEPENDENCY)
	@echo "[FLOW] Fusion Compiler flow completed successfully up to the final TCL script."

# ------------------------------------------------------------------------------
# Physical Verification - KLayout DRC (GF180MCU)
# ------------------------------------------------------------------------------
# KLayout DRC of the run GDS. Results in <run>/drc/ (merged .lyrdb and the log of every deck).
#   make drc
#   make drc GF180MCU_OPT=B                     # 4 metal layers instead of 5
#   make drc DRC_EXTRA="--antenna --density"
#   make drc RUN=croc_soc_20260804_101500
#   make finish drc
.PHONY: drc
drc:
	@if [ ! -e "$(GDS)" ]; then \
	  echo "[DRC] ERROR: GDS not found: $(GDS)"; \
	  echo "[DRC] Run 'make finish' (or 'make all') first, or pass RUN=<run-folder> / GDS=<path/to.gds>."; \
	  exit 1; \
	fi
	@if [ ! -f "$(DRC_HOME)/run_drc.py" ]; then \
	  echo "[DRC] ERROR: run_drc.py not found under DRC_HOME=$(DRC_HOME)"; \
	  echo "[DRC] Set DRC_HOME to the folder holding run_drc.py, rule_decks/ and utils/."; \
	  exit 1; \
	fi
	@gds_real="$$(readlink -f "$(GDS)")"; \
	 run_dir="$$(dirname "$$gds_real")"; \
	 out_dir="$$run_dir/drc"; \
	 mkdir -p "$$out_dir"; \
	 echo "[DRC] design : $$gds_real"; \
	 echo "[DRC] stack  : gf180mcu=$(GF180MCU_OPT)  mode=$(DRC_RUN_MODE)  extra='$(DRC_EXTRA)'"; \
	 echo "[DRC] results: $$out_dir"; \
	 ( cd "$$out_dir" && \
	   PDK_ROOT="$(DRC_PDK_ROOT)" PDK="$(DRC_PDK)" \
	   python3 "$(DRC_HOME)/run_drc.py" \
	     --path="$$gds_real" --gf180mcu=$(GF180MCU_OPT) \
	     --run_mode=$(DRC_RUN_MODE) $(DRC_EXTRA) \
	 ) 2>&1 | tee "$$out_dir/drc.log"
	@echo "[DRC] Done. Open the .lyrdb in KLayout: <run>/drc/*.lyrdb"

# ------------------------------------------------------------------------------
# Physical Verification - KLayout LVS (GF180MCU)
# ------------------------------------------------------------------------------
# KLayout LVS of the run: the SPICE netlist from the run Verilog (see LVS_* above) against the GDS. Results in
# <run>/lvs/.
#   make lvs
#   make lvs GF180MCU_OPT=B                      # 4 metal layers instead of 5
#   make lvs RUN=croc_soc_20260804_101500
#   make finish drc lvs
.PHONY: lvs
lvs:
	@if [ ! -e "$(GDS)" ]; then \
	  echo "[LVS] ERROR: GDS not found: $(GDS)"; \
	  echo "[LVS] Run 'make finish' (or 'make all') first, or pass RUN=<run-folder> / GDS=<path/to.gds>."; \
	  exit 1; \
	fi
	@if [ ! -e "$(VLOG)" ]; then \
	  echo "[LVS] ERROR: Verilog netlist not found: $(VLOG)"; \
	  echo "[LVS] Fusion Compiler must export it alongside the GDS (see 06_finish.tcl), or pass VLOG=<path/to.v>."; \
	  exit 1; \
	fi
	@if [ ! -f "$(LVS_HOME)/run_lvs.py" ]; then \
	  echo "[LVS] ERROR: run_lvs.py not found under LVS_HOME=$(LVS_HOME)"; \
	  echo "[LVS] Set LVS_HOME to the folder holding run_lvs.py, verilog2spice.py and gf180mcu.lvs."; \
	  exit 1; \
	fi
	@if [ ! -e "$(LVS_SC_CDL)" ]; then \
	  echo "[LVS] ERROR: standard-cell CDL not found: $(LVS_SC_CDL)"; \
	  echo "[LVS] Set LVS_PDK_KIT (or LVS_SC_CDL directly) to where ciel's gf180mcu_fd_sc_mcu7t5v0"; \
	  echo "[LVS]   libs.ref lives, e.g. run 'ciel ls' / check ~/.ciel/gf180mcu$(GF180MCU_OPT)."; \
	  echo "[LVS] Do NOT point it at gf180_drc_lvs/lvs/testing/sc_testcases/*.cdl (different, test-suite"; \
	  echo "[LVS]   cell names) or ~/pdk_synopsys/cdl/*.cdl (partial export, missing most cells)."; \
	  exit 1; \
	fi
	@mkdir -p "$(CACHE_DIR)"
	@if [ ! -e "$(FOLDED_SC_CDL)" ] || [ "$(LVS_SC_CDL)" -nt "$(FOLDED_SC_CDL)" ]; then \
	  echo "[LVS] Preparing standard-cell CDL ($(LVS_WELL_TIES) $(LVS_MODEL_RENAME)): $(FOLDED_SC_CDL)"; \
	  python3 "$(LVS_HOME)/fold_wells.py" $(LVS_WELL_TIES) $(LVS_MODEL_RENAME) "$(LVS_SC_CDL)" "$(FOLDED_SC_CDL)"; \
	fi
	@gds_real="$$(readlink -f "$(GDS)")"; \
	 vlog_real="$$(readlink -f "$(VLOG)")"; \
	 run_dir="$$(dirname "$$gds_real")"; \
	 out_dir="$$run_dir/lvs"; \
	 mkdir -p "$$out_dir"; \
	 set -o pipefail; \
	 echo "[LVS] design  : $$gds_real"; \
	 echo "[LVS] netlist : $$vlog_real"; \
	 echo "[LVS] stack   : gf180mcu=$(GF180MCU_OPT)  mode=$(LVS_RUN_MODE)  sub=$(LVS_SUB)"; \
	 echo "[LVS] results : $$out_dir"; \
	 echo "[LVS] Verilog -> SPICE ($(TOP).sp) via verilog2spice.py ..."; \
	 python3 "$(LVS_HOME)/verilog2spice.py" \
	     -v "$$vlog_real" -c "$(FOLDED_SC_CDL)" \
	     $(foreach cdl,$(LVS_BLACKBOX_CDL),--blackbox-cdl "$(cdl)") \
	     -o "$$out_dir/$(TOP).sp" \
	   2>&1 | tee "$$out_dir/verilog2spice.log"; \
	 v2s_status=$${PIPESTATUS[0]}; \
	 if [ "$$v2s_status" -ne 0 ]; then \
	   echo "[LVS] ERROR: verilog2spice.py reported missing cells (exit $$v2s_status)."; \
	   echo "[LVS] Check $$out_dir/verilog2spice.log -- a macro's CDL is likely missing from LVS_BLACKBOX_CDL."; \
	   exit 1; \
	 fi; \
	 lvs_gds="$$gds_real"; \
	 if [ -n "$(strip $(LVS_BLACKBOX_CELLS))" ]; then \
	   echo "[LVS] Black-boxing hard macro(s) in a copy of the GDS ($(LVS_BLACKBOX_CELLS)) ..."; \
	   echo "[LVS] ($(GDS) itself is untouched -- this only affects what LVS signs off against.)"; \
	   klayout -b -r "$(LVS_HOME)/blackbox_gds_cells.rb" \
	       -rd input="$$gds_real" \
	       -rd output="$$out_dir/$(TOP).lvs_blackbox.gds" \
	       -rd cells="$(subst $(space),$(comma),$(LVS_BLACKBOX_CELLS))" \
	     2>&1 | tee "$$out_dir/blackbox_gds.log"; \
	   bb_status=$${PIPESTATUS[0]}; \
	   if [ "$$bb_status" -ne 0 ]; then \
	     echo "[LVS] ERROR: blackbox_gds_cells.rb failed (exit $$bb_status), see $$out_dir/blackbox_gds.log"; \
	     exit 1; \
	   fi; \
	   lvs_gds="$$out_dir/$(TOP).lvs_blackbox.gds"; \
	 fi; \
	 echo "[LVS] Running KLayout LVS (GF180MCU) ..."; \
	 ( cd "$$out_dir" && \
	   PDK_ROOT="$(LVS_PDK_ROOT)" PDK="$(LVS_PDK)" \
	   python3 "$(LVS_HOME)/run_lvs.py" \
	     --design="$$lvs_gds" --net="$$out_dir/$(TOP).sp" --gf180mcu=$(GF180MCU_OPT) \
	     --run_mode=$(LVS_RUN_MODE) --lvs_sub=$(LVS_SUB) $(LVS_FLAGS) $(LVS_EXTRA) \
	     --blackbox_macros="$(subst $(space),$(comma),$(LVS_BLACKBOX_CELLS))" \
	     --exclude_from_compare="$(LVS_EXCLUDE_FROM_COMPARE)" \
	 ) 2>&1 | tee "$$out_dir/lvs.log"; \
	 echo "[LVS] Cross-checking with a second, independent comparison (lvs_compare.rb) ..."; \
	 klayout -b -r "$(LVS_HOME)/lvs_compare.rb" \
	     -rd layout_netlist="$$out_dir/extracted_netlist_$(TOP).cir" \
	     -rd schematic_netlist="$$out_dir/$(TOP).sp" \
	     -rd device_class_map="$(LVS_DEVICE_CLASS_MAP)" \
	     -rd blackbox_macros="$(subst $(space),$(comma),$(LVS_BLACKBOX_CELLS))" \
	     -rd exclude_from_compare="$(LVS_EXCLUDE_FROM_COMPARE)" \
	     -rd summary="$$out_dir/lvs_compare_summary.txt" \
	   > "$$out_dir/lvs_compare.log" 2>&1; \
	 if grep -q "INFO : Congratulations! Netlists match." "$$out_dir/lvs.log"; then \
	   echo "[LVS] MATCH. Open <run>/lvs/*.lvsdb in KLayout to review (File > Open, or the Netlist"; \
	   echo "[LVS] Browser panel) -- that database is now the authoritative, independently-viewable"; \
	   echo "[LVS] result. See also <run>/lvs/lvs_compare_summary.txt for a text cross-check."; \
	 else \
	   echo "[LVS] MISMATCH. Open <run>/lvs/*.lvsdb in KLayout (File > Open) to see exactly which"; \
	   echo "[LVS] circuits/nets/devices differ -- that database is the authoritative, independently-"; \
	   echo "[LVS] viewable result, not just this log. See also <run>/lvs/lvs_compare_summary.txt for"; \
	   echo "[LVS] a ranked text breakdown of the same result."; \
	   exit 1; \
	 fi

# ------------------------------------------------------------------------------
# Physical Verification - Synopsys IC Validator DRC (GF180MCU)
# ------------------------------------------------------------------------------
# IC Validator DRC of the run GDS with the decks of ICV_PDK_HOME. Results in <run>/drc_icv/.
#   make drc-icv
#   make drc-icv ICV_BEOL_STACK=1P4M                  # 4 metal layers instead of 5
#   make drc-icv ICV_DRC_RUNSET=$(ICV_PDK_HOME)/DRC_ICV_MODIFIED/DRC/ICV/gf180mcu_drc.rs
#   make drc-icv RUN=croc_soc_20260804_101500
#   make finish drc-icv
.PHONY: drc-icv
drc-icv:
	@if [ ! -e "$(GDS)" ]; then \
	  echo "[DRC-ICV] ERROR: GDS not found: $(GDS)"; \
	  echo "[DRC-ICV] Run 'make finish' (or 'make all') first, or pass RUN=<run-folder> / GDS=<path/to.gds>."; \
	  exit 1; \
	fi
	@if [ ! -x "$(ICV_HOME_DIR)/bin/icv" ]; then \
	  echo "[DRC-ICV] ERROR: icv not found under ICV_HOME_DIR=$(ICV_HOME_DIR)"; \
	  echo "[DRC-ICV] Set ICV_HOME_DIR to the IC Validator installation directory."; \
	  exit 1; \
	fi
	@if [ ! -f "$(ICV_DRC_RUNSET)" ]; then \
	  echo "[DRC-ICV] ERROR: runset not found: $(ICV_DRC_RUNSET)"; \
	  echo "[DRC-ICV] Set ICV_PDK_HOME (or ICV_DRC_RUNSET directly) to where pdk_synopsys/DRC_ICV* lives."; \
	  exit 1; \
	fi
	@gds_real="$$(readlink -f "$(GDS)")"; \
	 run_dir="$$(dirname "$$gds_real")"; \
	 out_dir="$$run_dir/drc_icv"; \
	 mkdir -p "$$out_dir"; \
	 set -o pipefail; \
	 echo "[DRC-ICV] design : $$gds_real"; \
	 echo "[DRC-ICV] runset : $(ICV_DRC_RUNSET)"; \
	 echo "[DRC-ICV] stack  : BEOL_STACK=$(ICV_BEOL_STACK) TOPMETAL=$(ICV_TOPMETAL) MIMCAP=$(ICV_MIMCAP) PADBONDING=$(ICV_PADBONDING)"; \
	 echo "[DRC-ICV] results: $$out_dir"; \
	 ( cd "$$out_dir" && \
	   PATH="$(ICV_HOME_DIR)/bin:$$PATH" ICV_HOME_DIR="$(ICV_HOME_DIR)" \
	   BEOL_STACK="$(ICV_BEOL_STACK)" TOPMETAL="$(ICV_TOPMETAL)" \
	   MIMCAP_SELECTION="$(ICV_MIMCAP)" PADBONDING="$(ICV_PADBONDING)" \
	   LATCH_CHECK="$(ICV_LATCH_CHECK)" \
	   icv -f gdsii -c "$(TOP)" -i "$$gds_real" -vue \
	     $(if $(ICV_RUNSET_CONFIG),-runset_config "$(REPO_DIR)/$(ICV_RUNSET_CONFIG)") \
	     -host_init $(ICV_HOST_INIT) $(ICV_DRC_EXTRA) \
	     "$(ICV_DRC_RUNSET)" \
	 ) 2>&1 | tee "$$out_dir/drc_icv.log"
	@echo "[DRC-ICV] Done. See <run>/drc_icv/$(TOP).RESULTS for the summary, or open"
	@echo "[DRC-ICV]   <run>/drc_icv/$(TOP).vue in IC Validator Live DRC / VUE to browse violations."

# ------------------------------------------------------------------------------
# Physical Verification - Synopsys IC Validator LVS (GF180MCU)
# ------------------------------------------------------------------------------
# IC Validator LVS: the SPICE netlist from the run Verilog (without the model rename, FOLDED_SC_CDL_ICV) against
# the GDS, with the same black-box macros as make lvs. Results in <run>/lvs_icv/.
#   make lvs-icv
#   make lvs-icv ICV_BEOL_STACK=1P4M                  # 4 metal layers instead of 5
#   make lvs-icv RUN=croc_soc_20260804_101500
#   make finish drc-icv lvs-icv
.PHONY: lvs-icv
lvs-icv:
	@if [ ! -e "$(GDS)" ]; then \
	  echo "[LVS-ICV] ERROR: GDS not found: $(GDS)"; \
	  echo "[LVS-ICV] Run 'make finish' (or 'make all') first, or pass RUN=<run-folder> / GDS=<path/to.gds>."; \
	  exit 1; \
	fi
	@if [ ! -e "$(VLOG)" ]; then \
	  echo "[LVS-ICV] ERROR: Verilog netlist not found: $(VLOG)"; \
	  echo "[LVS-ICV] Fusion Compiler must export it alongside the GDS (see 06_finish.tcl), or pass VLOG=<path/to.v>."; \
	  exit 1; \
	fi
	@if [ ! -x "$(ICV_HOME_DIR)/bin/icv" ]; then \
	  echo "[LVS-ICV] ERROR: icv not found under ICV_HOME_DIR=$(ICV_HOME_DIR)"; \
	  echo "[LVS-ICV] Set ICV_HOME_DIR to the IC Validator installation directory."; \
	  exit 1; \
	fi
	@if [ ! -f "$(ICV_LVS_RUNSET)" ]; then \
	  echo "[LVS-ICV] ERROR: runset not found: $(ICV_LVS_RUNSET)"; \
	  echo "[LVS-ICV] Set ICV_PDK_HOME (or ICV_LVS_RUNSET directly) to where pdk_synopsys/LVS_ICV lives."; \
	  exit 1; \
	fi
	@if [ ! -f "$(LVS_HOME)/verilog2spice.py" ] || [ ! -f "$(LVS_HOME)/fold_wells.py" ]; then \
	  echo "[LVS-ICV] ERROR: verilog2spice.py/fold_wells.py not found under LVS_HOME=$(LVS_HOME)"; \
	  echo "[LVS-ICV] Set LVS_HOME to the folder holding them (shared with the KLayout 'lvs' target)."; \
	  exit 1; \
	fi
	@if [ ! -e "$(LVS_SC_CDL)" ]; then \
	  echo "[LVS-ICV] ERROR: standard-cell CDL not found: $(LVS_SC_CDL)"; \
	  echo "[LVS-ICV] Set LVS_PDK_KIT (or LVS_SC_CDL directly) -- see the 'lvs' target above for details."; \
	  exit 1; \
	fi
	@mkdir -p "$(CACHE_DIR)"
	@if [ ! -e "$(FOLDED_SC_CDL_ICV)" ] || [ "$(LVS_SC_CDL)" -nt "$(FOLDED_SC_CDL_ICV)" ]; then \
	  echo "[LVS-ICV] Preparing standard-cell CDL ($(LVS_WELL_TIES), no model rename): $(FOLDED_SC_CDL_ICV)"; \
	  python3 "$(LVS_HOME)/fold_wells.py" $(LVS_WELL_TIES) "$(LVS_SC_CDL)" "$(FOLDED_SC_CDL_ICV)"; \
	fi
	@gds_real="$$(readlink -f "$(GDS)")"; \
	 vlog_real="$$(readlink -f "$(VLOG)")"; \
	 run_dir="$$(dirname "$$gds_real")"; \
	 out_dir="$$run_dir/lvs_icv"; \
	 mkdir -p "$$out_dir"; \
	 set -o pipefail; \
	 echo "[LVS-ICV] design  : $$gds_real"; \
	 echo "[LVS-ICV] netlist : $$vlog_real"; \
	 echo "[LVS-ICV] runset  : $(ICV_LVS_RUNSET)"; \
	 echo "[LVS-ICV] stack   : BEOL_STACK=$(ICV_BEOL_STACK)"; \
	 echo "[LVS-ICV] results : $$out_dir"; \
	 echo "[LVS-ICV] Verilog -> SPICE ($(TOP).sp) via verilog2spice.py ..."; \
	 python3 "$(LVS_HOME)/verilog2spice.py" \
	     -v "$$vlog_real" -c "$(FOLDED_SC_CDL_ICV)" \
	     $(foreach cdl,$(LVS_BLACKBOX_CDL),--blackbox-cdl "$(cdl)") \
	     -o "$$out_dir/$(TOP).sp" \
	   2>&1 | tee "$$out_dir/verilog2spice.log"; \
	 v2s_status=$${PIPESTATUS[0]}; \
	 if [ "$$v2s_status" -ne 0 ]; then \
	   echo "[LVS-ICV] ERROR: verilog2spice.py reported missing cells (exit $$v2s_status)."; \
	   echo "[LVS-ICV] Check $$out_dir/verilog2spice.log -- a macro's CDL is likely missing from LVS_BLACKBOX_CDL."; \
	   exit 1; \
	 fi; \
	 lvs_gds="$$gds_real"; \
	 if [ -n "$(strip $(LVS_BLACKBOX_CELLS))" ]; then \
	   echo "[LVS-ICV] Black-boxing hard macro(s) in a copy of the GDS ($(LVS_BLACKBOX_CELLS)) ..."; \
	   echo "[LVS-ICV] ($(GDS) itself is untouched -- this only affects what LVS signs off against.)"; \
	   klayout -b -r "$(LVS_HOME)/blackbox_gds_cells.rb" \
	       -rd input="$$gds_real" \
	       -rd output="$$out_dir/$(TOP).lvs_blackbox.gds" \
	       -rd cells="$(subst $(space),$(comma),$(LVS_BLACKBOX_CELLS))" \
	     2>&1 | tee "$$out_dir/blackbox_gds.log"; \
	   bb_status=$${PIPESTATUS[0]}; \
	   if [ "$$bb_status" -ne 0 ]; then \
	     echo "[LVS-ICV] ERROR: blackbox_gds_cells.rb failed (exit $$bb_status), see $$out_dir/blackbox_gds.log"; \
	     exit 1; \
	   fi; \
	   lvs_gds="$$out_dir/$(TOP).lvs_blackbox.gds"; \
	 fi; \
	 echo "[LVS-ICV] Running IC Validator LVS (GF180MCU) ..."; \
	 ( cd "$$out_dir" && \
	   PATH="$(ICV_HOME_DIR)/bin:$$PATH" ICV_HOME_DIR="$(ICV_HOME_DIR)" \
	   ICV_LVS="$(ICV_LVS_HOME)" BEOL_STACK="$(ICV_BEOL_STACK)" \
	   icv -f gdsii -c "$(TOP)" -i "$$lvs_gds" \
	     -s "$$out_dir/$(TOP).sp" -sf SPICE -vue \
	     $(if $(ICV_RUNSET_CONFIG),-runset_config "$(REPO_DIR)/$(ICV_RUNSET_CONFIG)") \
	     -host_init $(ICV_HOST_INIT) $(ICV_LVS_EXTRA) \
	     "$(ICV_LVS_RUNSET)" \
	 ) 2>&1 | tee "$$out_dir/lvs_icv.log"; \
	 if grep -q "LVS Compare Result: PASS" "$$out_dir/$(TOP).RESULTS" 2>/dev/null; then \
	   echo "[LVS-ICV] MATCH. See $$out_dir/$(TOP).RESULTS for the summary, or open"; \
	   echo "[LVS-ICV]   $$out_dir/$(TOP).vue in IC Validator Live DRC / VUE to browse the compare tree."; \
	 else \
	   echo "[LVS-ICV] MISMATCH (or run failed). See $$out_dir/$(TOP).RESULTS for the summary, or open"; \
	   echo "[LVS-ICV]   $$out_dir/$(TOP).vue in IC Validator Live DRC / VUE to see exactly which"; \
	   echo "[LVS-ICV]   circuits/nets/devices differ."; \
	   exit 1; \
	 fi

# ------------------------------------------------------------------------------
# Metal Fill - Synopsys IC Validator (GF180MCU, density signoff)
# ------------------------------------------------------------------------------
# Metal fill of the run GDS with croc_metal_fill.rs into a new file, <run>/fill_icv/filled.gds. $(GDS) does not
# change: give the filled GDS to the checks with GDS=.../fill_icv/filled.gds.
#   make fill-icv
#   make fill-icv RUN=croc_soc_20260804_101500
#   make drc GDS=outputs/latest/fill_icv/filled.gds DRC_EXTRA=--density_only
#   make finish fill-icv
.PHONY: fill-icv
fill-icv:
	@if [ ! -e "$(GDS)" ]; then \
	  echo "[FILL-ICV] ERROR: GDS not found: $(GDS)"; \
	  echo "[FILL-ICV] Run 'make finish' (or 'make all') first, or pass RUN=<run-folder> / GDS=<path/to.gds>."; \
	  exit 1; \
	fi
	@if [ ! -x "$(ICV_HOME_DIR)/bin/icv" ]; then \
	  echo "[FILL-ICV] ERROR: icv not found under ICV_HOME_DIR=$(ICV_HOME_DIR)"; \
	  echo "[FILL-ICV] Set ICV_HOME_DIR to the IC Validator installation directory."; \
	  exit 1; \
	fi
	@if [ ! -f "$(ICV_FILL_RUNSET)" ]; then \
	  echo "[FILL-ICV] ERROR: runset not found: $(ICV_FILL_RUNSET)"; \
	  exit 1; \
	fi
	@if [ ! -d "$(ICV_FILL_INCLUDE_DIR)" ]; then \
	  echo "[FILL-ICV] ERROR: include dir not found: $(ICV_FILL_INCLUDE_DIR)"; \
	  echo "[FILL-ICV] Set ICV_PDK_HOME (or ICV_FILL_INCLUDE_DIR directly) to where pdk_synopsys/DRC_ICV_MODIFIED lives."; \
	  exit 1; \
	fi
	@gds_real="$$(readlink -f "$(GDS)")"; \
	 run_dir="$$(dirname "$$gds_real")"; \
	 out_dir="$$run_dir/fill_icv"; \
	 mkdir -p "$$out_dir"; \
	 set -o pipefail; \
	 echo "[FILL-ICV] design : $$gds_real"; \
	 echo "[FILL-ICV] runset : $(ICV_FILL_RUNSET)"; \
	 echo "[FILL-ICV] results: $$out_dir"; \
	 ( cd "$$out_dir" && \
	   PATH="$(ICV_HOME_DIR)/bin:$$PATH" ICV_HOME_DIR="$(ICV_HOME_DIR)" \
	   icv -f gdsii -c "$(TOP)" -i "$$gds_real" \
	     -I "$(ICV_FILL_INCLUDE_DIR)" \
	     -host_init $(ICV_HOST_INIT) $(ICV_FILL_EXTRA) \
	     "$(REPO_DIR)/$(ICV_FILL_RUNSET)" \
	 ) 2>&1 | tee "$$out_dir/fill_icv.log"; \
	 if [ ! -e "$$out_dir/filled.gds" ]; then \
	   echo "[FILL-ICV] ERROR: filled.gds was not produced -- check $$out_dir/fill_icv.log"; \
	   exit 1; \
	 fi; \
	 echo "[FILL-ICV] Done. Filled GDS: $$out_dir/filled.gds"; \
	 echo "[FILL-ICV]   Re-check density with: make drc GDS=$$out_dir/filled.gds DRC_EXTRA=--density_only"; \
	 echo "[FILL-ICV]   Or full DRC with:      make drc GDS=$$out_dir/filled.gds"

# ------------------------------------------------------------------------------
# Signoff STA - Synopsys PrimeTime (GF180MCU, MCMM: slow/typical/fast)
# ------------------------------------------------------------------------------
# PrimeTime STA, one pt_shell per corner (sta_corner.tcl). Setup at slow and typical, hold at fast, as in mcmm.tcl.
# Reports in <run>/sta_pt/ and a summary at the end.
#
# Typical use (after `make finish`):
#   make sta-pt                                # all 3 corners, outputs/latest
#   make sta-pt RUN=croc_soc_20260804_101500   # re-check an older run
.PHONY: sta-pt
sta-pt:
	@if [ ! -x "$(PT_HOME_DIR)/bin/pt_shell" ]; then \
	  echo "[STA-PT] ERROR: pt_shell not found under PT_HOME_DIR=$(PT_HOME_DIR)"; \
	  exit 1; \
	fi
	@if [ ! -e "$(SPEC_SDC)" ]; then \
	  echo "[STA-PT] ERROR: sign-off SDC not found: $(SPEC_SDC)"; \
	  echo "[STA-PT] Run 'make finish' first, or 'make pt_export' to write SDC+SPEF again from the finish block."; \
	  exit 1; \
	fi
	@mkdir -p "$(CACHE_DIR)"
	@if [ ! -e "$(PT_SRAM_DB)" ] || [ "$(PT_SRAM_LIB)" -nt "$(PT_SRAM_DB)" ]; then \
	  echo "[STA-PT] Compiling SRAM liberty -> db (Library Compiler): $(PT_SRAM_DB)"; \
	  PATH="$(LC_HOME_DIR)/bin:$$PATH" lc_shell -x " \
	    read_lib $(PT_SRAM_LIB); \
	    write_lib gf180mcu_fd_ip_sram__sram512x8m8wm1__tt_025C_5v00 -format db -output $(PT_SRAM_DB); \
	    exit" 2>&1 | tee "$(CACHE_DIR)/lc_sram.log"; \
	  if [ ! -e "$(PT_SRAM_DB)" ]; then \
	    echo "[STA-PT] ERROR: SRAM db compile failed, see $(CACHE_DIR)/lc_sram.log"; exit 1; \
	  fi; \
	fi
	@vlog_real="$$(readlink -f "$(VLOG)")"; \
	 sdc_real="$$(readlink -f "$(SPEC_SDC)")"; \
	 run_dir="$$(dirname "$$vlog_real")"; \
	 out_dir="$$run_dir/sta_pt"; \
	 mkdir -p "$$out_dir"; \
	 set -o pipefail; \
	 echo "[STA-PT] design  : $$vlog_real"; \
	 echo "[STA-PT] sdc     : $$sdc_real"; \
	 echo "[STA-PT] results : $$out_dir"; \
	 for spec in "slow $(PT_SC_DB_slow) $(PT_IO_DB_slow) typ_125" \
	             "typical $(PT_SC_DB_typical) $(PT_IO_DB_typical) typ_25" \
	             "fast $(PT_SC_DB_fast) $(PT_IO_DB_fast) typ_-40"; do \
	   set -- $$spec; corner=$$1; sc_db=$$2; io_db=$$3; spef_suffix=$$4; \
	   spef="$$run_dir/$(TOP).$${spef_suffix}.spef"; \
	   if [ ! -e "$$spef" ]; then \
	     echo "[STA-PT] ERROR: SPEF not found for corner $$corner: $$spef"; \
	     echo "[STA-PT] Run 'make finish' or 'make pt_export' first."; \
	     exit 1; \
	   fi; \
	   echo "[STA-PT] --- corner: $$corner ---"; \
	   ( cd "$$out_dir" && PATH="$(PT_HOME_DIR)/bin:$$PATH" pt_shell -x " \
	     set CORNER $$corner; \
	     set TOP $(TOP); \
	     set VLOG $$vlog_real; \
	     set SDC_FILE $$sdc_real; \
	     set SPEF_FILE $$spef; \
	     set SC_DB $$sc_db; \
	     set IO_DB $$io_db; \
	     set SRAM_DB $(abspath $(PT_SRAM_DB)); \
	     set REPORT_DIR $$out_dir; \
	     source $(REPO_DIR)/scripts/signoff/sta/sta_corner.tcl; \
	     exit" ) \
	   2>&1 | tee "$$out_dir/sta_pt.$$corner.log"; \
	 done; \
	 echo "[STA-PT] ================ Summary ================"; \
	 for corner in slow typical; do \
	   echo "[STA-PT] setup @ $$corner (Path Group 'clock'):"; \
	   grep -A5 "Timing Path Group 'clock' (max_delay/setup)" "$$out_dir/report_qor.$$corner.rpt" 2>/dev/null | sed 's/^/  /'; \
	 done; \
	 echo "[STA-PT] hold @ fast (Path Group 'clock'):"; \
	 grep -A5 "Timing Path Group 'clock' (min_delay/hold)" "$$out_dir/report_qor.fast.rpt" 2>/dev/null | sed 's/^/  /'; \
	 echo "[STA-PT] Full reports: $$out_dir/*.rpt"

# ------------------------------------------------------------------------------
# Power analysis - Synopsys PrimePower (GF180MCU)
# ------------------------------------------------------------------------------
# PrimePower with the setup of sta-pt (power_corner.tcl, power commands in plain pt_shell). Vectorless activity, or
# PP_SAIF=<file.saif> for simulated activity.
#
# Typical use (after `make finish`):
#   make power-pp                                # fast corner only (default)
#   make power-pp PP_CORNERS="slow typical fast"  # all 3, for comparison
#   make power-pp PP_SAIF=sim/build/croc.saif     # real activity once available
.PHONY: power-pp
power-pp:
	@if [ ! -x "$(PT_HOME_DIR)/bin/pt_shell" ]; then \
	  echo "[POWER-PP] ERROR: pt_shell not found under PT_HOME_DIR=$(PT_HOME_DIR)"; \
	  exit 1; \
	fi
	@if [ ! -e "$(SDC)" ]; then \
	  echo "[POWER-PP] ERROR: SDC not found: $(SDC)"; \
	  echo "[POWER-PP] Run 'make finish' first, or 'make pt_export' to write SDC+SPEF again from the finish block."; \
	  exit 1; \
	fi
	@mkdir -p "$(CACHE_DIR)"
	@if [ ! -e "$(PT_SRAM_DB)" ] || [ "$(PT_SRAM_LIB)" -nt "$(PT_SRAM_DB)" ]; then \
	  echo "[POWER-PP] Compiling SRAM liberty -> db (Library Compiler): $(PT_SRAM_DB)"; \
	  PATH="$(LC_HOME_DIR)/bin:$$PATH" lc_shell -x " \
	    read_lib $(PT_SRAM_LIB); \
	    write_lib gf180mcu_fd_ip_sram__sram512x8m8wm1__tt_025C_5v00 -format db -output $(PT_SRAM_DB); \
	    exit" 2>&1 | tee "$(CACHE_DIR)/lc_sram.log"; \
	  if [ ! -e "$(PT_SRAM_DB)" ]; then \
	    echo "[POWER-PP] ERROR: SRAM db compile failed, see $(CACHE_DIR)/lc_sram.log"; exit 1; \
	  fi; \
	fi
	@vlog_real="$$(readlink -f "$(VLOG)")"; \
	 sdc_real="$$(readlink -f "$(SDC)")"; \
	 run_dir="$$(dirname "$$vlog_real")"; \
	 out_dir="$$run_dir/power_pp"; \
	 mkdir -p "$$out_dir"; \
	 set -o pipefail; \
	 echo "[POWER-PP] design  : $$vlog_real"; \
	 echo "[POWER-PP] sdc     : $$sdc_real"; \
	 echo "[POWER-PP] corners : $(PP_CORNERS)"; \
	 echo "[POWER-PP] results : $$out_dir"; \
	 for corner in $(PP_CORNERS); do \
	   case $$corner in \
	     slow)    sc_db="$(PT_SC_DB_slow)";    io_db="$(PT_IO_DB_slow)";    spef_suffix=typ_125 ;; \
	     typical) sc_db="$(PT_SC_DB_typical)"; io_db="$(PT_IO_DB_typical)"; spef_suffix=typ_25  ;; \
	     fast)    sc_db="$(PT_SC_DB_fast)";    io_db="$(PT_IO_DB_fast)";    spef_suffix=typ_-40 ;; \
	     *) echo "[POWER-PP] ERROR: unknown corner '$$corner' (expected slow|typical|fast)"; exit 1 ;; \
	   esac; \
	   spef="$$run_dir/$(TOP).$${spef_suffix}.spef"; \
	   if [ ! -e "$$spef" ]; then \
	     echo "[POWER-PP] ERROR: SPEF not found for corner $$corner: $$spef"; \
	     echo "[POWER-PP] Run 'make finish' or 'make pt_export' first."; \
	     exit 1; \
	   fi; \
	   echo "[POWER-PP] --- corner: $$corner ---"; \
	   ( cd "$$out_dir" && PATH="$(PT_HOME_DIR)/bin:$$PATH" pt_shell -x " \
	     set CORNER $$corner; \
	     set TOP $(TOP); \
	     set VLOG $$vlog_real; \
	     set SDC_FILE $$sdc_real; \
	     set SPEF_FILE $$spef; \
	     set SC_DB $$sc_db; \
	     set IO_DB $$io_db; \
	     set SRAM_DB $(abspath $(PT_SRAM_DB)); \
	     set REPORT_DIR $$out_dir; \
	     set PP_TOGGLE_RATE $(PP_DEFAULT_TOGGLE_RATE); \
	     set PP_STATIC_PROB $(PP_DEFAULT_STATIC_PROB); \
	     set PP_SAIF {$(abspath $(PP_SAIF))}; \
	     source $(REPO_DIR)/scripts/signoff/power/power_corner.tcl; \
	     exit" ) \
	   2>&1 | tee "$$out_dir/power_pp.$$corner.log"; \
	 done; \
	 echo "[POWER-PP] ================ Summary ================"; \
	 for corner in $(PP_CORNERS); do \
	   echo "[POWER-PP] $$corner:"; \
	   grep "Total Power" "$$out_dir/report_power_summary.$$corner.rpt" 2>/dev/null | sed 's/^/  /'; \
	 done; \
	 echo "[POWER-PP] Full reports: $$out_dir/*.rpt"

# ------------------------------------------------------------------------------
# Sign-off Rail Analysis - RedHawk-SC Fusion (in-design voltage drop / IR drop)
# ------------------------------------------------------------------------------
# RedHawk-SC rail analysis of the finish block in work/design.dlib (see RAIL_* above). Reports in
# outputs/latest/rail_rh/.
#   make rail                                         # static
#   make rail RAIL_VOLTAGE_DROP=dynamic_vectorless    # solves, no per-pin values yet (see the known gap above)
.PHONY: rail
rail:
	@if [ ! -x "$$(command -v fc_shell)" ]; then \
	  echo "[RAIL] ERROR: fc_shell not found on PATH."; \
	  exit 1; \
	fi
	@if [ ! -e "$(WORK_DIR)/design.dlib/finish" ]; then \
	  echo "[RAIL] ERROR: no 'finish' block in $(WORK_DIR)/design.dlib."; \
	  echo "[RAIL] Run 'make finish' (or 'make all') first."; \
	  exit 1; \
	fi
	@if [ ! -x "$(RAIL_REDHAWK_PATH)/redhawk_sc" ]; then \
	  echo "[RAIL] ERROR: redhawk_sc not found under RAIL_REDHAWK_PATH=$(RAIL_REDHAWK_PATH)"; \
	  echo "[RAIL] Set RAIL_REDHAWK_PATH to the directory containing the redhawk_sc executable."; \
	  exit 1; \
	fi
	@if [ -z "$(RAIL_TECH_FILE)" ] || [ ! -e "$(RAIL_TECH_FILE)" ]; then \
	  echo "[RAIL] ERROR: RAIL_TECH_FILE not set or not found: '$(RAIL_TECH_FILE)'"; \
	  echo "[RAIL] Default is scripts/signoff/irdrop/tech/gf180mcu.itf (checked into this repo --"; \
	  echo "[RAIL] see its header for provenance). If it's missing, restore it or set"; \
	  echo "[RAIL] RAIL_TECH_FILE to another real ITF/IRCX/NRC tech file."; \
	  exit 1; \
	fi
	@out_dir="$(OUTPUTS_DIR)/latest/rail_rh"; \
	 mkdir -p "$$out_dir"; \
	 tech_file_real="$$(readlink -f "$(RAIL_TECH_FILE)")"; \
	 out_dir_real="$$(readlink -f "$$out_dir")"; \
	 set -o pipefail; \
	 echo "[RAIL] design    : $(TOP) ('finish' block, $(WORK_DIR)/design.dlib)"; \
	 echo "[RAIL] product   : $(RAIL_PRODUCT)"; \
	 echo "[RAIL] tech_file : $$tech_file_real"; \
	 echo "[RAIL] mode      : $(RAIL_VOLTAGE_DROP)"; \
	 echo "[RAIL] results   : $$out_dir"; \
	 cd $(WORK_DIR) && fc_shell -batch -x " \
	   set TOP $(TOP); \
	   set REPORT_DIR $$out_dir_real; \
	   set RAIL_PRODUCT $(RAIL_PRODUCT); \
	   set RAIL_REDHAWK_PATH $(RAIL_REDHAWK_PATH); \
	   set RAIL_TECH_FILE $$tech_file_real; \
	   set RAIL_VOLTAGE_DROP $(RAIL_VOLTAGE_DROP); \
	   source ../scripts/signoff/irdrop/analyze_rail.tcl; \
	   exit" \
	 2>&1 | tee "$$out_dir_real/rail.$(RAIL_VOLTAGE_DROP).log"; \
	 echo "[RAIL] Full report: $$out_dir/voltage_drop.$(RAIL_VOLTAGE_DROP).rpt"

# ------------------------------------------------------------------------------
# Clean
# ------------------------------------------------------------------------------
.PHONY: clean distclean
clean:
	rm -rf $(WORK_DIR)
	@echo "Cleaned the work directory (staging of logs and reports included)."

# distclean also removes the exported GDS/netlists in outputs/. Use with care.
distclean: clean
	rm -rf $(OUTPUTS_DIR)
	@echo "Also removed the outputs directory (exported GDS/netlists)."

# ------------------------------------------------------------------------------
# Software & Simulation Flow
# ------------------------------------------------------------------------------
.PHONY: sw sim sim-vcs verilate run clean-sw clean-sim

# Default program. Example: make run BIN=sim/sw/bin/test/test_gpio.hex
BIN ?= sim/sw/hello_world/bin/helloworld.hex

sw:
	@echo "[SW] Compiling RISC-V bare-metal software..."
	@$(MAKE) -C sim/sw

clean-sw:
	@echo "[SW] Cleaning software binaries..."
	@$(MAKE) -C sim/sw clean

# Build the Verilator model only (again after every RTL change)
verilate:
	@echo "[SIM] Compiling Verilator hardware model..."
	@cd sim && BUILD_ONLY=1 bash ../scripts/sim/run_verilator.sh

# Run a program on the built model, no rebuild
run: sw
	@echo "[SIM] Running $(BIN) ..."
	@cd sim && BIN=$(abspath $(BIN)) SKIP_BUILD=1 bash ../scripts/sim/run_verilator.sh

# Build and run (default helloworld)
sim:
	@echo "[SIM] Launching Verilator simulation flow..."
	@cd sim && BIN=$(abspath $(BIN)) bash ../scripts/sim/run_verilator.sh

# Build the VCS model (elaboration)
vcs-compile:
	@echo "[SIM] Compiling VCS hardware model..."
	@cd sim && BUILD_ONLY=1 bash ../scripts/sim/run_vcs.sh

# Run a program on the VCS model of a previous vcs-compile
run-vcs: sw
	@echo "[SIM] Running $(BIN) on VCS..."
	@cd sim && BIN=$(abspath $(BIN)) SKIP_BUILD=1 bash ../scripts/sim/run_vcs.sh

# Build and run with VCS
sim-vcs: sw
	@echo "[SIM] Launching full VCS simulation flow..."
	@cd sim && BIN=$(abspath $(BIN)) bash ../scripts/sim/run_vcs.sh

clean-sim:
	@echo "[SIM] Cleaning simulation builds..."
	@rm -rf sim/build/*

# ------------------------------------------------------------------------------
# FPGA (ZedBoard / Zynq-7000 PL) Flow -- requires Vivado on PATH
# ------------------------------------------------------------------------------
.PHONY: fpga clean-fpga

VIVADO ?= vivado

# Vivado batch build (synthesis, place, route, bitstream) from croc_fpga.flist and constraints/zedboard.xdc.
# Output in work_fpga/.
fpga:
	@echo "[FPGA] Running Vivado non-project build for the ZedBoard..."
	@$(VIVADO) -mode batch -source scripts/fpga/build_zedboard.tcl

clean-fpga:
	rm -rf work_fpga vivado*.log vivado*.jou vivado*.str .Xil
	@echo "Cleaned FPGA build directory and Vivado logs."

# ------------------------------------------------------------------------------
# Help Menu
# ------------------------------------------------------------------------------
.PHONY: help
help:
	@echo "================================================================"
	@echo " Croc SoC Fusion Compiler + DRC/LVS Flow"
	@echo "================================================================"
	@echo "Main Targets:"
	@echo "  make all        – Run all available Fusion Compiler steps sequentially"
	@echo "  make drc        – KLayout GF180MCU DRC on the latest run's GDS"
	@echo "  make lvs        – Verilog->SPICE + KLayout GF180MCU LVS on the latest run"
	@echo "  make drc-icv    – Synopsys IC Validator GF180MCU DRC on the latest run's GDS"
	@echo "  make lvs-icv    – Verilog->SPICE + Synopsys IC Validator GF180MCU LVS"
	@echo "  make fill-icv   – Synopsys IC Validator Metal1-5 dummy fill (density signoff)"
	@echo "  make sta-pt     – Synopsys PrimeTime signoff STA (MCMM: slow/typical/fast)"
	@echo "  make power-pp   – Synopsys PrimePower power analysis"
	@echo "  make rail       – RedHawk-SC in-design voltage/IR drop (static works; dynamic partial)"
	@echo "  make clean      – Delete the 'work' directory (library, staged logs and reports)"
	@echo "  make distclean  – clean + also delete 'outputs' (exported GDS/netlists/results)"
	@echo ""
	@echo "Individual Steps (dynamically generated from scripts/):"
	@echo "  make read_rtl"
	@echo "  make floorplan"
	@echo "  make synthesis"
	@echo "  make cts"
	@echo "  make route"
	@echo "  make finish"
	@echo "  (make finish also writes the SDC + per-corner SPEF for sta-pt/power-pp)"
	@echo ""
	@echo "Run selection (shared by drc and lvs):"
	@echo "  make drc                           – sign off outputs/latest (default)"
	@echo "  make lvs RUN=$(TOP)_20260804_101500  – sign off a specific (older) run"
	@echo "  make drc GDS=/path/to.gds VLOG=/path/to.v  – fully explicit override"
	@echo ""
	@echo "DRC options (KLayout / GF180MCU):"
	@echo "  make drc GF180MCU_OPT=C            – metal stack A=3LM B=4LM C=5LM (default C)"
	@echo "  make drc DRC_RUN_MODE=deep         – flat|deep|tiling (default flat)"
	@echo "  make drc DRC_EXTRA=\"--antenna --density\"  – add extra checks"
	@echo "  make drc DRC_HOME=/path/to/gf180mcu– where run_drc.py + rule_decks/ live"
	@echo "  make finish drc                    – build finish, then run DRC"
	@echo ""
	@echo "LVS options (KLayout / GF180MCU):"
	@echo "  make lvs GF180MCU_OPT=C            – metal stack A=3LM B=4LM C=5LM (default C)"
	@echo "  make lvs LVS_RUN_MODE=flat         – flat|deep|tiling (default deep)"
	@echo "  make lvs LVS_SUB=VSS               – substrate net name (default VSS)"
	@echo "  make lvs LVS_HOME=/path/to/gf180mcu– where run_lvs.py + verilog2spice.py live"
	@echo "  make lvs LVS_BLACKBOX_CELLS=       – sign off the real GDS as-is (default black-boxes"
	@echo "                                       hard macros like SRAM -- see LVS_BLACKBOX_CELLS in"
	@echo "                                       the Makefile; the run's .gds itself is never"
	@echo "                                       modified, so 'make finish'/tapeout output always"
	@echo "                                       has the real macro)"
	@echo "  make finish drc lvs                – build finish, then DRC, then LVS"
	@echo ""
	@echo "DRC/LVS options (Synopsys IC Validator / GF180MCU):"
	@echo "  make drc-icv ICV_BEOL_STACK=1P5M    – metal stack 1P3M=A 1P4M=B 1P5M=C (default 1P5M)"
	@echo "  make drc-icv ICV_DRC_RUNSET=...     – switch to DRC_ICV_MODIFIED/ or a custom deck"
	@echo "  make lvs-icv ICV_PDK_HOME=/path     – where pdk_synopsys/{DRC_ICV,LVS_ICV} live"
	@echo "  make finish drc-icv lvs-icv         – build finish, then IC Validator DRC, then LVS"
	@echo ""
	@echo "Metal fill / density signoff (Synopsys IC Validator / GF180MCU):"
	@echo "  make fill-icv                       – fill outputs/latest's GDS -> .../fill_icv/filled.gds"
	@echo "  make drc GDS=outputs/latest/fill_icv/filled.gds DRC_EXTRA=--density_only"
	@echo "                                       – re-check density on the filled GDS (KLayout)"
	@echo "  make finish fill-icv                – build finish, then fill"
	@echo ""
	@echo "Signoff STA / power (Synopsys PrimeTime / PrimePower):"
	@echo "  make pt_export                       – write SDC + per-corner SPEF again from the finish block (make finish writes them)"
	@echo "  make sta-pt                          – PrimeTime STA, all 3 MCMM corners (slow/typical/fast)"
	@echo "  make sta-pt RUN=$(TOP)_20260804_101500 – re-check an older run"
	@echo "  make finish sta-pt                   – build (writes SDC/SPEF), then run signoff STA"
	@echo "  Setup is checked at slow+typical, hold at fast (mirrors scripts/common/mcmm.tcl's"
	@echo "  own set_scenario_status split). SRAM macro uses the same tt/25C/5.0V liberty view"
	@echo "  at all 3 corners -- this PDK kit ships no ss/ff SRAM characterization (see"
	@echo "  scripts/signoff/sta/sta_corner.tcl header comment); everything else is corner-accurate."
	@echo ""
	@echo "  make power-pp                        – PrimePower analysis, same SDC/SPEF/libs as sta-pt"
	@echo "  Vectorless (default switching activity) power estimate -- no gate-level VCD/SAIF from a"
	@echo "  real workload exists yet in this environment; set PP_SAIF=<file> once one does."
	@echo ""
	@echo "Signoff rail analysis (RedHawk-SC Fusion, in-design voltage/IR drop):"
	@echo "  make rail                                         – static voltage drop, latest 'finish' block"
	@echo "  make rail RAIL_VOLTAGE_DROP=dynamic_vectorless    – dynamic (solves clean, per-pin report"
	@echo "                                                       extraction not working yet, see Makefile)"
	@echo "  Treats croc_soc's 6 VDD + 6 VSS top-level pins as the ideal supply (create_taps -top_pg)"
	@echo "  and solves for voltage drop across the real, routed PDN -- this is the direct answer to"
	@echo "  whether those 6 pins are enough. Uses scripts/signoff/irdrop/tech/gf180mcu.itf by default (real"
	@echo "  GF180MCU parasitics recovered from the PDK's own field-solver binary, see its header)."
	@echo ""
	@echo "Outputs (one self-contained folder per Fusion Compiler run):"
	@echo "  outputs/$(TOP)_<timestamp>/$(TOP).gds/.v  – timestamped, never overwritten"
	@echo "  outputs/latest                      – symlink to the most recent run folder"
	@echo "  outputs/<run>/drc/                  – KLayout DRC .lyrdb + logs for that run"
	@echo "  outputs/<run>/lvs/                  – KLayout LVS .sp/.lvsdb/extracted netlist + logs"
	@echo "  outputs/<run>/drc_icv/               – IC Validator DRC .RESULTS/.vue + logs"
	@echo "  outputs/<run>/lvs_icv/               – IC Validator LVS .sp/.RESULTS/.vue + logs"
	@echo "  outputs/<run>/fill_icv/              – IC Validator filled.gds + logs"
	@echo "  outputs/<run>/$(TOP).sdc, .typ_*.spef – SDC + per-corner parasitics (written at finish)"
	@echo "  outputs/<run>/sta_pt/                – PrimeTime timing/constraint/QoR reports"
	@echo "  outputs/<run>/reports/<step>/        – QoR, timing, DRC reports of every flow step (01..05 copied at 06_finish, 06 and export_signoff written there)"
	@echo "  outputs/<run>/logs/, svf/            – step logs and Formality guidance files of that build (copied at finish)"
	@echo "  outputs/<run>/power_pp/               – PrimePower reports"
	@echo "  outputs/latest/rail_rh/               – RedHawk-SC rail analysis report + log"
	@echo "  outputs/.cache/                     – cached folded CDLs + SRAM liberty->db (rebuilt only if stale)"
	@echo ""
	@echo "Simulation (Verilator):"
	@echo "  make sim                       – Compile + run (defaults to helloworld)"
	@echo "  make sim BIN=<path/to.hex>     – Compile + run a specific application"
	@echo "  make verilate                  – Compile the HW model only (after RTL changes)"
	@echo "  make run BIN=<path/to.hex>     – Run an app on the compiled model (no recompile)"
	@echo "  make clean-sim                 – Remove the simulation build directory"
	@echo ""
	@echo "GUI / Interactive Commands:"
	@echo "  make open_<step> – Open a specific block in terminal mode"
	@echo "  make gui_<step>  – Open a specific block in GUI mode"
	@echo ""
	@echo "FPGA (ZedBoard, requires Vivado on PATH):"
	@echo "  make fpga        – Non-project batch build -> work_fpga/croc_zedboard_top.bit"
	@echo "  make clean-fpga  – Remove the FPGA build directory and Vivado logs"
	@echo "================================================================"
# ------------------------------------------------------------------------------
# Checks of a finished run (scripts/signoff, scripts/sim, scripts/dft, scripts/chip)
# ------------------------------------------------------------------------------
# Every check reads RUN (a folder name under outputs/ or an absolute path, default latest) and writes
# outputs/<run>/checks/<step>/summary.txt. `make report` collects them into outputs/<run>/report.md.
# Tool paths are in scripts/utils/env.sh (override in scripts/utils/local.env).
#
#   make signoff   KLayout DRC and LVS, functional STA at 3 corners, Formality   (needs a run made with `make all`)
#   make scan-sta  scan-shift STA, 3 corners
#   make gls       Verilator boot, scan shift, Icarus macro boot over JTAG
#   make dft       scan chain trace, ATPG, pattern replay (NPAT=20 for a quick run), SRAM March test
#   make chip      chip flow with the pad ring, precheck (COB=0: without --cob), chip-level GLS
#   make check     scan-sta + gls + dft + chip, then the report
.PHONY: signoff scan-sta gls dft chip check report
signoff:
	$(MAKE) drc lvs sta-pt
	$(REPO_DIR)/scripts/signoff/lec/run_lec.sh $(RUN_DIR)
	RUN=$(RUN_DIR) scripts/signoff/sta/signoff_summary.sh
scan-sta:
	RUN=$(RUN_DIR) scripts/signoff/sta/scan_sta.sh
gls:
	RUN=$(RUN_DIR) scripts/sim/run_gls_all.sh
dft:
	RUN=$(RUN_DIR) scripts/dft/run_dft.sh
chip:
	RUN=$(RUN_DIR) scripts/chip/run_chip_flow.sh
report:
	python3 scripts/utils/report.py $(RUN_DIR)
check: scan-sta gls dft chip report
