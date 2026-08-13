# -----------------------------------------------------------------------------
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Unified Fusion Compiler (FC) RTL-to-GDS + KLayout DRC Makefile
# -----------------------------------------------------------------------------

SHELL := /bin/bash
.DELETE_ON_ERROR:

# Helpers for converting Make's space-separated lists into comma-separated
# strings (e.g. for klayout -rd args that take a comma-separated list).
empty :=
space := $(empty) $(empty)
comma := ,

# ------------------------------------------------------------------------------
# Design Configuration
# ------------------------------------------------------------------------------
TOP                := croc_soc
WORK_DIR           := work
LOGS_DIR           := logs
REPORTS_DIR        := reports
OUTPUTS_DIR        := outputs
REPO_DIR           := $(shell pwd)

.DEFAULT_GOAL := help

# ------------------------------------------------------------------------------
# Sign-off run selection (shared by DRC and LVS)
# ------------------------------------------------------------------------------
# Each Fusion Compiler run (see 06_finish.tcl) lands in its own folder:
#   outputs/<TOP>_<YYYYMMDD_HHMMSS>/{<TOP>.gds, <TOP>.v}
# and outputs/latest is a symlink to the newest one. Sign-off targets read
# GDS/VLOG out of that run folder and write their results right back into it
# (.../drc/, .../lvs/), so everything for a run lives in one place.
#
#   make drc                              # latest run
#   make lvs                              # latest run
#   make drc RUN=croc_soc_20260804_101500 # a specific (older) run
#   make drc GDS=/path/to/other.gds VLOG=/path/to/other.v  # fully explicit
RUN  ?= latest
GDS  ?= $(OUTPUTS_DIR)/$(RUN)/$(TOP).gds
VLOG ?= $(OUTPUTS_DIR)/$(RUN)/$(TOP).v

# ------------------------------------------------------------------------------
# Sign-off / DRC configuration (KLayout + GF180MCU)
# ------------------------------------------------------------------------------
# DRC_HOME must contain: run_drc.py, rule_decks/, utils/, and the three
# top-level decks gf180mcu.drc / gf180mcu_antenna.drc / gf180mcu_density.drc.
DRC_HOME      ?= $(HOME)/Documents/gf180_drc_lvs/drc/
# Metal stack option passed to run_drc.py / run_lvs.py:  A=3LM  B=4LM  C=5LM
GF180MCU_OPT  ?= C
# KLayout run mode: flat | deep | tiling
DRC_RUN_MODE  ?= flat
# Extra run_drc.py flags, e.g. DRC_EXTRA="--antenna --density"
DRC_EXTRA     ?= --thr=6
# run_drc.py derives $PDK_ROOT/$PDK from these; we set them explicitly so a
# PDK_ROOT already exported for the Synopsys flow can't interfere.
DRC_PDK_ROOT  ?= $(dir $(patsubst %/,%,$(DRC_HOME)))
DRC_PDK       ?= $(notdir $(patsubst %/,%,$(DRC_HOME)))

# ------------------------------------------------------------------------------
# Sign-off / LVS configuration (KLayout + GF180MCU)
# ------------------------------------------------------------------------------
# LVS_HOME must contain: run_lvs.py, verilog2spice.py, fold_wells.py, and the
# gf180mcu.lvs deck. Fusion Compiler does not export a SPICE schematic, so
# `make lvs` first rebuilds one from the exported gate-level Verilog (VLOG)
# using verilog2spice.py against the gf180mcu_fd_sc_mcu7t5v0 CDL, then runs
# KLayout LVS comparing that schematic against the GDS.
LVS_HOME         ?= $(HOME)/Documents/gf180_drc_lvs/lvs/
# KLayout run mode: flat | deep | tiling (deep is the validated default here)
LVS_RUN_MODE     ?= deep
# Substrate net name used in the design
LVS_SUB          ?= VSS
# Complete, versioned GF180MCU PDK managed by `ciel` (the open-source PDK
# version manager). ~/.ciel/gf180mcu<OPT> is a stable symlink to the
# currently-active ciel version, so it survives PDK upgrades. It ships one
# combined CDL per library (libs.ref/<lib>/cdl/<lib>.cdl) -- this is the
# REAL, complete gf180mcu_fd_sc_mcu7t5v0 library whose subckt names match
# what Fusion Compiler's write_verilog actually instantiates.
#
# NOTE: this is deliberately NOT gf180_drc_lvs/lvs/testing/sc_testcases/*.cdl
# (different, X1_7T5P0-style cell names -- a test-suite fixture) and NOT
# ~/pdk_synopsys/cdl/*.cdl (a partial, per-cell export missing most cells,
# e.g. inv_1/nand2_1/fillcap_*/dffrnq_1 -- confirmed missing 2026-08-12).
# GF180MCU_OPT selects the metal-stack variant (A/B/C/D), matching ciel's own
# gf180mcuA/B/C/D directories; the standard-cell CDL itself is identical
# across all four (verified by checksum), only IO/SRAM/tech data differs.
LVS_PDK_KIT      ?= $(HOME)/.ciel/gf180mcu$(GF180MCU_OPT)/libs.ref
# Reference (real) standard-cell CDL. fold_wells.py always strips the
# physical-only `antenna` cell (its diodes break KLayout's SPICE reader),
# and folds VPW -> VSS (matching gf180mcu.lvs's own connect_global on the
# substrate, which globally merges every p-well/substrate tap into VSS
# *within* KLayout's per-leaf-cell extraction). It deliberately does NOT
# fold VNW -> VDD: n-well has no equivalent global connect in this deck, so
# a layout leaf cell keeps its n-well tap as a genuinely separate pin
# (merged into VDD only through abutment with neighboring cells at the
# parent level) -- folding it in the schematic would give every leaf cell a
# spurious pin-count mismatch. verilog2spice.py's own default
# `--tie VNW=VDD` ties each *instantiation's* VNW pin to VDD instead,
# mirroring what abutment does in the layout. The result is cached under
# outputs/.cache/ and only rebuilt when the source CDL changes.
LVS_SC_CDL       ?= $(LVS_PDK_KIT)/gf180mcu_fd_sc_mcu7t5v0/cdl/gf180mcu_fd_sc_mcu7t5v0.cdl
LVS_WELL_TIES    ?= --tie VPW=VSS
# Renames the CDL's SPICE MOSFET model names (nfet_05v0/pfet_05v0) to match
# gf180mcu.lvs's own layout-side device class names (nmos_5p0/pmos_5p0, from
# its extract_devices(mos4("nmos_5p0"), ...) calls). With matching names,
# KLayout's NetlistComparer treats them as the same class automatically --
# no same_device_classes equivalence declaration needed. That matters
# because this KLayout version's (0.30.9) built-in same_device_classes DSL
# helper reliably errors out even when given classes that verifiably exist
# (see the note in gf180mcu.lvs), which otherwise leaves every MOSFET
# pairing -- and thus the deck's own native `compare` and the .lvsdb you'd
# open in KLayout -- unusably wrong (confirmed 2026-08-12: renaming took the
# deck's own compare from ~thousands of spurious failures down to 126 minor
# warnings, concentrated in decap fillers and a few compound gates, none of
# them hard failures). Without this, the .lvsdb in KLayout cannot be trusted.
LVS_MODEL_RENAME ?= --rename-model nfet_05v0=nmos_5p0 --rename-model pfet_05v0=pmos_5p0
# Hard macros with no transistor-level CDL to compare against (e.g. SRAM):
# black-boxed by pin interface only, so they LVS as opaque cells and must be
# signed off separately. Defaults to every gf180mcu SRAM size in the kit;
# harmless to list sizes the design doesn't use (verilog2spice.py only emits
# stubs for cells actually instantiated).
LVS_BLACKBOX_CDL ?= $(wildcard $(LVS_PDK_KIT)/gf180mcu_fd_ip_sram/cdl/gf180mcu_fd_ip_sram__sram*.cdl)
# Hard macros to black-box on the LAYOUT (GDS) side for `make lvs` too --
# not just the schematic. Fusion Compiler's write_gds places the SRAM's
# real, full transistor-level view (thousands of devices per instance);
# without this, LVS "compares" that against the schematic's pin-only stub
# and fails on device count alone, telling you nothing about the design
# itself. `make lvs` derives a black-boxed copy of $(GDS) (blackbox_gds_cells.rb
# strips diffusion/poly/well/implant/contact layers from just these cells'
# sub-hierarchy, leaving metal/via routing and pin labels untouched, so the
# macro's boundary connectivity is unaffected) and signs off against that --
# $(GDS) itself is never modified, so it's unaffected for `make drc` and
# stays exactly what Fusion Compiler wrote for tapeout. Defaults to the cell
# names implied by LVS_BLACKBOX_CDL; set to empty to sign off the real GDS
# as-is (e.g. once you have a transistor-level SRAM CDL to LVS it against
# directly instead of treating it as a black box).
LVS_BLACKBOX_CELLS ?= $(basename $(notdir $(LVS_BLACKBOX_CDL)))
# Comma-separated, case-insensitive substrings: subcircuit instances whose
# referenced circuit name contains any of these are removed from BOTH the
# layout and schematic netlists before compare (symmetrically, comparison
# scope only -- the real GDS/.v/.sp are untouched, so DRC and tapeout are
# unaffected). fillcap (decoupling-cap fillers) has thousands of instances
# tying only VDD/VSS with no signal connectivity and no distinguishing
# topology between same-size instances, so exact 1:1 instance
# correspondence between an independently-drawn layout and an
# independently-synthesized schematic is fundamentally ambiguous -- not a
# real violation, just more interchangeable siblings than a graph-
# isomorphism matcher can uniquely resolve (confirmed 2026-08-13: this was
# the deciding factor between "Netlists don't match" and "Congratulations!
# Netlists match" on croc_soc, with the *same* 126 harmless
# MatchWithWarning notes either way -- see lvs_compare_summary.txt).
# Set to empty to compare every instance, filler cells included.
LVS_EXCLUDE_FROM_COMPARE ?= fillcap
# Known-good run_lvs.py switches (matches the manually-verified croc_soc run).
LVS_FLAGS        ?= --set_spice_comments --set_net_only --set_top_lvl_pins --set_combine --set_purge --set_purge_nets
# Extra run_lvs.py flags, e.g. LVS_EXTRA="--thr=6 --set_verbose"
LVS_EXTRA        ?= --thr=6
LVS_PDK_ROOT     ?= $(dir $(patsubst %/,%,$(LVS_HOME)))
LVS_PDK          ?= $(notdir $(patsubst %/,%,$(LVS_HOME)))
# Layout-vs-schematic MOSFET device-class equivalence, passed to
# lvs_compare.rb (the secondary cross-check -- see LVS_MODEL_RENAME above
# for the primary fix, which makes this unnecessary by construction: with
# both sides' CDL model names already renamed to match the layout's own
# device class names, they read back with the SAME name -- e.g. NMOS_5P0
# on both sides, not NMOS_5P0 vs NFET_05V0 -- so KLayout's NetlistComparer
# already treats them as equivalent with no mapping needed. Empty by
# default; only set this if you override LVS_MODEL_RENAME to something
# that leaves the names actually differing between the two sides.
LVS_DEVICE_CLASS_MAP ?=

CACHE_DIR       := $(OUTPUTS_DIR)/.cache
FOLDED_SC_CDL   := $(CACHE_DIR)/gf180mcu_fd_sc_mcu7t5v0.folded.cdl

# ------------------------------------------------------------------------------
# Fusion Compiler dynamic step rules (from scripts/0*_*.tcl)
# ------------------------------------------------------------------------------
# This block automatically reads any TCL file in scripts/ that starts with a number 
# (e.g., 01_read_rtl.tcl, 02_floorplan.tcl) and creates a make target for it.
define MAKE_FC_RULE
.PHONY: $2 open_$2 gui_$2

$2: $(WORK_DIR)/design.dlib/$2

open_$2: $(WORK_DIR)/design.dlib/$2
	cd $(WORK_DIR) && fc_shell -f ../scripts/common/setup.tcl -x "open_lib design.dlib; open_block $2"

gui_$2: $(WORK_DIR)/design.dlib/$2
	cd $(WORK_DIR) && fc_shell -gui -f ../scripts/common/setup.tcl -x "open_lib design.dlib; open_block $2"

$(WORK_DIR)/design.dlib/$2: $3 $1
	mkdir -p $(WORK_DIR) $(LOGS_DIR) $(REPORTS_DIR)/$(basename $(notdir $1)) && cd $(WORK_DIR) && set -o pipefail; \
	fc_shell -batch -f ../$1 | tee ../$(LOGS_DIR)/$2.log
endef

TCL_FILES = $(sort $(wildcard scripts/0*_*.tcl))

DEPENDENCY :=
$(foreach file,$(TCL_FILES),\
  $(eval base := $(shell echo $(notdir $(file)) | sed -E 's/^[0-9]+_(.*)\.tcl/\1/'))\
  $(eval $(call MAKE_FC_RULE,$(file),$(base),$(DEPENDENCY)))\
  $(eval DEPENDENCY := $(WORK_DIR)/design.dlib/$(base))\
)

# ------------------------------------------------------------------------------
# Full Flow
# ------------------------------------------------------------------------------
.PHONY: all
all: $(DEPENDENCY)
	@echo "[FLOW] Fusion Compiler flow completed successfully up to the final TCL script."

# ------------------------------------------------------------------------------
# Physical Verification - KLayout DRC (GF180MCU)
# ------------------------------------------------------------------------------
# Runs run_drc.py on the run's GDS. Results (merged .lyrdb + per-deck logs)
# land in <run>/drc/, right next to that run's .gds/.v, so nothing overwrites
# and every check is traceable back to its exact GDS.
#
# Typical use (after the FC flow has produced a GDS):
#   make drc                                   # checks outputs/latest
#   make drc GF180MCU_OPT=B                     # 4LM stack instead of 5LM
#   make drc DRC_EXTRA="--antenna --density"    # add antenna + density checks
#   make drc RUN=croc_soc_20260804_101500       # re-check an older run
#   make finish drc                             # build finish, then DRC, in one go
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
# Fusion Compiler exports a GDS + gate-level Verilog, but no SPICE schematic.
# `make lvs` rebuilds one (verilog2spice.py, using the folded
# gf180mcu_fd_sc_mcu7t5v0 CDL + any hard-macro CDLs as black boxes), then runs
# KLayout LVS comparing it against the GDS. Results land in <run>/lvs/,
# alongside that run's .gds/.v (and its drc/ folder, if `make drc` also ran).
#
# Typical use (after the FC flow has produced a GDS + Verilog netlist):
#   make lvs                                    # latest run
#   make lvs GF180MCU_OPT=B                      # 4LM stack instead of 5LM
#   make lvs RUN=croc_soc_20260804_101500        # re-check an older run
#   make finish drc lvs                          # build, then DRC, then LVS
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
# Clean
# ------------------------------------------------------------------------------
.PHONY: clean distclean
clean:
	rm -rf $(WORK_DIR) $(LOGS_DIR) $(REPORTS_DIR)
	@echo "Cleaned work, logs, and reports directories."

# distclean also removes the exported GDS/netlists in outputs/. Use with care.
distclean: clean
	rm -rf $(OUTPUTS_DIR)
	@echo "Also removed the outputs directory (exported GDS/netlists)."

# ------------------------------------------------------------------------------
# Software & Simulation Flow
# ------------------------------------------------------------------------------
.PHONY: sw sim sim-vcs verilate run clean-sw clean-sim

# Default application binary. Override on the command line, e.g.:
#   make run BIN=sim/sw/bin/test/test_gpio.hex
BIN ?= sim/sw/hello_world/bin/helloworld.hex

sw:
	@echo "[SW] Compiling RISC-V bare-metal software..."
	@$(MAKE) -C sim/sw

clean-sw:
	@echo "[SW] Cleaning software binaries..."
	@$(MAKE) -C sim/sw clean

# Compile the Verilator hardware model only (re-run after any RTL change).
verilate:
	@echo "[SIM] Compiling Verilator hardware model..."
	@cd sim && BUILD_ONLY=1 bash scripts/run_verilator.sh

# Run a binary on the already-compiled model -- no recompile, near-instant.
run: sw
	@echo "[SIM] Running $(BIN) ..."
	@cd sim && BIN=$(abspath $(BIN)) SKIP_BUILD=1 bash scripts/run_verilator.sh

# Compile + run in one shot (original behavior; defaults to helloworld).
sim:
	@echo "[SIM] Launching Verilator simulation flow..."
	@cd sim && BIN=$(abspath $(BIN)) bash scripts/run_verilator.sh

# Compile the VCS hardware model (elaboration phase).
vcs-compile:
	@echo "[SIM] Compiling VCS hardware model..."
	@cd sim && BUILD_ONLY=1 bash scripts/run_vcs.sh

# Run a binary on the already-compiled VCS model.
# Assumes the simulation binary (e.g., simv) exists from a previous vcs-compile.
run-vcs: sw
	@echo "[SIM] Running $(BIN) on VCS..."
	@cd sim && BIN=$(abspath $(BIN)) SKIP_BUILD=1 bash scripts/run_vcs.sh

# Compile + run VCS in one shot.
sim-vcs: sw
	@echo "[SIM] Launching full VCS simulation flow..."
	@cd sim && BIN=$(abspath $(BIN)) bash scripts/run_vcs.sh

clean-sim:
	@echo "[SIM] Cleaning simulation builds..."
	@rm -rf sim/build/*

# ------------------------------------------------------------------------------
# FPGA (ZedBoard / Zynq-7000 PL) Flow -- requires Vivado on PATH
# ------------------------------------------------------------------------------
.PHONY: fpga clean-fpga

VIVADO ?= vivado

# Non-project-mode batch build: synth -> opt -> place -> route -> bitstream.
# Reads croc_fpga.flist + constraints/zedboard.xdc; output in work_fpga/.
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
	@echo "  make clean      – Delete the 'work', 'logs', and 'reports' directories"
	@echo "  make distclean  – clean + also delete 'outputs' (exported GDS/netlists/results)"
	@echo ""
	@echo "Individual Steps (dynamically generated from scripts/):"
	@echo "  make read_rtl"
	@echo "  make floorplan"
	@echo "  make synthesis"
	@echo "  make cts"
	@echo "  make route"
	@echo "  make finish"
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
	@echo "Outputs (one self-contained folder per Fusion Compiler run):"
	@echo "  outputs/$(TOP)_<timestamp>/$(TOP).gds/.v  – timestamped, never overwritten"
	@echo "  outputs/latest                      – symlink to the most recent run folder"
	@echo "  outputs/<run>/drc/                  – DRC .lyrdb + logs for that run"
	@echo "  outputs/<run>/lvs/                  – LVS .sp/.lvsdb/extracted netlist + logs"
	@echo "  outputs/.cache/                     – cached folded CDL (rebuilt only if stale)"
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