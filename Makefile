# -----------------------------------------------------------------------------
# Croc SoC Physical Design Flow
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# Description: Unified Fusion Compiler (FC) RTL-to-GDS + KLayout DRC Makefile
# -----------------------------------------------------------------------------

SHELL := /bin/bash
.DELETE_ON_ERROR:

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
# Sign-off / DRC configuration (KLayout + GF180MCU)
# ------------------------------------------------------------------------------
# DRC_HOME must contain: run_drc.py, rule_decks/, utils/, and the three
# top-level decks gf180mcu.drc / gf180mcu_antenna.drc / gf180mcu_density.drc.
DRC_HOME      ?= $(HOME)/Documents/gf180_drc_lvs/drc/
# Metal stack option passed to run_drc.py:  A=3LM  B=4LM  C=5LM
GF180MCU_OPT  ?= C
# KLayout run mode: flat | deep | tiling
DRC_RUN_MODE  ?= flat
# Extra run_drc.py flags, e.g. DRC_EXTRA="--antenna --density"
DRC_EXTRA     ?= --thr=6
# GDS to check. Defaults to the "latest" pointer written by 06_finish.tcl.
# Override to sign off a specific run, e.g. make drc GDS=outputs/croc_chip_20260804_101500.gds
GDS           ?= $(OUTPUTS_DIR)/$(TOP).latest.gds
# run_drc.py derives $PDK_ROOT/$PDK from these; we set them explicitly so a
# PDK_ROOT already exported for the Synopsys flow can't interfere.
DRC_PDK_ROOT  ?= $(dir $(patsubst %/,%,$(DRC_HOME)))
DRC_PDK       ?= $(notdir $(patsubst %/,%,$(DRC_HOME)))

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
# Runs run_drc.py on the finished GDS. Results (merged .lyrdb + per-deck logs)
# are grouped per run under reports/drc/<gds-stem>/, so nothing overwrites and
# every check is traceable back to its exact GDS.
#
# Typical use (after the FC flow has produced a GDS):
#   make drc                                   # checks outputs/croc_chip.latest.gds
#   make drc GF180MCU_OPT=B                     # 4LM stack instead of 5LM
#   make drc DRC_EXTRA="--antenna --density"    # add antenna + density checks
#   make drc GDS=outputs/croc_chip_20260804_101500.gds   # re-check an older run
#   make finish drc                             # build finish, then DRC, in one go
.PHONY: drc
drc:
	@if [ ! -e "$(GDS)" ]; then \
	  echo "[DRC] ERROR: GDS not found: $(GDS)"; \
	  echo "[DRC] Run 'make finish' (or 'make all') first, or pass GDS=<path/to.gds>."; \
	  exit 1; \
	fi
	@if [ ! -f "$(DRC_HOME)/run_drc.py" ]; then \
	  echo "[DRC] ERROR: run_drc.py not found under DRC_HOME=$(DRC_HOME)"; \
	  echo "[DRC] Set DRC_HOME to the folder holding run_drc.py, rule_decks/ and utils/."; \
	  exit 1; \
	fi
	@mkdir -p $(LOGS_DIR)
	@gds_real="$$(readlink -f "$(GDS)")"; \
	 stem="$$(basename "$$gds_real" .gds)"; \
	 run_dir="$(REPORTS_DIR)/drc/$$stem"; \
	 mkdir -p "$$run_dir"; \
	 ln -sfn "$$gds_real" "$$run_dir/$$stem.gds"; \
	 echo "[DRC] design : $$gds_real"; \
	 echo "[DRC] stack  : gf180mcu=$(GF180MCU_OPT)  mode=$(DRC_RUN_MODE)  extra='$(DRC_EXTRA)'"; \
	 echo "[DRC] results: $$run_dir"; \
	 ( cd "$$run_dir" && \
	   PDK_ROOT="$(DRC_PDK_ROOT)" PDK="$(DRC_PDK)" \
	   python3 "$(DRC_HOME)/run_drc.py" \
	     --path="$$stem.gds" --gf180mcu=$(GF180MCU_OPT) \
	     --run_mode=$(DRC_RUN_MODE) $(DRC_EXTRA) \
	 ) 2>&1 | tee "$(LOGS_DIR)/drc_$$stem.log"
	@echo "[DRC] Done. Open the .lyrdb in KLayout: reports/drc/<stem>/*.lyrdb"

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
	@echo " Croc SoC Fusion Compiler + DRC Flow"
	@echo "================================================================"
	@echo "Main Targets:"
	@echo "  make all        – Run all available Fusion Compiler steps sequentially"
	@echo "  make drc        – KLayout GF180MCU DRC on the latest GDS in outputs/"
	@echo "  make clean      – Delete the 'work', 'logs', and 'reports' directories"
	@echo "  make distclean  – clean + also delete 'outputs' (exported GDS/netlists)"
	@echo ""
	@echo "Individual Steps (dynamically generated from scripts/):"
	@echo "  make read_rtl"
	@echo "  make floorplan"
	@echo "  make synthesis"
	@echo "  make cts"
	@echo "  make route"
	@echo "  make finish"
	@echo ""
	@echo "DRC options (KLayout / GF180MCU):"
	@echo "  make drc GF180MCU_OPT=C            – metal stack A=3LM B=4LM C=5LM (default C)"
	@echo "  make drc DRC_RUN_MODE=deep         – flat|deep|tiling (default flat)"
	@echo "  make drc DRC_EXTRA=\"--antenna --density\"  – add extra checks"
	@echo "  make drc GDS=outputs/<file>.gds    – check a specific (older) GDS run"
	@echo "  make drc DRC_HOME=/path/to/gf180mcu– where run_drc.py + rule_decks/ live"
	@echo "  make finish drc                    – build finish, then run DRC"
	@echo ""
	@echo "Outputs:"
	@echo "  outputs/$(TOP)_<timestamp>.gds/.v  – timestamped, never overwritten"
	@echo "  outputs/$(TOP).latest.gds/.v       – symlink to the most recent run"
	@echo "  reports/drc/<stem>/                – DRC .lyrdb + logs per GDS"
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